-- =====================================================================
-- آزمون پایگاه داده‌ای 80_assistant.sql (سند: docs/design/10-assistant.md §۷ و §۹)
--
-- اجرا (از ریشهٔ مخزن؛ پایگاه دادهٔ تازه با UTF8):
--   export PGPASSWORD=postgres
--   psql -h localhost -p 5433 -U postgres -d postgres -c "DROP DATABASE IF EXISTS ds_assistant"
--   psql -h localhost -p 5433 -U postgres -d postgres -c "CREATE DATABASE ds_assistant ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8'"
--   for f in 00_foundation 10_core 20_ledger 25_masterdata 80_assistant; do
--     psql -h localhost -p 5433 -U postgres -d ds_assistant -v ON_ERROR_STOP=1 -q -f docs/design/sql/$f.sql; done
--   psql -h localhost -p 5433 -U postgres -d ds_assistant -v ON_ERROR_STOP=1 -f docs/design/sql/tests/80_assistant_test.sql
--
-- ساختار (یک نشست psql که با superuser وصل می‌شود):
--   بخش ۱ (fixture، نقش postgres): مستأجر A و B، سه شرکت، چهار کاربر و عضویت، سیاست دستیار، دورهٔ مصرف، رضایت،
--          یک رشته برای هر مستأجر، و توابع کمکی public.as_* و public.k / public.fp (همه SECURITY INVOKER؛
--          با نقش فراخوان اجرا می‌شوند، پس RLS و grantها روی hk_app اعمال می‌شوند).
--   بخش ۲ (assert، «SET ROLE hk_app»: نه مالک، NOBYPASSRLS): T01b..T16. هر DO block مستأجر، کاربر و
--          app.actor_via را با set_config(..., true) تنظیم می‌کند.
--   بخش ۳ (hk_readonly): T17 فراداده بله، محتوا و راز نه.
--   بخش ۴ (postgres): T18 قیدهای کاتالوگ و CHECKها، T19 ردیف‌های ساختگی منقضی (با session_replication_role=replica) و
--          آزمون reap/purge/حذف دادهٔ شخصی/انقضا/توقیف قانونی با hk_app، T20 lint امنیتی هسته روی اسکیمای assistant، lint
--          کاتالوگ و نمایهٔ FK، T21 نگهبان پیشنهادی هسته روی ledger.journal_line (در تراکنش برگشتی)، T22 بردار اثرانگشت
--          مشترک با پایتون، T23 هم‌روندی واقعی با dblink (سقف هم‌زمانی و بودجه) و سطح جداسازی.
-- خروجی موفق با «ALL 80_assistant TESTS PASSED» پایان می‌یابد؛ هر شکست «TEST FAILED [...]» می‌دهد و psql با کد ≠ ۰
-- خارج می‌شود. بردار مشترک: -v fp_vectors_file=docs/design/sql/tests/assistant_fingerprint_v2.json
-- برچسب‌های ناوردا در سند: INV-AI-* (R-INV؛ پیش‌تر INV-AST-*).
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
\if :{?fp_vectors_file}
\else
  \set fp_vectors_file docs/design/sql/tests/assistant_fingerprint_v2.json
\endif
\set fp_vectors `cat :fp_vectors_file`

-- =====================================================================
-- بخش ۱: fixture (postgres)
-- =====================================================================
RESET ROLE;

CREATE OR REPLACE FUNCTION public.k(p text) RETURNS uuid
LANGUAGE sql IMMUTABLE AS $$
SELECT (CASE p
  WHEN 'A'     THEN '80a00000-0000-7000-8000-000000000001'  WHEN 'B'     THEN '80b00000-0000-7000-8000-000000000001'
  WHEN 'A.C1'  THEN '80a00000-0000-7000-8000-0000000000c1'  WHEN 'A.C2'  THEN '80a00000-0000-7000-8000-0000000000c2'
  WHEN 'B.C1'  THEN '80b00000-0000-7000-8000-0000000000c1'
  WHEN 'a1'    THEN '80a00000-0000-7000-8000-0000000000a1'  WHEN 'a2'    THEN '80a00000-0000-7000-8000-0000000000a2'
  WHEN 'a3'    THEN '80a00000-0000-7000-8000-0000000000a3'  WHEN 'b1'    THEN '80b00000-0000-7000-8000-0000000000b1'
  WHEN 'polA'  THEN '80a00000-0000-7000-8000-0000000000f1'  WHEN 'polB'  THEN '80b00000-0000-7000-8000-0000000000f1'
  WHEN 'cA1'   THEN '80a00000-0000-7000-8000-00000000cc01'  WHEN 'cA2'   THEN '80a00000-0000-7000-8000-00000000cc02'
  WHEN 'cA3'   THEN '80a00000-0000-7000-8000-00000000cc03'  WHEN 'cA4'   THEN '80a00000-0000-7000-8000-00000000cc04'
  WHEN 'cB1'   THEN '80b00000-0000-7000-8000-00000000cc01'
  WHEN 'uA'    THEN '80a00000-0000-7000-8000-00000000ee00'  WHEN 'ua1'   THEN '80a00000-0000-7000-8000-00000000ee01'
  WHEN 'ua2'   THEN '80a00000-0000-7000-8000-00000000ee02'  WHEN 'ua3'   THEN '80a00000-0000-7000-8000-00000000ee03'
  WHEN 'uB'    THEN '80b00000-0000-7000-8000-00000000ee00'  WHEN 'ub1'   THEN '80b00000-0000-7000-8000-00000000ee01'
  WHEN 'tA1'   THEN '80a00000-0000-7000-8000-00000000aa01'  WHEN 'tA2'   THEN '80a00000-0000-7000-8000-00000000aa02'
  WHEN 'tA9'   THEN '80a00000-0000-7000-8000-00000000aa09'  WHEN 'tA21'  THEN '80a00000-0000-7000-8000-00000000aa21'
  WHEN 'tA31'  THEN '80a00000-0000-7000-8000-00000000aa31'  WHEN 'tOld'  THEN '80a00000-0000-7000-8000-00000000aa90'
  WHEN 'tExp'  THEN '80a00000-0000-7000-8000-00000000aa91'  WHEN 'tB1'   THEN '80b00000-0000-7000-8000-00000000bb01'
  WHEN 'rA1'   THEN '80a00000-0000-7000-8000-0000000a0001'  WHEN 'rA2'   THEN '80a00000-0000-7000-8000-0000000a0002'
  WHEN 'rA3'   THEN '80a00000-0000-7000-8000-0000000a0003'  WHEN 'rOld'  THEN '80a00000-0000-7000-8000-0000000a0090'
  WHEN 'rExp'  THEN '80a00000-0000-7000-8000-0000000a0091'  WHEN 'rAnc'  THEN '80a00000-0000-7000-8000-0000000a0092'
  WHEN 'rB1'   THEN '80b00000-0000-7000-8000-0000000a0001'
  WHEN 'cl11'  THEN '80a00000-0000-7000-8000-000000c10011'  WHEN 'cl12'  THEN '80a00000-0000-7000-8000-000000c10012'
  WHEN 'cl13'  THEN '80a00000-0000-7000-8000-000000c10013'  WHEN 'cl21'  THEN '80a00000-0000-7000-8000-000000c10021'
  WHEN 'cl31'  THEN '80a00000-0000-7000-8000-000000c10031'  WHEN 'clOld' THEN '80a00000-0000-7000-8000-000000c10090'
  WHEN 'clExp' THEN '80a00000-0000-7000-8000-000000c10091'
  WHEN 'tc1'   THEN '80a00000-0000-7000-8000-0000000d0001'  WHEN 'tc2'   THEN '80a00000-0000-7000-8000-0000000d0002'
  WHEN 'tc3'   THEN '80a00000-0000-7000-8000-0000000d0003'  WHEN 'tc4'   THEN '80a00000-0000-7000-8000-0000000d0004'
  WHEN 'tc5'   THEN '80a00000-0000-7000-8000-0000000d0005'  WHEN 'tc6'   THEN '80a00000-0000-7000-8000-0000000d0006'
  WHEN 'tcExp' THEN '80a00000-0000-7000-8000-0000000d0091'
  WHEN 'pr1'   THEN '80a00000-0000-7000-8000-0000000e0001'  WHEN 'pr2'   THEN '80a00000-0000-7000-8000-0000000e0002'
  WHEN 'pr3'   THEN '80a00000-0000-7000-8000-0000000e0003'  WHEN 'pr4'   THEN '80a00000-0000-7000-8000-0000000e0004'
  WHEN 'prExp' THEN '80a00000-0000-7000-8000-0000000e0091'
  WHEN 'tp1'   THEN '80a00000-0000-7000-8000-0000000f0001'  WHEN 'tp2'   THEN '80a00000-0000-7000-8000-0000000f0002'
  WHEN 'tpB'   THEN '80b00000-0000-7000-8000-0000000f0001'
  WHEN 'm1'    THEN '80a00000-0000-7000-8000-000000ab0001'  WHEN 'm2'    THEN '80a00000-0000-7000-8000-000000ab0002'
  WHEN 'f1'    THEN '80a00000-0000-7000-8000-000000ac0001'  WHEN 'f2'    THEN '80a00000-0000-7000-8000-000000ac0002'
  WHEN 'rA4'   THEN '80a00000-0000-7000-8000-0000000a0004'  WHEN 'cl41'  THEN '80a00000-0000-7000-8000-000000c10041'
  WHEN 'm3'    THEN '80a00000-0000-7000-8000-000000ab0003'  WHEN 'm4'    THEN '80a00000-0000-7000-8000-000000ab0004'
  WHEN 'tVo'   THEN '80a00000-0000-7000-8000-00000000aa92'  WHEN 'tHc'   THEN '80a00000-0000-7000-8000-00000000aa93'
  WHEN 'tHs'   THEN '80a00000-0000-7000-8000-00000000aa94'  WHEN 'tHr'   THEN '80a00000-0000-7000-8000-00000000aa95'
  WHEN 'tA3o'  THEN '80a00000-0000-7000-8000-00000000aa96'
  WHEN 'rDl'   THEN '80a00000-0000-7000-8000-0000000a0093'  WHEN 'rHm'   THEN '80a00000-0000-7000-8000-0000000a0094'
  WHEN 'exM'   THEN '80a00000-0000-7000-8000-0000000bb001'  WHEN 'exO'   THEN '80a00000-0000-7000-8000-0000000bb002'
  WHEN 'C'     THEN '80c00000-0000-7000-8000-000000000001'  WHEN 'C.C1'  THEN '80c00000-0000-7000-8000-0000000000c1'
  WHEN 'c1'    THEN '80c00000-0000-7000-8000-0000000000a1'  WHEN 'c2'    THEN '80c00000-0000-7000-8000-0000000000a2'
  WHEN 'c3'    THEN '80c00000-0000-7000-8000-0000000000a3'
  WHEN 'polC'  THEN '80c00000-0000-7000-8000-0000000000f1'  WHEN 'cC1'   THEN '80c00000-0000-7000-8000-00000000cc01'
  WHEN 'uC'    THEN '80c00000-0000-7000-8000-00000000ee00'  WHEN 'uc1'   THEN '80c00000-0000-7000-8000-00000000ee01'
  WHEN 'uc2'   THEN '80c00000-0000-7000-8000-00000000ee02'  WHEN 'uc3'   THEN '80c00000-0000-7000-8000-00000000ee03'
  WHEN 'tC1'   THEN '80c00000-0000-7000-8000-00000000cc31'  WHEN 'tC2'   THEN '80c00000-0000-7000-8000-00000000cc32'
  WHEN 'tC3'   THEN '80c00000-0000-7000-8000-00000000cc33'
  WHEN 'rC1'   THEN '80c00000-0000-7000-8000-0000000a0001'  WHEN 'rC2'   THEN '80c00000-0000-7000-8000-0000000a0002'
  WHEN 'rC3'   THEN '80c00000-0000-7000-8000-0000000a0003'
END)::uuid $$;

-- اثرانگشت‌ها: P = پروفایل اصلی پلتفرم، S = پروفایل دوم (failover)، L = سرور LAN مستأجر (hkllm2)، X = مقصدی که سیاست ندارد.
-- P و S مقدارهای مات تحویلی سیاست امضاشدهٔ پلتفرم‌اند؛ پایگاه دادهٔ صفحهٔ داده آن‌ها را دوباره حساب نمی‌کند.
CREATE OR REPLACE FUNCTION public.fp(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
SELECT CASE p
  WHEN 'P' THEN '4a43acd40cff6f3730caef30f6d857ecf139d4ed89d983b1c2e435f9ebb2f8f2'
  WHEN 'S' THEN 'da5ba91c78fbaf85dc3aad3834ae740cb300f798034ed343b00cd8a200eb868a'
  WHEN 'L' THEN 'e6cfeeb53945b2c0816cd874697e3d7b9da0905c3efb7f09d5b92465233ccc23'
  WHEN 'X' THEN '1111111111111111111111111111111111111111111111111111111111111111'
END $$;

BEGIN;
-- A نصب On-prem است (ارائه‌دهندهٔ LAN خود مشتری مجاز)؛ B مستأجر SaaS است (RV-AST-15)
INSERT INTO core.tenant (id, slug, display_name, deployment) VALUES
  (public.k('A'), 'as-tenant-a', 'A', 'onprem'), (public.k('B'), 'as-tenant-b', 'B', 'saas_shared');
INSERT INTO core.company (tenant_id, id, code, name) VALUES
  (public.k('A'), public.k('A.C1'), 'C1', 'کافه الف'),
  (public.k('A'), public.k('A.C2'), 'C2', 'کفش الف'),
  (public.k('B'), public.k('B.C1'), 'C1', 'برق ب');
INSERT INTO core.app_user (id, kind, display_name) VALUES
  (public.k('a1'), 'human', 'مالک الف'), (public.k('a2'), 'human', 'حسابدار الف'),
  (public.k('a3'), 'human', 'فروشنده الف'), (public.k('b1'), 'human', 'مالک ب');
INSERT INTO core.tenant_membership (tenant_id, user_id, status, is_owner, joined_at) VALUES
  (public.k('A'), public.k('a1'), 'active', true,  now()),
  (public.k('A'), public.k('a2'), 'active', false, now()),
  (public.k('A'), public.k('a3'), 'active', false, now()),
  (public.k('B'), public.k('b1'), 'active', true,  now());
-- همگام‌سازی کاتالوگ مجوز ماژول‌هایی که در زنجیرهٔ مستقل این آزمون اعمال نشده‌اند (sales، treasury، inventory، …؛ در پایگاه
-- یکپارچه خود آن ماژول‌ها ثبت می‌کنند). مجوز ثبت‌نشده یعنی ابزار در دسترس نیست (fail-closed)، پس آزمون به آن نیاز دارد.
INSERT INTO core.permission (code, module, scope_dimensions, risk, allow_service_account, allow_impersonation_write, description_key, introduced_in)
SELECT DISTINCT tp.permission_code, split_part(tp.permission_code, '.', 1), '{company}'::text[],
       CASE WHEN tp.permission_code IN ('inventory.cost.read','payroll.report.read','treasury.reminder.send') THEN 'sensitive' ELSE 'normal' END,
       true, false, 'perm.' || tp.permission_code, '1.0'
  FROM assistant.tool_permission tp
 WHERE NOT EXISTS (SELECT 1 FROM core.permission p WHERE p.code = tp.permission_code)
ON CONFLICT (code) DO NOTHING;
COMMIT;

-- ---------- توابع کمکی آزمون ----------
CREATE OR REPLACE FUNCTION public.as_expect_error(p_label text, p_sql text, p_expect text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_state text; v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF (p_expect LIKE 'HK\_%' AND split_part(v_msg, ':', 1) = p_expect) OR v_state = p_expect THEN RETURN; END IF;
    RAISE EXCEPTION 'TEST FAILED [%]: expected %, got % %', p_label, p_expect, v_state, v_msg;
  END;
  RAISE EXCEPTION 'TEST FAILED [%]: statement succeeded but % was expected', p_label, p_expect;
END $$;

CREATE OR REPLACE FUNCTION public.as_assert(p_cond boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'TEST FAILED [%]', p_label; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.as_ctx(p_tenant uuid, p_user uuid, p_via text DEFAULT '') RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.tenant_id', coalesce(p_tenant::text, ''), true);
  PERFORM set_config('app.user_id', coalesce(p_user::text, ''), true);
  PERFORM set_config('app.actor_via', p_via, true);
  PERFORM set_config('app.impersonation_session_id', '', true);
END $$;

-- سند سیاست (بلوک assistant امضاشده). ستون‌های tenant_policy همه از این سند تولید می‌شوند (RV-AST-10).
CREATE OR REPLACE FUNCTION public.as_policy_doc(p_version bigint, p_features text[], p_profile_fp text, p_secondary text[],
                                                p_allow_tenant boolean, p_tenant_tokens bigint, p_tenant_cost text, p_user_tokens bigint,
                                                p_max_concurrent integer, p_max_rounds integer DEFAULT 6, p_max_tool_calls integer DEFAULT 12)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'policy_version', p_version, 'entitled', true, 'enabled', true, 'kill_reason', NULL, 'features', to_jsonb(p_features),
    'profile', CASE WHEN p_profile_fp IS NULL THEN NULL
                    ELSE jsonb_build_object('code', 'ir-main', 'version', 3, 'fingerprint', p_profile_fp, 'operator', 'Iranian AI Co',
                                            'data_location', 'iran', 'network', 'public') END,
    'secondary_fingerprints', to_jsonb(coalesce(p_secondary, '{}'::text[])), 'allow_tenant_provider', p_allow_tenant,
    'quotas', jsonb_build_object('tenant_monthly_tokens', p_tenant_tokens, 'tenant_monthly_cost', p_tenant_cost, 'cost_unit', 'IRR',
                                 'user_monthly_tokens', p_user_tokens, 'max_concurrent_runs', p_max_concurrent,
                                 'max_rounds', p_max_rounds, 'max_tool_calls', p_max_tool_calls))
$$;

-- نسخهٔ تازهٔ سند سیاست مستأجر جاری: کلیدهای سطح بالا جایگزین و quotas ادغام می‌شوند؛ نسخه یکی بالا می‌رود
CREATE OR REPLACE FUNCTION public.as_policy_patch(p_patch jsonb) RETURNS void
LANGUAGE sql AS $$
  UPDATE assistant.tenant_policy
     SET document = document || (p_patch - 'quotas')
                    || jsonb_build_object('policy_version', policy_version + 1,
                                          'quotas', coalesce(document->'quotas', '{}'::jsonb) || coalesce(p_patch->'quotas', '{}'::jsonb))
   WHERE tenant_id = core.current_tenant_id()
$$;

CREATE OR REPLACE FUNCTION public.as_usage(p_scope text, p_user uuid) RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT id FROM assistant.usage_period
   WHERE tenant_id = core.current_tenant_id() AND scope = p_scope AND user_id IS NOT DISTINCT FROM p_user
     AND period_start <= current_date AND period_end > current_date
$$;

CREATE OR REPLACE FUNCTION public.as_grant_consent(p_id uuid, p_purposes text[], p_classes text[], p_fps text[],
                                                   p_granted uuid DEFAULT NULL, p_mfa_age interval DEFAULT interval '1 minute')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO assistant.consent (tenant_id, id, purposes, data_classes, provider_fingerprints, provider_summary, consent_text_code,
                                 consent_text_sha256, granted_by, signer_full_name, signer_capacity, mfa_at)
  VALUES (core.current_tenant_id(), coalesce(p_id, uuidv7()), p_purposes, p_classes, p_fps,
          '[{"operator":"Iranian AI Co","data_location":"iran"}]', 'assistant.consent.v1', sha256(convert_to('متن رضایت نسخهٔ ۱', 'UTF8')),
          coalesce(p_granted, core.current_user_id()), 'مالک الف', 'owner', now() - p_mfa_age)
  RETURNING id INTO v;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.as_new_run(p_id uuid, p_thread uuid, p_fp text DEFAULT NULL, p_source text DEFAULT 'platform',
                                             p_tp uuid DEFAULT NULL, p_purpose text DEFAULT 'chat', p_user uuid DEFAULT NULL,
                                             p_policy_version bigint DEFAULT NULL, p_consent uuid DEFAULT NULL,
                                             p_tenant_usage uuid DEFAULT NULL, p_user_usage uuid DEFAULT NULL,
                                             p_lease interval DEFAULT interval '5 minutes', p_status text DEFAULT 'running',
                                             p_company uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE p assistant.tenant_policy; v uuid; u uuid := coalesce(p_user, core.current_user_id()); v_company uuid := p_company;
BEGIN
  SELECT * INTO p FROM assistant.tenant_policy WHERE tenant_id = core.current_tenant_id();
  IF v_company IS NULL THEN
    SELECT company_id INTO v_company FROM assistant.thread WHERE tenant_id = core.current_tenant_id() AND id = p_thread;
  END IF;
  IF v_company IS NULL THEN
    SELECT id INTO v_company FROM core.company WHERE tenant_id = core.current_tenant_id() ORDER BY code LIMIT 1;
  END IF;
  INSERT INTO assistant.run (tenant_id, id, thread_id, user_id, company_id, purpose, consent_id, provider_source, provider_code,
                             provider_version, provider_fingerprint, tenant_provider_id, model, policy_version, prompt_version,
                             prompt_sha256, toolset_sha256, tenant_usage_id, user_usage_id, lease_expires_at, request_id, status, finished_at)
  VALUES (core.current_tenant_id(), coalesce(p_id, uuidv7()), p_thread, u, v_company, p_purpose,
          coalesce(p_consent, (SELECT id FROM assistant.consent WHERE tenant_id = core.current_tenant_id() AND status = 'active')),
          p_source, CASE WHEN p_source = 'tenant' THEN 'tenant-lan' ELSE 'ir-main' END, CASE WHEN p_source = 'tenant' THEN NULL ELSE 3 END,
          coalesce(p_fp, public.fp('P')), p_tp, 'hoosh-7b-instruct', coalesce(p_policy_version, p.policy_version), 'fa-chat-v1',
          sha256(convert_to('system prompt', 'UTF8')), sha256(convert_to('toolset', 'UTF8')),
          coalesce(p_tenant_usage, public.as_usage('tenant', NULL)), coalesce(p_user_usage, public.as_usage('user', u)),
          now() + p_lease, 'req-test', p_status, CASE WHEN p_status = 'running' THEN NULL ELSE now() END)
  RETURNING id INTO v;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.as_new_call(p_id uuid, p_run uuid, p_round integer, p_rp integer DEFAULT 1000, p_rc integer DEFAULT 500,
                                              p_unit core.amount_unit DEFAULT 'IRR', p_tenant_usage uuid DEFAULT NULL,
                                              p_lease interval DEFAULT interval '3 minutes', p_completed boolean DEFAULT false) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE r assistant.run; v uuid;
BEGIN
  SELECT * INTO r FROM assistant.run WHERE tenant_id = core.current_tenant_id() AND id = p_run;
  INSERT INTO assistant.llm_call (tenant_id, id, run_id, round_no, user_id, tenant_usage_id, user_usage_id, provider_fingerprint, model,
                                  lease_expires_at, reserved_prompt_tokens, reserved_completion_tokens, price_unit,
                                  input_price_per_mtok, output_price_per_mtok, status, finished_at, prompt_tokens, completion_tokens, finish_reason)
  VALUES (r.tenant_id, coalesce(p_id, uuidv7()), r.id, p_round, r.user_id, coalesce(p_tenant_usage, r.tenant_usage_id), r.user_usage_id,
          r.provider_fingerprint, r.model, now() + p_lease, p_rp, p_rc, p_unit, 20000, 80000,
          CASE WHEN p_completed THEN 'completed' ELSE 'in_flight' END, CASE WHEN p_completed THEN now() END,
          CASE WHEN p_completed THEN 10 END, CASE WHEN p_completed THEN 10 END, CASE WHEN p_completed THEN 'stop' END)
  RETURNING id INTO v;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.as_finish_call(p_call uuid, p_pt integer, p_ct integer, p_finish text DEFAULT 'tool_calls') RETURNS void
LANGUAGE sql AS $$
  UPDATE assistant.llm_call SET status = 'completed', prompt_tokens = p_pt, completion_tokens = p_ct, finish_reason = p_finish,
                                first_token_ms = 300, total_ms = 1200
   WHERE id = p_call
$$;

CREATE OR REPLACE FUNCTION public.as_tool_call(p_id uuid, p_run uuid, p_call uuid, p_seq integer, p_tool text, p_status text DEFAULT 'ok',
                                               p_result jsonb DEFAULT '{"ok": true}', p_perms text[] DEFAULT NULL, p_rows integer DEFAULT 0,
                                               p_version integer DEFAULT NULL, p_thread uuid DEFAULT NULL, p_denied text DEFAULT NULL,
                                               p_args jsonb DEFAULT '{"period": "this_month"}') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE r assistant.run; v uuid; v_perms text[];
BEGIN
  SELECT * INTO r FROM assistant.run WHERE tenant_id = core.current_tenant_id() AND id = p_run;
  SELECT coalesce(array_agg(permission_code ORDER BY permission_code), '{}') INTO v_perms
    FROM assistant.tool_permission WHERE tool_code = p_tool AND requirement = 'read';
  INSERT INTO assistant.tool_call (tenant_id, id, run_id, llm_call_id, thread_id, user_id, seq, provider_call_id, tool_code, tool_version,
                                   status, args, result, result_rows, permissions_checked, denied_permission, error_code, latency_ms)
  VALUES (r.tenant_id, coalesce(p_id, uuidv7()), r.id, p_call, coalesce(p_thread, r.thread_id), r.user_id, p_seq, 'call_' || p_seq,
          p_tool, coalesce(p_version, (SELECT version FROM assistant.tool WHERE code = p_tool)), p_status, p_args, p_result, p_rows,
          coalesce(p_perms, v_perms), p_denied,
          CASE WHEN p_status IN ('ok','denied') THEN NULL ELSE 'assistant.tool.failed' END, 42)
  RETURNING id INTO v;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.as_proposal(p_id uuid, p_tool_call uuid, p_kind text, p_valid boolean DEFAULT true,
                                              p_company uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE tc assistant.tool_call; v uuid;
BEGIN
  SELECT * INTO tc FROM assistant.tool_call WHERE tenant_id = core.current_tenant_id() AND id = p_tool_call;
  INSERT INTO assistant.proposal (tenant_id, id, tool_call_id, run_id, thread_id, user_id, company_id, kind, title, payload, validation,
                                  valid, expires_at)
  VALUES (tc.tenant_id, coalesce(p_id, uuidv7()), tc.id, tc.run_id, tc.thread_id, tc.user_id,
          coalesce(p_company, (SELECT company_id FROM assistant.run WHERE id = tc.run_id)), p_kind, 'پیش‌نویس سند اجاره',
          '{"date": "2026-11-17", "lines": [{"account": "6101", "debit": "50000000"}, {"account": "1101", "credit": "50000000"}]}',
          jsonb_build_object('ok', p_valid), p_valid, now() + interval '1 day')
  RETURNING id INTO v;
  RETURN v;
END $$;

-- مستأجر A: سیاست، دوره‌های مصرف، رضایت اول، رشتهٔ a1
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  INSERT INTO assistant.tenant_policy (tenant_id, id, source, document, signature, signer_kid)
  VALUES (public.k('A'), public.k('polA'), 'dev_fixture',
          public.as_policy_doc(1, '{chat,proposals,migration_mapping}', public.fp('P'), ARRAY[public.fp('S')], true, 100000, '5000000', 50000, 2),
          decode(repeat('ab', 64), 'hex'), 'dev-key');
  INSERT INTO assistant.usage_period (tenant_id, id, scope, user_id, period_start, period_end, token_limit, cost_limit, cost_unit, limit_source) VALUES
    (public.k('A'), public.k('uA'),  'tenant', NULL,           current_date - 10, current_date + 20, 100000, 5000000, 'IRR', 'policy'),
    (public.k('A'), public.k('ua1'), 'user',   public.k('a1'), current_date - 10, current_date + 20, 50000,  NULL,    'IRR', 'policy'),
    (public.k('A'), public.k('ua2'), 'user',   public.k('a2'), current_date - 10, current_date + 20, 50000,  NULL,    'IRR', 'policy'),
    (public.k('A'), public.k('ua3'), 'user',   public.k('a3'), current_date - 10, current_date + 20, 50000,  NULL,    'IRR', 'policy');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_grant_consent(public.k('cA1'), '{chat,migration_mapping}',
                                  '{financial_aggregate,reference_names,item_name,party_name,document_detail}', ARRAY[public.fp('P'), public.fp('S')]);
  INSERT INTO assistant.thread (tenant_id, id, user_id, company_id, title) VALUES (public.k('A'), public.k('tA1'), public.k('a1'), public.k('A.C1'), 'تراز ماه');
END $T$;

-- مستأجر B
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('B'), NULL);
  INSERT INTO assistant.tenant_policy (tenant_id, id, source, document, signature, signer_kid)
  VALUES (public.k('B'), public.k('polB'), 'dev_fixture',
          public.as_policy_doc(1, '{chat}', public.fp('P'), NULL, false, 100000, NULL, 50000, 3),
          decode(repeat('cd', 64), 'hex'), 'dev-key');
  INSERT INTO assistant.usage_period (tenant_id, id, scope, user_id, period_start, period_end, token_limit, limit_source) VALUES
    (public.k('B'), public.k('uB'),  'tenant', NULL,           current_date - 10, current_date + 20, 100000, 'policy'),
    (public.k('B'), public.k('ub1'), 'user',   public.k('b1'), current_date - 10, current_date + 20, 50000,  'policy');
  PERFORM public.as_ctx(public.k('B'), public.k('b1'));
  PERFORM public.as_grant_consent(public.k('cB1'), '{chat}', '{financial_aggregate}', ARRAY[public.fp('P')]);
  INSERT INTO assistant.thread (tenant_id, id, user_id, company_id, title) VALUES (public.k('B'), public.k('tB1'), public.k('b1'), public.k('B.C1'), 'فروش امروز');
END $T$;

-- =====================================================================
-- بخش ۲: assertها با hk_app
-- =====================================================================
SET ROLE hk_app;

-- T01b: کاتالوگ فقط با migration نوشته می‌شود
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T01b app cannot add tools',
    $q$INSERT INTO assistant.tool (code, version, kind, module, service_ref, phase, introduced_in)
       VALUES ('ledger.post_anything', 1, 'query', 'ledger', 'hesabketab.ledger.api.services:LedgerPostingService.post', 'v1', '1.0')$q$, '42501');
  PERFORM public.as_expect_error('T01b app cannot widen the ceiling',
    $q$INSERT INTO assistant.tool_permission VALUES ('ledger.trial_balance', 'ledger.journal.read', 'read')$q$, '42501');
  PERFORM public.as_assert((SELECT count(*) FROM assistant.tool) >= 19, 'T01b tool catalog readable');
END $T$;

-- T02: سیاست مستأجر (ستون‌ها تولیدی از سند امضاشده‌اند؛ RV-AST-10)
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_expect_error('T02 policy version must increase',
    $q$UPDATE assistant.tenant_policy SET document = jsonb_set(document, '{quotas,max_rounds}', '5')$q$, 'HK_AST_POLICY_VERSION');
  PERFORM public.as_expect_error('T02 replayed older policy rejected',
    $q$UPDATE assistant.tenant_policy SET document = jsonb_set(document, '{policy_version}', '0')$q$, 'HK_AST_POLICY_VERSION');
  PERFORM public.as_expect_error('T02 document without a version rejected',
    $q$UPDATE assistant.tenant_policy SET document = document - 'policy_version'$q$, 'HK_AST_POLICY_VERSION');
  PERFORM public.as_expect_error('T02 disabled needs a reason',
    $q$SELECT public.as_policy_patch('{"enabled": false}')$q$, '23514');
  PERFORM public.as_expect_error('T02 enabled tenant needs a provider source',
    $q$SELECT public.as_policy_patch('{"profile": null, "allow_tenant_provider": false}')$q$, '23514');
  PERFORM public.as_expect_error('T02 policy without a platform profile and no tenant provider stays dark',
    $q$SELECT public.as_policy_patch('{"profile": null, "secondary_fingerprints": [], "allow_tenant_provider": null}')$q$, '23514');
  PERFORM public.as_expect_error('T02 signature is Ed25519 sized',
    $q$UPDATE assistant.tenant_policy SET document = jsonb_set(document, '{policy_version}', to_jsonb(policy_version + 1)), signature = '\x00'::bytea$q$, '23514');
  PERFORM public.as_expect_error('T02 secondary fingerprints are hex64',
    $q$SELECT public.as_policy_patch('{"secondary_fingerprints": ["abc"]}')$q$, '23514');
  PERFORM public.as_expect_error('T02 features must be a JSON array',
    $q$SELECT public.as_policy_patch('{"features": "chat"}')$q$, 'HK_AST_POLICY_DOCUMENT');
  PERFORM public.as_expect_error('T02 unknown feature rejected',
    $q$SELECT public.as_policy_patch('{"features": ["chat", "autopilot"]}')$q$, '23514');
  PERFORM public.as_expect_error('T02 at least two rounds (tools + final answer)',
    $q$SELECT public.as_policy_patch('{"quotas": {"max_rounds": 1}}')$q$, '23514');
  PERFORM public.as_expect_error('T02 document must say whether the tenant is entitled',
    $q$UPDATE assistant.tenant_policy SET document = (document - 'entitled') || jsonb_build_object('policy_version', policy_version + 1)$q$, '23502');
  PERFORM public.as_expect_error('T02 one policy row per tenant',
    $q$INSERT INTO assistant.tenant_policy (tenant_id, source, document, signature, signer_kid)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'dev_fixture', '{"policy_version": 9, "entitled": false, "enabled": false, "kill_reason": "off"}',
               decode(repeat('ab', 64), 'hex'), 'dev-key')$q$, '23505');
  PERFORM public.as_expect_error('T02 policy cannot be deleted by the app', $q$DELETE FROM assistant.tenant_policy$q$, '42501');
  PERFORM public.as_expect_error('T02 policy identity immutable',
    $q$UPDATE assistant.tenant_policy SET document = jsonb_set(document, '{policy_version}', to_jsonb(policy_version + 1)), id = uuidv7()$q$, 'HK_AST_POLICY_VERSION');
  -- RV-AST-10: ستون اجباری سیاست را هیچ نویسنده‌ای جدا از سند امضاشده نمی‌نویسد
  PERFORM public.as_expect_error('T02 kill switch column cannot diverge from the signed document',
    $q$UPDATE assistant.tenant_policy SET platform_enabled = true$q$, '428C9');
  PERFORM public.as_expect_error('T02 budget columns cannot diverge from the signed document',
    $q$UPDATE assistant.tenant_policy SET tenant_monthly_tokens = NULL$q$, '428C9');
  PERFORM public.as_policy_patch('{"note": "v2"}');
  PERFORM public.as_assert((SELECT policy_version = 2 AND row_version = 2 AND entitled AND platform_enabled AND max_rounds = 6
                                   AND tenant_monthly_tokens = 100000 AND tenant_monthly_cost = 5000000 AND cost_unit = 'IRR'
                                   AND features = '{chat,proposals,migration_mapping}' AND secondary_fingerprints = ARRAY[public.fp('S')]
                              FROM assistant.tenant_policy), 'T02 policy v2 applied; columns derived from the document');
  PERFORM public.as_assert((SELECT document_sha256 = sha256(convert_to(document::text, 'UTF8')) FROM assistant.tenant_policy), 'T02 document hash generated');
  PERFORM set_config('app.actor_via', 'assistant', true);
  PERFORM public.as_expect_error('T02 assistant-originated tx cannot touch policy',
    $q$SELECT public.as_policy_patch('{"note": "x"}')$q$, 'HK_AST_VIA_ASSISTANT');
END $T$;

-- T03: رضایت پردازش داده
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T03 consent granted by the current user',
    format($q$SELECT public.as_grant_consent(NULL, '{chat}', '{financial_aggregate}', ARRAY[%L], %L)$q$, public.fp('P'), public.k('a2')),
    'HK_AST_CONSENT_STATE');
  PERFORM public.as_expect_error('T03 prohibited data class cannot be consented',
    format($q$SELECT public.as_grant_consent(NULL, '{chat}', '{financial_aggregate,contact_pii}', ARRAY[%L])$q$, public.fp('P')),
    'HK_AST_CONSENT_SCOPE');
  PERFORM public.as_expect_error('T03 unknown data class',
    format($q$SELECT public.as_grant_consent(NULL, '{chat}', '{everything}', ARRAY[%L])$q$, public.fp('P')), 'HK_AST_CONSENT_SCOPE');
  PERFORM public.as_expect_error('T03 unknown purpose',
    format($q$SELECT public.as_grant_consent(NULL, '{marketing}', '{financial_aggregate}', ARRAY[%L])$q$, public.fp('P')), 'HK_AST_CONSENT_SCOPE');
  PERFORM public.as_expect_error('T03 consent needs fresh MFA',
    format($q$SELECT public.as_grant_consent(NULL, '{chat}', '{financial_aggregate}', ARRAY[%L], NULL, interval '20 minutes')$q$, public.fp('P')),
    '23514');
  PERFORM public.as_expect_error('T03 fingerprints are hex64',
    $q$SELECT public.as_grant_consent(NULL, '{chat}', '{financial_aggregate}', ARRAY['not-a-fingerprint'])$q$, '23514');
  PERFORM public.as_expect_error('T03 superseded only by a new grant',
    format($q$UPDATE assistant.consent SET status = 'superseded', superseded_by = %L, ended_at = now() WHERE id = %L$q$, public.k('cA1'), public.k('cA1')),
    'HK_AST_CONSENT_STATE');
  PERFORM public.as_expect_error('T03 consent terms immutable (even when revoking)',
    format($q$UPDATE assistant.consent SET purposes = '{chat,document_ocr}', status = 'revoked', ended_by = %L, end_reason = 'آزمون' WHERE id = %L$q$,
           public.k('a1'), public.k('cA1')), 'HK_AST_CONSENT_STATE');
  PERFORM public.as_expect_error('T03 active consent only revoked or superseded',
    format($q$UPDATE assistant.consent SET end_reason = 'یادداشت' WHERE id = %L$q$, public.k('cA1')), 'HK_AST_CONSENT_STATE');
  PERFORM public.as_expect_error('T03 consent is created active',
    format($q$INSERT INTO assistant.consent (tenant_id, status, purposes, data_classes, provider_fingerprints, provider_summary, consent_text_code,
                                            consent_text_sha256, granted_by, signer_full_name, signer_capacity, mfa_at, ended_at, ended_by, end_reason)
              VALUES (%L, 'revoked', '{chat}', '{financial_aggregate}', ARRAY[%L], '[{"operator": "x"}]', 'assistant.consent.v1',
                      sha256('\x00'::bytea), %L, 'مالک الف', 'owner', now(), now(), %L, 'پیشاپیش لغو')$q$,
           public.k('A'), public.fp('P'), public.k('a1'), public.k('a1')), 'HK_AST_CONSENT_STATE');
  PERFORM public.as_expect_error('T03 revoked by the current user',
    format($q$UPDATE assistant.consent SET status = 'revoked', ended_by = %L, end_reason = 'لغو آزمایشی' WHERE id = %L$q$, public.k('a2'), public.k('cA1')),
    'HK_AST_CONSENT_STATE');
  PERFORM public.as_expect_error('T03 revoke needs a reason',
    format($q$UPDATE assistant.consent SET status = 'revoked', ended_by = %L WHERE id = %L$q$, public.k('a1'), public.k('cA1')), '23514');
  PERFORM public.as_expect_error('T03 consent rows are never deleted', $q$DELETE FROM assistant.consent$q$, '42501');
  PERFORM set_config('app.impersonation_session_id', '80a00000-0000-7000-8000-00000000dead', true);
  PERFORM public.as_expect_error('T03 no consent under impersonation',
    format($q$SELECT public.as_grant_consent(NULL, '{chat}', '{financial_aggregate}', ARRAY[%L])$q$, public.fp('P')), 'HK_AST_IMPERSONATION');
  PERFORM set_config('app.impersonation_session_id', '', true);
  PERFORM set_config('app.actor_via', 'assistant', true);
  PERFORM public.as_expect_error('T03 the assistant cannot consent for itself',
    format($q$SELECT public.as_grant_consent(NULL, '{chat}', '{financial_aggregate}', ARRAY[%L])$q$, public.fp('P')), 'HK_AST_VIA_ASSISTANT');
  PERFORM set_config('app.actor_via', '', true);
  -- رضایت تازه رضایت قبلی را جایگزین می‌کند
  PERFORM public.as_grant_consent(public.k('cA2'), '{chat}',
                                  '{financial_aggregate,reference_names,item_name,party_name,document_detail}',
                                  ARRAY[public.fp('P'), public.fp('S'), public.fp('X')]);
  PERFORM public.as_assert((SELECT status = 'superseded' AND superseded_by = public.k('cA2') AND ended_at IS NOT NULL
                              FROM assistant.consent WHERE id = public.k('cA1')), 'T03 previous consent superseded');
  PERFORM public.as_assert((SELECT count(*) FROM assistant.consent WHERE status = 'active') = 1, 'T03 exactly one active consent');
  PERFORM public.as_expect_error('T03 superseded consent is final',
    format($q$UPDATE assistant.consent SET status = 'revoked', ended_by = %L, end_reason = 'آزمون' WHERE id = %L$q$, public.k('a1'), public.k('cA1')),
    'HK_AST_CONSENT_STATE');
END $T$;

-- T04: دورهٔ مصرف (سقف ردیف هرگز بیش از سیاست امضاشده؛ شمارنده‌ها فقط از سنجش)
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_expect_error('T04 user scope needs a user',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, token_limit, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'user', current_date + 40, current_date + 60, 10, 'policy')$q$, '23514');
  PERFORM public.as_expect_error('T04 overlapping periods rejected',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, token_limit, cost_limit, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'tenant', current_date - 5, current_date + 25, 10, 10, 'policy')$q$, '23P01');
  PERFORM public.as_expect_error('T04 unlimited period has no limit',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, user_id, period_start, period_end, token_limit, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'user', '80a00000-0000-7000-8000-0000000000a3', current_date + 40, current_date + 60, 10, 'unlimited')$q$, '23514');
  PERFORM public.as_expect_error('T04 period at most 62 days',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, token_limit, cost_limit, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'tenant', current_date + 40, current_date + 140, 10, 10, 'policy')$q$, '23514');
  PERFORM public.as_expect_error('T04 user of another tenant',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, user_id, period_start, period_end, token_limit, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'user', '80b00000-0000-7000-8000-0000000000b1', current_date + 40, current_date + 60, 10, 'policy')$q$,
    '23503');
  PERFORM public.as_expect_error('T04 period bounds not writable by the app (column grant)',
    format($q$UPDATE assistant.usage_period SET period_start = period_start - 1 WHERE id = %L$q$, public.k('uA')), '42501');
  PERFORM public.as_expect_error('T04 only limit columns are writable',
    format($q$UPDATE assistant.usage_period SET scope = 'user' WHERE id = %L$q$, public.k('uA')), '42501');
  PERFORM public.as_expect_error('T04 recent period cannot be deleted',
    format($q$DELETE FROM assistant.usage_period WHERE id = %L$q$, public.k('ua3')), 'HK_AST_RETENTION');
  -- RV-AST-10: سقف هر دوره حداکثر سقف سیاست امضاشده است؛ بی‌سقف فقط اگر سیاست هم بی‌سقف باشد
  PERFORM public.as_expect_error('T04 tenant token limit cannot exceed the signed policy',
    format($q$UPDATE assistant.usage_period SET token_limit = 999999999 WHERE id = %L$q$, public.k('uA')), 'HK_AST_USAGE_LIMIT');
  PERFORM public.as_expect_error('T04 tenant period cannot be unlimited under a capped plan',
    format($q$UPDATE assistant.usage_period SET token_limit = NULL, cost_limit = NULL, limit_source = 'unlimited' WHERE id = %L$q$, public.k('uA')),
    'HK_AST_USAGE_LIMIT');
  PERFORM public.as_expect_error('T04 tenant cost limit cannot exceed the signed policy',
    format($q$UPDATE assistant.usage_period SET cost_limit = 5000001 WHERE id = %L$q$, public.k('uA')), 'HK_AST_USAGE_LIMIT');
  PERFORM public.as_expect_error('T04 user token limit capped by the policy',
    format($q$UPDATE assistant.usage_period SET token_limit = 999999999 WHERE scope = 'user' AND id = %L$q$, public.k('ua3')), 'HK_AST_USAGE_LIMIT');
  PERFORM public.as_expect_error('T04 user period cannot be unlimited under a capped plan',
    format($q$UPDATE assistant.usage_period SET token_limit = NULL, limit_source = 'unlimited' WHERE id = %L$q$, public.k('ua3')), 'HK_AST_USAGE_LIMIT');
  PERFORM public.as_expect_error('T04 cost unit equals the policy unit',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, token_limit, cost_limit, cost_unit, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'tenant', current_date + 40, current_date + 60, 10, 10, 'IRT', 'policy')$q$, 'HK_AST_USAGE_LIMIT');
  PERFORM public.as_expect_error('T04 a period starts with zero counters',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, token_limit, cost_limit, limit_source, tokens_charged)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'tenant', current_date + 40, current_date + 60, 10, 10, 'policy', 5)$q$, 'HK_AST_USAGE_IMMUTABLE');
  PERFORM public.as_expect_error('T04 counters are written only by model-call metering',
    format($q$UPDATE assistant.usage_period SET tokens_charged = tokens_charged + 5 WHERE id = %L$q$, public.k('uA')), 'HK_AST_USAGE_IMMUTABLE');
  UPDATE assistant.usage_period SET token_limit = 90000 WHERE id = public.k('uA');
  UPDATE assistant.usage_period SET token_limit = 100000 WHERE id = public.k('uA');
  PERFORM public.as_assert((SELECT row_version = 3 FROM assistant.usage_period WHERE id = public.k('uA')), 'T04 limits updatable with row_version');
END $T$;

-- T05: رشته و دید «فقط صاحب»
DO $T$
DECLARE n integer;
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  INSERT INTO assistant.thread (tenant_id, id, user_id, company_id) VALUES (public.k('A'), public.k('tA2'), public.k('a1'), public.k('A.C1'));
  PERFORM public.as_assert((SELECT title = 'گفت‌وگوی تازه' AND message_count = 0 FROM assistant.thread WHERE id = public.k('tA2')), 'T05 thread defaults');
  PERFORM public.as_expect_error('T05 thread is created by its owner only',
    format($q$INSERT INTO assistant.thread (tenant_id, user_id, company_id) VALUES (%L, %L, %L)$q$, public.k('A'), public.k('a2'), public.k('A.C1')), '42501');
  PERFORM public.as_expect_error('T05 title must be normalized (Arabic yeh)',
    format($q$INSERT INTO assistant.thread (tenant_id, user_id, company_id, title) VALUES (%L, %L, %L, 'گفتگوي')$q$,
           public.k('A'), public.k('a1'), public.k('A.C1')), '23514');
  PERFORM public.as_expect_error('T05 thread company of another tenant',
    format($q$INSERT INTO assistant.thread (tenant_id, user_id, company_id) VALUES (%L, %L, %L)$q$, public.k('A'), public.k('a1'), public.k('B.C1')), '23503');
  PERFORM public.as_expect_error('T05 a new thread has no messages',
    format($q$INSERT INTO assistant.thread (tenant_id, user_id, company_id, message_count) VALUES (%L, %L, %L, 5)$q$, public.k('A'), public.k('a1'), public.k('A.C1')),
    'HK_AST_THREAD_IMMUTABLE');
  PERFORM public.as_expect_error('T05 message_count is maintained by messages',
    format($q$UPDATE assistant.thread SET message_count = 5 WHERE id = %L$q$, public.k('tA2')), 'HK_AST_THREAD_IMMUTABLE');
  PERFORM public.as_expect_error('T05 thread company immutable',
    format($q$UPDATE assistant.thread SET company_id = %L WHERE id = %L$q$, public.k('A.C2'), public.k('tA2')), 'HK_AST_THREAD_IMMUTABLE');
  UPDATE assistant.thread SET title = 'خلاصهٔ فروش' WHERE id = public.k('tA2');
  PERFORM public.as_assert((SELECT row_version = 2 FROM assistant.thread WHERE id = public.k('tA2')), 'T05 rename bumps row_version');
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  INSERT INTO assistant.thread (tenant_id, id, user_id, company_id) VALUES (public.k('A'), public.k('tA21'), public.k('a2'), public.k('A.C1'));
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread WHERE user_id = public.k('a1')) = 0, 'T05 a2 cannot see threads of a1');
  UPDATE assistant.thread SET title = 'دزدیده' WHERE id = public.k('tA2');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.as_assert(n = 0, 'T05 a2 cannot rename a1 thread');
  PERFORM public.as_ctx(public.k('A'), public.k('a3'));
  INSERT INTO assistant.thread (tenant_id, id, user_id, company_id) VALUES (public.k('A'), public.k('tA31'), public.k('a3'), public.k('A.C2'));
  -- RV-AST-01، RV-X4-09: «بدون کاربر» دیگر زمینهٔ سیستمی نیست؛ فقط هدف سیستمی ثبت‌شده محتوا را می‌بیند
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread) = 0, 'T05 tenant context without a user sees no conversation');
  PERFORM set_config('hk.assistant_system', 'export', true);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread) = 0, 'T05 an unregistered system purpose sees no conversation');
  PERFORM set_config('hk.assistant_system', 'placement_move:80a00000-0000-7000-8000-0000000bb001', true);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread) = 0, 'T05 a placement move needs a running staff export');
  PERFORM set_config('hk.assistant_system', 'retention', true);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread) = 4, 'T05 a registered system purpose (retention) sees every thread');
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM set_config('hk.assistant_system', 'retention', true);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread) = 1, 'T05 a system purpose does not widen a user context');
  PERFORM set_config('hk.assistant_system', '', true);
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM set_config('app.impersonation_session_id', '80a00000-0000-7000-8000-00000000dead', true);
  PERFORM set_config('hk.assistant_system', 'retention', true);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread) = 0, 'T05 no system purpose under impersonation');
  PERFORM set_config('hk.assistant_system', '', true);
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM set_config('app.impersonation_session_id', '80a00000-0000-7000-8000-00000000dead', true);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread) = 0, 'T05 impersonation sees no conversation, not even of the impersonated user');
  PERFORM public.as_expect_error('T05 no thread is created under impersonation',
    format($q$INSERT INTO assistant.thread (tenant_id, user_id, company_id) VALUES (%L, %L, %L)$q$, public.k('A'), public.k('a1'), public.k('A.C1')), '42501');
END $T$;

-- T06: اجرا — سیاست، رضایت، ارائه‌دهنده، مصرف، هم‌زمانی
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  -- RV-AST-14: اجرا در شرکت رشتهٔ خودش است (FK چهارستونی)
  PERFORM public.as_expect_error('T06 run company must equal its thread company',
    format($q$SELECT public.as_new_run(NULL, %L, p_company => %L)$q$, public.k('tA1'), public.k('A.C2')), '23503');
  PERFORM public.as_new_run(public.k('rA1'), public.k('tA1'));
  PERFORM public.as_assert((SELECT status = 'running' AND finished_at IS NULL FROM assistant.run WHERE id = public.k('rA1')), 'T06 run created');
  PERFORM public.as_expect_error('T06 one running run per user',
    format($q$SELECT public.as_new_run(NULL, %L)$q$, public.k('tA2')), '23505');
  PERFORM public.as_expect_error('T06 run belongs to the current user',
    format($q$SELECT public.as_new_run(NULL, %L, p_user => %L)$q$, public.k('tA21'), public.k('a2')), 'HK_AST_RUN_STATE');
  PERFORM public.as_expect_error('T06 chat run needs a thread', $q$SELECT public.as_new_run(NULL, NULL)$q$, 'HK_AST_RUN_STATE');
  PERFORM public.as_expect_error('T06 run is created running',
    format($q$SELECT public.as_new_run(NULL, %L, p_status => 'completed')$q$, public.k('tA2')), 'HK_AST_RUN_STATE');
  PERFORM public.as_expect_error('T06 run built on a stale policy',
    format($q$SELECT public.as_new_run(NULL, %L, p_policy_version => 1)$q$, public.k('tA2')), 'HK_AST_POLICY_STALE');
  PERFORM public.as_expect_error('T06 purpose not covered by consent',
    format($q$SELECT public.as_new_run(NULL, %L, p_purpose => 'migration_mapping')$q$, public.k('tA2')), 'HK_AST_CONSENT');
  PERFORM public.as_expect_error('T06 destination not covered by consent',
    format($q$SELECT public.as_new_run(NULL, %L, p_fp => %L)$q$, public.k('tA2'), public.fp('L')), 'HK_AST_CONSENT');
  PERFORM public.as_expect_error('T06 consented destination not in the tenant policy',
    format($q$SELECT public.as_new_run(NULL, %L, p_fp => %L)$q$, public.k('tA2'), public.fp('X')), 'HK_AST_PROVIDER');
  PERFORM public.as_expect_error('T06 consent missing',
    format($q$SELECT public.as_new_run(NULL, %L, p_consent => %L)$q$, public.k('tA2'), public.k('cA1')), 'HK_AST_CONSENT');
  PERFORM public.as_expect_error('T06 usage rows must match scopes',
    format($q$SELECT public.as_new_run(NULL, %L, p_tenant_usage => %L, p_user_usage => %L)$q$, public.k('tA2'), public.k('ua1'), public.k('uA')),
    'HK_AST_USAGE_ROW');
  PERFORM public.as_expect_error('T06 usage row of another user',
    format($q$SELECT public.as_new_run(NULL, %L, p_user_usage => %L)$q$, public.k('tA2'), public.k('ua2')), 'HK_AST_USAGE_ROW');
  PERFORM public.as_expect_error('T06 lease must be in the future',
    format($q$SELECT public.as_new_run(NULL, %L, p_lease => interval '-1 minute')$q$, public.k('tA2')), 'HK_AST_RUN_STATE');
  PERFORM public.as_expect_error('T06 lease at most 15 minutes',
    format($q$SELECT public.as_new_run(NULL, %L, p_lease => interval '20 minutes')$q$, public.k('tA2')), '23514');
  PERFORM public.as_expect_error('T06 tenant provider path needs an active provider',
    format($q$SELECT public.as_new_run(NULL, %L, p_source => 'tenant', p_tp => NULL)$q$, public.k('tA2')), 'HK_AST_PROVIDER');
  PERFORM set_config('app.impersonation_session_id', '80a00000-0000-7000-8000-00000000dead', true);
  PERFORM public.as_expect_error('T06 no assistant under impersonation',
    format($q$SELECT public.as_new_run(NULL, %L)$q$, public.k('tA2')), 'HK_AST_IMPERSONATION');
END $T$;

DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_new_run(public.k('rA2'), public.k('tA21'), p_fp => public.fp('S'));
  PERFORM public.as_ctx(public.k('A'), public.k('a3'));
  PERFORM public.as_expect_error('T06 tenant concurrency cap (2 running)',
    format($q$SELECT public.as_new_run(NULL, %L)$q$, public.k('tA31')), 'HK_AST_CONCURRENCY');
  -- RV-AST-07: سیاست بدون پروفایل پلتفرم (فقط ارائه‌دهندهٔ مستأجر) هیچ اجرای platform نمی‌پذیرد، حتی با مقصدِ در رضایت
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch('{"profile": null, "secondary_fingerprints": [], "allow_tenant_provider": true}');
  PERFORM public.as_ctx(public.k('A'), public.k('a3'));
  PERFORM public.as_expect_error('T06 platform run when the policy has no platform profile',
    format($q$SELECT public.as_new_run(NULL, %L, p_fp => %L)$q$, public.k('tA31'), public.fp('P')), 'HK_AST_PROVIDER');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch(jsonb_build_object('profile', jsonb_build_object('code', 'ir-main', 'version', 3, 'fingerprint', public.fp('P')),
                                                    'secondary_fingerprints', jsonb_build_array(public.fp('S'))));
  -- کلید قطع مستأجر
  PERFORM public.as_policy_patch('{"enabled": false, "kill_reason": "خاموشی اضطراری"}');
  PERFORM public.as_ctx(public.k('A'), public.k('a3'));
  PERFORM public.as_expect_error('T06 kill switch blocks new runs',
    format($q$SELECT public.as_new_run(NULL, %L)$q$, public.k('tA31')), 'HK_AST_DISABLED');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch('{"enabled": true, "kill_reason": null, "features": ["chat", "proposals"]}');
  PERFORM public.as_ctx(public.k('A'), public.k('a3'));
  PERFORM public.as_expect_error('T06 feature not in plan',
    format($q$SELECT public.as_new_run(NULL, %L, p_purpose => 'migration_mapping')$q$, public.k('tA31')), 'HK_AST_DISABLED');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch('{"entitled": false}');
  PERFORM public.as_ctx(public.k('A'), public.k('a3'));
  PERFORM public.as_expect_error('T06 plan without assistant',
    format($q$SELECT public.as_new_run(NULL, %L)$q$, public.k('tA31')), 'HK_AST_DISABLED');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch('{"entitled": true, "features": ["chat", "proposals", "migration_mapping"]}');
  -- ستون‌های هویتی و lease
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T06 run identity immutable',
    format($q$UPDATE assistant.run SET model = 'other-model' WHERE id = %L$q$, public.k('rA1')), 'HK_AST_RUN_STATE');
  PERFORM public.as_expect_error('T06 run lease cannot shrink',
    format($q$UPDATE assistant.run SET lease_expires_at = lease_expires_at - interval '1 minute' WHERE id = %L$q$, public.k('rA1')), 'HK_AST_RUN_STATE');
  PERFORM public.as_expect_error('T06 direct detach from thread forbidden',
    format($q$UPDATE assistant.run SET thread_id = NULL WHERE id = %L$q$, public.k('rA1')), 'HK_AST_RUN_STATE');
  PERFORM public.as_expect_error('T06 running run cannot be deleted',
    format($q$DELETE FROM assistant.run WHERE id = %L$q$, public.k('rA1')), 'HK_AST_RETENTION');
  UPDATE assistant.run SET lease_expires_at = lease_expires_at + interval '1 minute' WHERE id = public.k('rA1');
END $T$;

-- T07: فراخوانی مدل و بودجه
DO $T$
DECLARE t record;
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_new_call(public.k('cl11'), public.k('rA1'), 1, 1000, 500);
  SELECT * INTO t FROM assistant.v_usage WHERE id = public.k('ua1');
  PERFORM public.as_assert(t.tokens_committed = 1500 AND t.in_flight = 1 AND t.tokens_charged = 0, 'T07 reservation counted');
  -- RV-AST-06: یک دور در جریان برای هر اجرا
  PERFORM public.as_expect_error('T07 one round in flight per run',
    format($q$SELECT public.as_new_call(NULL, %L, 2)$q$, public.k('rA1')), 'HK_AST_ROUND_ORDER');
  PERFORM public.as_expect_error('T07 call must use the run usage rows',
    format($q$SELECT public.as_new_call(NULL, %L, 2, p_tenant_usage => %L)$q$, public.k('rA1'), public.k('ua2')), 'HK_AST_LLM_STATE');
  PERFORM public.as_expect_error('T07 completed needs usage',
    format($q$UPDATE assistant.llm_call SET status = 'completed' WHERE id = %L$q$, public.k('cl11')), '23514');
  PERFORM public.as_expect_error('T07 abandon only after lease expiry',
    format($q$UPDATE assistant.llm_call SET status = 'abandoned' WHERE id = %L$q$, public.k('cl11')), 'HK_AST_LLM_STATE');
  PERFORM public.as_expect_error('T07 reservation immutable',
    format($q$UPDATE assistant.llm_call SET reserved_prompt_tokens = 1 WHERE id = %L$q$, public.k('cl11')), 'HK_AST_LLM_STATE');
  PERFORM public.as_expect_error('T07 price snapshot immutable',
    format($q$UPDATE assistant.llm_call SET input_price_per_mtok = 0 WHERE id = %L$q$, public.k('cl11')), 'HK_AST_LLM_STATE');
  PERFORM public.as_expect_error('T07 in-flight lease cannot shrink',
    format($q$UPDATE assistant.llm_call SET lease_expires_at = lease_expires_at - interval '1 minute' WHERE id = %L$q$, public.k('cl11')), 'HK_AST_LLM_STATE');
  PERFORM public.as_finish_call(public.k('cl11'), 800, 300, 'tool_calls');
  PERFORM public.as_assert((SELECT charged_cost = 40 AND reserved_cost = 60 AND finished_at IS NOT NULL FROM assistant.llm_call WHERE id = public.k('cl11')),
                           'T07 cost generated from price snapshot (800*20000+300*80000)/1e6 = 40');
  SELECT * INTO t FROM assistant.v_usage WHERE id = public.k('ua1');
  PERFORM public.as_assert(t.tokens_committed = 1100 AND t.tokens_charged = 1100 AND t.in_flight = 0 AND t.tokens_remaining = 48900, 'T07 settlement replaces reservation');
  PERFORM public.as_expect_error('T07 terminal call is final',
    format($q$UPDATE assistant.llm_call SET status = 'failed', error_code = 'assistant.llm.timeout' WHERE id = %L$q$, public.k('cl11')), 'HK_AST_LLM_STATE');
  PERFORM public.as_expect_error('T07 user token budget',
    format($q$SELECT public.as_new_call(NULL, %L, 2, 60000, 500)$q$, public.k('rA1')), 'HK_AST_BUDGET_TOKENS');
  PERFORM public.as_expect_error('T07 round cap from policy',
    format($q$SELECT public.as_new_call(NULL, %L, 7)$q$, public.k('rA1')), 'HK_AST_ROUND_CAP');
  PERFORM public.as_expect_error('T07 a round number is never reused',
    format($q$SELECT public.as_new_call(NULL, %L, 1)$q$, public.k('rA1')), 'HK_AST_ROUND_ORDER');
  -- RV-AST-06: دورها پیاپی‌اند (بدون جهش شماره)
  PERFORM public.as_expect_error('T07 rounds are consecutive',
    format($q$SELECT public.as_new_call(NULL, %L, 3)$q$, public.k('rA1')), 'HK_AST_ROUND_ORDER');
  PERFORM public.as_expect_error('T07 price unit must match cost budget unit',
    format($q$SELECT public.as_new_call(NULL, %L, 2, 1000, 500, 'IRT')$q$, public.k('rA1')), 'HK_AST_BUDGET_UNIT');
  PERFORM public.as_expect_error('T07 call is created in flight without usage',
    format($q$SELECT public.as_new_call(NULL, %L, 2, p_completed => true)$q$, public.k('rA1')), 'HK_AST_LLM_STATE');
  PERFORM public.as_expect_error('T07 call lease must be in the future',
    format($q$SELECT public.as_new_call(NULL, %L, 2, p_lease => interval '-1 minute')$q$, public.k('rA1')), 'HK_AST_LLM_STATE');
  PERFORM public.as_expect_error('T07 lease at most 10 minutes',
    format($q$SELECT public.as_new_call(NULL, %L, 2, p_lease => interval '11 minutes')$q$, public.k('rA1')), '23514');
END $T$;

DO $T$
BEGIN
  -- a2 رزرو بزرگی دارد؛ سقف مستأجر کم می‌شود
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_new_call(public.k('cl21'), public.k('rA2'), 1, 20000, 500);
  PERFORM public.as_ctx(public.k('A'), NULL);
  UPDATE assistant.usage_period SET token_limit = 30000 WHERE id = public.k('uA');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T07 tenant token budget counts other users in flight',
    format($q$SELECT public.as_new_call(NULL, %L, 2, 8000, 500)$q$, public.k('rA1')), 'HK_AST_BUDGET_TOKENS');
  PERFORM public.as_ctx(public.k('A'), NULL);
  UPDATE assistant.usage_period SET token_limit = 100000, cost_limit = 500 WHERE id = public.k('uA');
  PERFORM public.as_assert((SELECT cost_committed = 480 FROM assistant.v_usage WHERE id = public.k('uA')), 'T07 committed cost = 40 charged + 440 reserved');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T07 tenant cost budget',
    format($q$SELECT public.as_new_call(NULL, %L, 2, 1000, 500)$q$, public.k('rA1')), 'HK_AST_BUDGET_COST');
  PERFORM public.as_ctx(public.k('A'), NULL);
  UPDATE assistant.usage_period SET cost_limit = 5000000 WHERE id = public.k('uA');
  -- کلید قطع وسط اجرا: دور بعدی رد می‌شود
  PERFORM public.as_policy_patch('{"enabled": false, "kill_reason": "خاموشی سراسری"}');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T07 kill switch stops the next round',
    format($q$SELECT public.as_new_call(NULL, %L, 2)$q$, public.k('rA1')), 'HK_AST_DISABLED');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch('{"enabled": true, "kill_reason": null}');
  -- RV-AST-06: کاهش پلن وسط اجرا (حذف ویژگی هدف) دور بعد را می‌بندد
  PERFORM public.as_policy_patch('{"features": ["proposals"]}');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T07 feature removed mid-run stops the next round',
    format($q$SELECT public.as_new_call(NULL, %L, 2)$q$, public.k('rA1')), 'HK_AST_DISABLED');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch('{"features": ["chat", "proposals", "migration_mapping"]}');
  -- RV-AST-11: کاهش سقف در سیاست، حتی پیش از به‌روزرسانی ردیف دوره، در لحظهٔ رزرو اعمال می‌شود (سقف مؤثر = کمینه)
  PERFORM public.as_policy_patch('{"quotas": {"tenant_monthly_tokens": 1500}}');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T07 lowered policy cap applies before the period row is synced',
    format($q$SELECT public.as_new_call(NULL, %L, 2, 1000, 500)$q$, public.k('rA1')), 'HK_AST_BUDGET_TOKENS');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch('{"quotas": {"tenant_monthly_tokens": 100000}}');
  -- خطای ارائه‌دهنده و لغو کاربر
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_expect_error('T07 failed needs an error code',
    format($q$UPDATE assistant.llm_call SET status = 'failed' WHERE id = %L$q$, public.k('cl21')), '23514');
  -- RV-AST-03: کد پایدار LlmError با رقم (http_5xx) پذیرفته است؛ پیش‌تر CHECK آن را رد می‌کرد و دور در جریان می‌ماند
  UPDATE assistant.llm_call SET status = 'failed', error_code = 'assistant.llm.http_5xx', http_status = 502, finish_reason = 'error'
   WHERE id = public.k('cl21');
  PERFORM public.as_assert((SELECT charged_cost = 0 AND status = 'failed' FROM assistant.llm_call WHERE id = public.k('cl21')),
                           'T07 provider 5xx recorded; failed call without usage costs nothing');
  -- RV-AST-06: پروفایل دوم (failover) که از سیاست حذف شود، دور بعد همان اجرا را می‌بندد
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch('{"secondary_fingerprints": []}');
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_expect_error('T07 platform profile removed mid-run stops the next round',
    format($q$SELECT public.as_new_call(NULL, %L, 2)$q$, public.k('rA2')), 'HK_AST_PROVIDER');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch(jsonb_build_object('secondary_fingerprints', jsonb_build_array(public.fp('S'))));
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T07 message into a thread of another user',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content) VALUES (%L, %L, %L, %L, 1, 'user', 'سلام')$q$,
           public.k('A'), public.k('tA21'), public.k('a1'), public.k('rA2')), 'HK_AST_MESSAGE_LINK');
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  UPDATE assistant.run SET cancel_requested_at = now() WHERE id = public.k('rA2');
  PERFORM public.as_expect_error('T07 cancelled run gets no new round',
    format($q$SELECT public.as_new_call(NULL, %L, 2)$q$, public.k('rA2')), 'HK_AST_RUN_NOT_RUNNING');
  PERFORM public.as_expect_error('T07 cancel request is set once',
    format($q$UPDATE assistant.run SET cancel_requested_at = now() + interval '1 second' WHERE id = %L$q$, public.k('rA2')), 'HK_AST_RUN_STATE');
  UPDATE assistant.run SET status = 'cancelled' WHERE id = public.k('rA2');
  PERFORM public.as_assert((SELECT finished_at IS NOT NULL FROM assistant.run WHERE id = public.k('rA2')), 'T07 run cancelled');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_assert((SELECT tokens_committed = 1100 AND llm_calls = 2 FROM assistant.v_usage WHERE id = public.k('uA')), 'T07 tenant usage derived from calls');
END $T$;

-- T08: فراخوانی ابزار
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_tool_call(public.k('tc1'), public.k('rA1'), public.k('cl11'), 1, 'ledger.trial_balance', 'ok',
                              '{"rows": [{"account": "1101", "debit": "1200000"}], "as_of": "2026-11-17"}', p_rows => 3);
  PERFORM public.as_assert((SELECT args_sha256 = sha256(convert_to(args::text, 'UTF8')) AND result_bytes > 0
                              FROM assistant.tool_call WHERE id = public.k('tc1')), 'T08 args hash and result size generated');
  PERFORM public.as_new_call(public.k('cl12'), public.k('rA1'), 2);
  PERFORM public.as_expect_error('T08 tool call needs a completed tool_calls response',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'ledger.trial_balance')$q$, public.k('rA1'), public.k('cl12')), 'HK_AST_TOOL_LINK');
  PERFORM public.as_expect_error('T08 tool version must be the catalog version',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'ledger.trial_balance', p_version => 2)$q$, public.k('rA1'), public.k('cl11')), 'HK_AST_TOOL_UNKNOWN');
  PERFORM public.as_expect_error('T08 unknown tool',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'ledger.post_journal', p_version => 1)$q$, public.k('rA1'), public.k('cl11')), 'HK_AST_TOOL_UNKNOWN');
  PERFORM public.as_expect_error('T08 model call never exercises a materialize permission',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'ledger.propose_journal', p_perms => '{ledger.journal.create}')$q$, public.k('rA1'), public.k('cl11')),
    'HK_AST_TOOL_PERMISSION');
  PERFORM public.as_expect_error('T08 permission outside the tool ceiling',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'ledger.trial_balance', p_perms => '{ledger.report.read,ledger.journal.post}')$q$,
           public.k('rA1'), public.k('cl11')), 'HK_AST_TOOL_PERMISSION');
  PERFORM public.as_expect_error('T08 denied permission outside the ceiling',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'ledger.trial_balance', 'denied', NULL, '{}', p_denied => 'ledger.journal.post')$q$,
           public.k('rA1'), public.k('cl11')), 'HK_AST_TOOL_PERMISSION');
  PERFORM public.as_expect_error('T08 result byte cap per tool',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'assistant.calculate', 'ok', jsonb_build_object('v', repeat('۱', 600)))$q$,
           public.k('rA1'), public.k('cl11')), 'HK_AST_TOOL_RESULT_CAP');
  PERFORM public.as_expect_error('T08 row cap per tool',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'ledger.account_search', p_rows => 11)$q$, public.k('rA1'), public.k('cl11')), 'HK_AST_TOOL_RESULT_CAP');
  PERFORM public.as_expect_error('T08 tool call cap from policy',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 13, 'ledger.account_search')$q$, public.k('rA1'), public.k('cl11')), 'HK_AST_TOOL_CAP');
  PERFORM public.as_expect_error('T08 ok needs a result',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'ledger.account_search', 'ok', NULL)$q$, public.k('rA1'), public.k('cl11')), '23514');
  PERFORM public.as_expect_error('T08 denied needs the denied permission',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'ledger.account_search', 'denied', NULL)$q$, public.k('rA1'), public.k('cl11')), '23514');
  PERFORM public.as_expect_error('T08 tool call thread equals run thread',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'ledger.account_search', p_thread => %L)$q$, public.k('rA1'), public.k('cl11'), public.k('tA2')),
    'HK_AST_TOOL_LINK');
  PERFORM public.as_expect_error('T08 args size cap',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 2, 'ledger.account_search', p_args => jsonb_build_object('q', repeat('x', 9000)))$q$,
           public.k('rA1'), public.k('cl11')), '23514');
  PERFORM public.as_expect_error('T08 sequence unique per run',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 1, 'ledger.account_search')$q$, public.k('rA1'), public.k('cl11')), '23505');
  PERFORM public.as_tool_call(public.k('tc2'), public.k('rA1'), public.k('cl11'), 2, 'ledger.account_statement', 'denied', NULL, '{}',
                              p_denied => 'ledger.report.read');
  PERFORM public.as_tool_call(public.k('tc3'), public.k('rA1'), public.k('cl11'), 3, 'ledger.propose_journal', 'ok', '{"lines": 2, "balanced": true}');
  PERFORM public.as_tool_call(public.k('tc4'), public.k('rA1'), public.k('cl11'), 4, 'ledger.propose_journal', 'ok', '{"lines": 1, "balanced": false}');
  PERFORM public.as_tool_call(public.k('tc5'), public.k('rA1'), public.k('cl11'), 5, 'parties.propose_party', 'ok', '{"name": "[[party:1]]"}');
  PERFORM public.as_tool_call(public.k('tc6'), public.k('rA1'), public.k('cl11'), 6, 'treasury.propose_payment_reminder', 'ok', '{"preview": "ok"}');
  PERFORM public.as_tool_call('80a00000-0000-7000-8000-0000000d0007', public.k('rA1'), public.k('cl11'), 7, 'ledger.propose_journal', 'ok', '{"lines": 3}');
  PERFORM public.as_expect_error('T08 tool calls are not updatable by the app',
    format($q$UPDATE assistant.tool_call SET latency_ms = 1 WHERE id = %L$q$, public.k('tc1')), '42501');
  PERFORM public.as_expect_error('T08 tool calls are not deletable by the app',
    format($q$DELETE FROM assistant.tool_call WHERE id = %L$q$, public.k('tc1')), '42501');
  -- RV-AST-08: دور max_rounds پاسخ نهایی بی‌ابزار است؛ هیچ فراخوانی ابزاری به آن پاسخ داده نمی‌شود
  PERFORM public.as_finish_call(public.k('cl12'), 0, 0, 'tool_calls');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch('{"quotas": {"max_rounds": 2}}');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T08 the final round gets no tool calls',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 8, 'ledger.account_search')$q$, public.k('rA1'), public.k('cl12')), 'HK_AST_ROUND_CAP');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_policy_patch('{"quotas": {"max_rounds": 6}}');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_tool_call(NULL, public.k('rA1'), public.k('cl12'), 8, 'assistant.calculate', 'ok', '{"value": "12.5"}', '{}');
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_assert((SELECT count(*) FROM assistant.tool_call) = 0, 'T08 tool calls visible to their owner only');
END $T$;

-- T08b: مجوزی که منسوخ (یا critical) شود دیگر در سقف خواندنی فراخوانی ابزار نیست (RV-X1-08؛ همان فیلتر v_permission_ceiling)
RESET ROLE;
UPDATE core.permission SET deprecated_at = now() WHERE code = 'ledger.account.read';
SET ROLE hk_app;
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T08b tool call cannot exercise a deprecated permission',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 9, 'ledger.account_search', p_perms => '{ledger.account.read}')$q$, public.k('rA1'), public.k('cl11')),
    'HK_AST_TOOL_PERMISSION');
END $T$;
RESET ROLE;
UPDATE core.permission SET deprecated_at = NULL WHERE code = 'ledger.account.read';
SET ROLE hk_app;

-- T09: پیشنهاد و تأیید انسانی
DO $T$
DECLARE n integer;
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_proposal(public.k('pr1'), public.k('tc3'), 'journal_draft', true);
  PERFORM public.as_assert((SELECT status = 'proposed' AND expires_at BETWEEN now() + interval '7 days' - interval '1 minute' AND now() + interval '7 days' + interval '1 minute'
                              FROM assistant.proposal WHERE id = public.k('pr1')), 'T09 expiry from kind ttl (7 days)');
  PERFORM public.as_expect_error('T09 proposal only from a proposal tool',
    format($q$SELECT public.as_proposal(NULL, %L, 'journal_draft')$q$, public.k('tc1')), 'HK_AST_PROPOSAL_LINK');
  PERFORM public.as_expect_error('T09 proposal kind must match the tool',
    format($q$SELECT public.as_proposal(NULL, %L, 'purchase_order_draft')$q$, public.k('tc4')), 'HK_AST_PROPOSAL_LINK');
  PERFORM public.as_expect_error('T09 proposal from a denied call',
    format($q$SELECT public.as_proposal(NULL, %L, 'journal_draft')$q$, public.k('tc2')), 'HK_AST_PROPOSAL_LINK');
  PERFORM public.as_expect_error('T09 proposal company equals its run company',
    format($q$SELECT public.as_proposal(NULL, %L, 'journal_draft', p_company => %L)$q$, '80a00000-0000-7000-8000-0000000d0007', public.k('A.C2')),
    '23503');
  PERFORM public.as_expect_error('T09 one proposal per tool call',
    format($q$SELECT public.as_proposal(NULL, %L, 'journal_draft')$q$, public.k('tc3')), '23505');
  PERFORM public.as_proposal(public.k('pr2'), public.k('tc4'), 'journal_draft', false);
  PERFORM public.as_expect_error('T09 proposal is created proposed',
    format($q$INSERT INTO assistant.proposal (tenant_id, tool_call_id, run_id, thread_id, user_id, company_id, kind, title, payload, valid, status,
                                             decided_at, decided_by, expires_at)
              VALUES (%L, '80a00000-0000-7000-8000-0000000d0007', %L, %L, %L, %L, 'journal_draft', 'پیش‌نویس', '{}', true, 'dismissed', now(), %L, now() + interval '1 day')$q$,
           public.k('A'), public.k('rA1'), public.k('tA1'), public.k('a1'), public.k('A.C1'), public.k('a1')), 'HK_AST_PROPOSAL_STATE');
  PERFORM public.as_expect_error('T09 an update must decide the proposal',
    format($q$UPDATE assistant.proposal SET status = 'proposed' WHERE id = %L$q$, public.k('pr2')), 'HK_AST_PROPOSAL_STATE');
  PERFORM public.as_proposal(public.k('pr3'), public.k('tc5'), 'party_form_prefill', true);
  PERFORM public.as_proposal(public.k('pr4'), public.k('tc6'), 'payment_reminder_sms', true);
  PERFORM public.as_expect_error('T09 materialize outside a human-confirm transaction',
    format($q$UPDATE assistant.proposal SET status = 'materialized', decided_by = %L, target_type = 'ledger.journal_draft', target_id = uuidv7() WHERE id = %L$q$,
           public.k('a1'), public.k('pr1')), 'HK_AST_PROPOSAL_ACTOR');
  PERFORM public.as_expect_error('T09 proposal content immutable',
    format($q$UPDATE assistant.proposal SET status = 'dismissed', decided_by = %L, payload = '{"lines": []}' WHERE id = %L$q$, public.k('a1'), public.k('pr1')),
    'HK_AST_PROPOSAL_STATE');
  PERFORM public.as_expect_error('T09 early expiry rejected',
    format($q$UPDATE assistant.proposal SET status = 'expired' WHERE id = %L$q$, public.k('pr2')), 'HK_AST_PROPOSAL_STATE');
  PERFORM public.as_expect_error('T09 only materialized proposals have targets',
    format($q$UPDATE assistant.proposal SET status = 'dismissed', decided_by = %L, target_id = uuidv7() WHERE id = %L$q$, public.k('a1'), public.k('pr2')),
    'HK_AST_PROPOSAL_TARGET');
  PERFORM set_config('app.actor_via', 'assistant', true);
  PERFORM public.as_expect_error('T09 the model can never decide a proposal',
    format($q$UPDATE assistant.proposal SET status = 'dismissed', decided_by = %L WHERE id = %L$q$, public.k('a1'), public.k('pr1')), 'HK_AST_VIA_ASSISTANT');
  PERFORM set_config('app.actor_via', 'assistant_confirm', true);
  PERFORM public.as_expect_error('T09 server draft needs its target',
    format($q$UPDATE assistant.proposal SET status = 'materialized', decided_by = %L WHERE id = %L$q$, public.k('a1'), public.k('pr1')), 'HK_AST_PROPOSAL_TARGET');
  PERFORM public.as_expect_error('T09 draft must be in the target module',
    format($q$UPDATE assistant.proposal SET status = 'materialized', decided_by = %L, target_type = 'purchase.order', target_id = uuidv7() WHERE id = %L$q$,
           public.k('a1'), public.k('pr1')), 'HK_AST_PROPOSAL_TARGET');
  PERFORM public.as_expect_error('T09 only the asking human decides',
    format($q$UPDATE assistant.proposal SET status = 'materialized', decided_by = %L, target_type = 'ledger.journal_draft', target_id = uuidv7() WHERE id = %L$q$,
           public.k('a2'), public.k('pr1')), 'HK_AST_PROPOSAL_ACTOR');
  PERFORM public.as_expect_error('T09 confirm transaction cannot write other assistant tables',
    format($q$INSERT INTO assistant.thread (tenant_id, id, user_id, company_id) VALUES (%L, %L, %L, %L)$q$,
           public.k('A'), public.k('tA9'), public.k('a1'), public.k('A.C1')), 'HK_AST_VIA_ASSISTANT');
  UPDATE assistant.proposal SET status = 'materialized', decided_by = public.k('a1'), target_type = 'ledger.journal_draft',
                                target_id = '80a00000-0000-7000-8000-0000000d7a01' WHERE id = public.k('pr1');
  PERFORM public.as_assert((SELECT status = 'materialized' AND decided_at IS NOT NULL AND row_version = 2 FROM assistant.proposal WHERE id = public.k('pr1')),
                           'T09 human-confirmed materialization');
  PERFORM public.as_expect_error('T09 decided proposal is final',
    format($q$UPDATE assistant.proposal SET status = 'dismissed', decided_by = %L, target_type = NULL, target_id = NULL WHERE id = %L$q$,
           public.k('a1'), public.k('pr1')), 'HK_AST_PROPOSAL_STATE');
  PERFORM public.as_expect_error('T09 invalid proposal cannot be materialized',
    format($q$UPDATE assistant.proposal SET status = 'materialized', decided_by = %L, target_type = 'ledger.journal_draft', target_id = uuidv7() WHERE id = %L$q$,
           public.k('a1'), public.k('pr2')), 'HK_AST_PROPOSAL_INVALID');
  PERFORM public.as_expect_error('T09 client prefill creates nothing on the server',
    format($q$UPDATE assistant.proposal SET status = 'materialized', decided_by = %L, target_type = 'parties.party', target_id = uuidv7() WHERE id = %L$q$,
           public.k('a1'), public.k('pr3')), 'HK_AST_PROPOSAL_TARGET');
  UPDATE assistant.proposal SET status = 'materialized', decided_by = public.k('a1') WHERE id = public.k('pr3');
  PERFORM public.as_expect_error('T09 human send records what was sent',
    format($q$UPDATE assistant.proposal SET status = 'materialized', decided_by = %L WHERE id = %L$q$, public.k('a1'), public.k('pr4')), 'HK_AST_PROPOSAL_TARGET');
  UPDATE assistant.proposal SET status = 'materialized', decided_by = public.k('a1'), target_type = 'treasury.party_reminder',
                                target_ref = 'ntf:80a00000-0000-7000-8000-00000000ab99' WHERE id = public.k('pr4');
  PERFORM set_config('app.actor_via', '', true);
  UPDATE assistant.proposal SET status = 'dismissed', decided_by = public.k('a1') WHERE id = public.k('pr2');
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_assert((SELECT count(*) FROM assistant.proposal) = 0, 'T09 proposals visible to their owner only');
  UPDATE assistant.proposal SET status = 'dismissed', decided_by = public.k('a2');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.as_assert(n = 0, 'T09 another user cannot decide');
END $T$;

-- T10: پیام‌ها و پایان اجرا
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T10 suggestion message needs its suggestion_code',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content, input_mode) VALUES (%L, %L, %L, %L, 1, 'user', 'سود و زیان این ماه چقدر است؟', 'suggestion')$q$,
           public.k('A'), public.k('tA1'), public.k('a1'), public.k('rA1')), '23514');
  PERFORM public.as_expect_error('T10 suggestion_code only with input_mode=suggestion',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content, suggestion_code) VALUES (%L, %L, %L, %L, 1, 'user', 'سود و زیان این ماه چقدر است؟', 'general.pnl_month')$q$,
           public.k('A'), public.k('tA1'), public.k('a1'), public.k('rA1')), '23514');
  INSERT INTO assistant.message (tenant_id, id, thread_id, user_id, run_id, seq, role, content, input_mode, suggestion_code)
  VALUES (public.k('A'), public.k('m1'), public.k('tA1'), public.k('a1'), public.k('rA1'), 99, 'user', 'تراز آزمایشی این ماه را نشان بده', 'suggestion',
          'retail_apparel.season_pnl');
  PERFORM public.as_assert((SELECT seq = 1 FROM assistant.message WHERE id = public.k('m1')), 'T10 seq assigned by the thread counter');
  PERFORM public.as_expect_error('T10 bidi override characters rejected',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content) VALUES (%L, %L, %L, %L, 1, 'user', %L)$q$,
           public.k('A'), public.k('tA1'), public.k('a1'), public.k('rA1'), 'سلام' || U&'\202E' || 'abc'), '23514');
  PERFORM public.as_expect_error('T10 user message length cap',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content) VALUES (%L, %L, %L, %L, 1, 'user', repeat('ا', 2001))$q$,
           public.k('A'), public.k('tA1'), public.k('a1'), public.k('rA1')), '23514');
  PERFORM public.as_expect_error('T10 one user message per run',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content) VALUES (%L, %L, %L, %L, 1, 'user', 'دوباره')$q$,
           public.k('A'), public.k('tA1'), public.k('a1'), public.k('rA1')), '23505');
  PERFORM public.as_expect_error('T10 message run must belong to the thread',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content) VALUES (%L, %L, %L, %L, 1, 'user', 'سلام')$q$,
           public.k('A'), public.k('tA1'), public.k('a1'), public.k('rA2')), 'HK_AST_MESSAGE_LINK');
  PERFORM public.as_expect_error('T10 assistant message needs finish',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content) VALUES (%L, %L, %L, %L, 1, 'assistant', 'پاسخ')$q$,
           public.k('A'), public.k('tA1'), public.k('a1'), public.k('rA1')), '23514');
  PERFORM public.as_new_call(public.k('cl13'), public.k('rA1'), 3, 2000, 500);
  PERFORM public.as_expect_error('T10 run cannot finish with a call in flight',
    format($q$UPDATE assistant.run SET status = 'completed' WHERE id = %L$q$, public.k('rA1')), 'HK_AST_RUN_OPEN_CALLS');
  PERFORM public.as_finish_call(public.k('cl13'), 1500, 200, 'stop');
  PERFORM public.as_expect_error('T10 completed chat run needs its answer',
    format($q$UPDATE assistant.run SET status = 'completed' WHERE id = %L$q$, public.k('rA1')), 'HK_AST_RUN_NO_ANSWER');
  -- RV-AST-09: پاسخ دستیار همان رشتهٔ stream‌شده است (بدون نرمال‌سازی fa-norm-v1) ولی نویسهٔ bidi و zero-width ممنوع است
  PERFORM public.as_expect_error('T10 assistant answer rejects bidi override characters',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content, finish) VALUES (%L, %L, %L, %L, 1, 'assistant', %L, 'complete')$q$,
           public.k('A'), public.k('tA1'), public.k('a1'), public.k('rA1'), 'پاسخ' || U&'\202E' || 'abc'), '23514');
  PERFORM public.as_expect_error('T10 assistant answer rejects zero-width space',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content, finish) VALUES (%L, %L, %L, %L, 1, 'assistant', %L, 'complete')$q$,
           public.k('A'), public.k('tA1'), public.k('a1'), public.k('rA1'), 'پاسخ' || U&'\200B' || 'دوم'), '23514');
  PERFORM public.as_expect_error('T10 assistant answer length cap',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content, finish) VALUES (%L, %L, %L, %L, 1, 'assistant', repeat('ا', 8001), 'complete')$q$,
           public.k('A'), public.k('tA1'), public.k('a1'), public.k('rA1')), '23514');
  INSERT INTO assistant.message (tenant_id, id, thread_id, user_id, run_id, seq, role, content, finish, blocks, grounding)
  VALUES (public.k('A'), public.k('m2'), public.k('tA1'), public.k('a1'), public.k('rA1'), 1, 'assistant',
          E'تراز آزمایشی آماده است. جمع بدهکار ۱٬۲۰۰٬۰۰۰ ریال است.\n- نقدي: ٣٠٪\n  - كارت: ۷۰٪\n\n\n```\nکد    ستون\n```', 'complete',
          jsonb_build_array(jsonb_build_object('type', 'table', 'tool_call_id', public.k('tc1'))), '{"checked": 1, "ungrounded": []}');
  PERFORM public.as_assert((SELECT content <> core.fa_normalize_text(content) AND position(E'\n  - ' IN content) > 0 AND position('٣٠٪' IN content) > 0
                              FROM assistant.message WHERE id = public.k('m2')),
                           'T10 assistant answer stored exactly as streamed (Markdown indentation, digits and letters untouched)');
  PERFORM public.as_assert((SELECT message_count = 2 AND row_version = 1 FROM assistant.thread WHERE id = public.k('tA1')),
                           'T10 thread counter advanced without touching row_version');
  UPDATE assistant.run SET status = 'completed' WHERE id = public.k('rA1');
  PERFORM public.as_assert((SELECT finished_at IS NOT NULL FROM assistant.run WHERE id = public.k('rA1')), 'T10 run completed');
  PERFORM public.as_expect_error('T10 finished run is final',
    format($q$UPDATE assistant.run SET lease_expires_at = lease_expires_at + interval '1 minute' WHERE id = %L$q$, public.k('rA1')), 'HK_AST_RUN_STATE');
  PERFORM public.as_expect_error('T10 no model call after the run ends',
    format($q$SELECT public.as_new_call(NULL, %L, 4)$q$, public.k('rA1')), 'HK_AST_RUN_NOT_RUNNING');
  PERFORM public.as_expect_error('T10 no tool call after the run ends',
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 8, 'ledger.account_search')$q$, public.k('rA1'), public.k('cl11')), 'HK_AST_RUN_NOT_RUNNING');
  PERFORM public.as_expect_error('T10 no messages after the run ends',
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content, finish) VALUES (%L, %L, %L, %L, 1, 'assistant', 'دیر', 'complete')$q$,
           public.k('A'), public.k('tA1'), public.k('a1'), public.k('rA1')), 'HK_AST_RUN_NOT_RUNNING');
  PERFORM public.as_expect_error('T10 messages are not updatable by the app',
    format($q$UPDATE assistant.message SET content = 'تغییر' WHERE id = %L$q$, public.k('m2')), '42501');
  PERFORM public.as_expect_error('T10 single messages are not deletable',
    format($q$DELETE FROM assistant.message WHERE id = %L$q$, public.k('m2')), '42501');
  PERFORM public.as_assert((SELECT llm_calls = 3 AND prompt_tokens = 2300 AND completion_tokens = 500 AND rounds = 3 FROM assistant.v_run_usage WHERE run_id = public.k('rA1')),
                           'T10 run usage summary');
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_assert((SELECT count(*) FROM assistant.message) = 0, 'T10 messages visible to their owner only');
  PERFORM public.as_assert((SELECT count(*) FROM assistant.v_run_usage WHERE run_id = public.k('rA1')) = 1, 'T10 metering visible to the tenant (no content)');
END $T$;

-- T11: بازخورد
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T11 feedback only on assistant messages',
    format($q$INSERT INTO assistant.feedback (tenant_id, message_id, user_id, rating) VALUES (%L, %L, %L, 1)$q$, public.k('A'), public.k('m1'), public.k('a1')),
    'HK_AST_FEEDBACK_ROLE');
  INSERT INTO assistant.feedback (tenant_id, id, message_id, user_id, rating, reason, comment)
  VALUES (public.k('A'), public.k('f1'), public.k('m2'), public.k('a1'), -1, 'wrong_numbers', 'جمع بدهکار اشتباه است');
  PERFORM public.as_expect_error('T11 reason only for a negative rating',
    format($q$UPDATE assistant.feedback SET rating = 1 WHERE id = %L$q$, public.k('f1')), '23514');
  UPDATE assistant.feedback SET rating = 1, reason = NULL WHERE id = public.k('f1');
  PERFORM public.as_assert((SELECT row_version = 2 FROM assistant.feedback WHERE id = public.k('f1')), 'T11 feedback update bumps row_version (If-Match)');
  PERFORM public.as_expect_error('T11 feedback target immutable',
    format($q$UPDATE assistant.feedback SET created_at = created_at - interval '1 day' WHERE id = %L$q$, public.k('f1')), 'HK_AST_FEEDBACK_ROLE');
  PERFORM public.as_expect_error('T11 one feedback per message and user',
    format($q$INSERT INTO assistant.feedback (tenant_id, message_id, user_id, rating) VALUES (%L, %L, %L, 1)$q$, public.k('A'), public.k('m2'), public.k('a1')),
    '23505');
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_expect_error('T11 feedback on a message the user cannot see',
    format($q$INSERT INTO assistant.feedback (tenant_id, message_id, user_id, rating) VALUES (%L, %L, %L, 1)$q$, public.k('A'), public.k('m2'), public.k('a2')),
    'HK_AST_FEEDBACK_ROLE');
END $T$;

-- T12: ارائه‌دهندهٔ مستأجر (On-prem/BYO) و رضایت مقصد تازه
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T12 http only on a private network',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, created_by)
              VALUES (%L, 'سرور محلی', 'Our LAN vLLM', 'iran', 'http://10.0.0.5:8000/v1', 'qwen2.5-7b', 'none', %L)$q$, public.k('A'), public.k('a1')), '23514');
  PERFORM public.as_expect_error('T12 lan location implies private network',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, created_by)
              VALUES (%L, 'سرور محلی', 'Our LAN vLLM', 'lan', 'https://llm.local/v1', 'qwen2.5-7b', 'none', %L)$q$, public.k('A'), public.k('a1')), '23514');
  PERFORM public.as_expect_error('T12 auth none means no key',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, api_key_sealed, allow_private_network, created_by)
              VALUES (%L, 'سرور محلی', 'Our LAN vLLM', 'lan', 'http://10.0.0.5:8000/v1', 'qwen2.5-7b', 'none', decode(repeat('00', 40), 'hex'), true, %L)$q$,
           public.k('A'), public.k('a1')), '23514');
  -- RV-X1-09، RV-AST-15: http و شبکهٔ خصوصی فقط برای مقصد LAN
  PERFORM public.as_expect_error('T12 http to a non-LAN destination rejected even with the private flag',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, api_key_sealed, allow_private_network, created_by)
              VALUES (%L, 'سرور آزمون', 'Foreign', 'other', 'http://llm.foreign.example/v1', 'm', 'authorization_bearer', decode(repeat('00', 40), 'hex'), true, %L)$q$,
           public.k('A'), public.k('a1')), '23514');
  PERFORM public.as_expect_error('T12 private flag only with a LAN destination',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, allow_private_network, created_by)
              VALUES (%L, 'سرور آزمون', 'Iran Co', 'iran', 'https://llm.example.ir/v1', 'm', 'none', true, %L)$q$, public.k('A'), public.k('a1')), '23514');
  -- RV-AST-20: نام اپراتور مبهم (tab، NBSP) پیش از اثرانگشت رد می‌شود
  PERFORM public.as_expect_error('T12 operator with a tab rejected',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, created_by)
              VALUES (%L, 'سرور آزمون', %L, 'iran', 'https://llm.example.ir/v1', 'm', 'none', %L)$q$, public.k('A'), E'\tAcme AI', public.k('a1')), '23514');
  PERFORM public.as_expect_error('T12 operator with a no-break space rejected',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, created_by)
              VALUES (%L, 'سرور آزمون', %L, 'iran', 'https://llm.example.ir/v1', 'm', 'none', %L)$q$, public.k('A'), 'Acme' || U&'\00A0' || 'AI', public.k('a1')), '23514');
  PERFORM public.as_expect_error('T12 URL without credentials or query',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, created_by)
              VALUES (%L, 'سرور آزمون', 'Evil', 'other', 'https://user:pass@evil.example/v1?x=1', 'm', 'none', %L)$q$, public.k('A'), public.k('a1')), '23514');
  INSERT INTO assistant.tenant_provider (tenant_id, id, display_name, operator, data_location, base_url, model, auth_header, allow_private_network, created_by)
  VALUES (public.k('A'), public.k('tp1'), 'سرور محلی', '  Our LAN vLLM ', 'lan', 'http://10.0.0.5:8000/v1', 'qwen2.5-7b', 'none', true, public.k('a1'));
  PERFORM public.as_assert((SELECT fingerprint = public.fp('L') FROM assistant.tenant_provider WHERE id = public.k('tp1')), 'T12 fingerprint generated');
  PERFORM public.as_expect_error('T12 activation needs a successful probe',
    format($q$UPDATE assistant.tenant_provider SET status = 'active' WHERE id = %L$q$, public.k('tp1')), '23514');
  UPDATE assistant.tenant_provider SET last_probe_ok = true, last_probe_at = now(), last_probe_report = '{"tools": true, "stream_usage": false}' WHERE id = public.k('tp1');
  UPDATE assistant.tenant_provider SET status = 'active' WHERE id = public.k('tp1');
  PERFORM public.as_assert((SELECT updated_by = public.k('a1') AND row_version = 3 FROM assistant.tenant_provider WHERE id = public.k('tp1')),
                           'T12 updated_by from context; each update bumps row_version (If-Match)');
  PERFORM public.as_expect_error('T12 one active provider per tenant',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, allow_private_network,
                                                   status, last_probe_ok, last_probe_at, created_by)
              VALUES (%L, 'دومی', 'Second', 'lan', 'http://10.0.0.6:8000/v1', 'm', 'none', true, 'active', true, now(), %L)$q$, public.k('A'), public.k('a1')), '23505');
  PERFORM public.as_expect_error('T12 destination of an active provider is frozen',
    format($q$UPDATE assistant.tenant_provider SET base_url = 'http://10.0.0.9:8000/v1' WHERE id = %L$q$, public.k('tp1')), 'HK_AST_PROVIDER_STATE');
  PERFORM public.as_expect_error('T12 creator immutable',
    format($q$UPDATE assistant.tenant_provider SET created_by = %L WHERE id = %L$q$, public.k('a2'), public.k('tp1')), 'HK_AST_PROVIDER_STATE');
  UPDATE assistant.tenant_provider SET status = 'disabled' WHERE id = public.k('tp1');
  UPDATE assistant.tenant_provider SET base_url = 'http://10.0.0.9:8000/v1' WHERE id = public.k('tp1');
  PERFORM public.as_assert((SELECT last_probe_ok IS NULL AND last_probe_at IS NULL FROM assistant.tenant_provider WHERE id = public.k('tp1')),
                           'T12 destination change resets the probe');
  PERFORM public.as_expect_error('T12 provider cannot go back to draft',
    format($q$UPDATE assistant.tenant_provider SET status = 'draft' WHERE id = %L$q$, public.k('tp1')), 'HK_AST_PROVIDER_STATE');
  UPDATE assistant.tenant_provider SET base_url = 'http://10.0.0.5:8000/v1' WHERE id = public.k('tp1');
  UPDATE assistant.tenant_provider SET last_probe_ok = true, last_probe_at = now() WHERE id = public.k('tp1');
  UPDATE assistant.tenant_provider SET status = 'active' WHERE id = public.k('tp1');
  -- اجرای با ارائه‌دهندهٔ مستأجر: اول رضایت مقصد تازه لازم است
  PERFORM public.as_expect_error('T12 new destination needs re-consent',
    format($q$SELECT public.as_new_run(NULL, %L, p_fp => %L, p_source => 'tenant', p_tp => %L)$q$, public.k('tA2'), public.fp('L'), public.k('tp1')),
    'HK_AST_CONSENT');
  PERFORM public.as_grant_consent(public.k('cA3'), '{chat,migration_mapping}',
                                  '{financial_aggregate,reference_names,item_name,party_name,document_detail}',
                                  ARRAY[public.fp('P'), public.fp('S'), public.fp('X'), public.fp('L')]);
  PERFORM public.as_expect_error('T12 tenant run fingerprint must equal the provider',
    format($q$SELECT public.as_new_run(NULL, %L, p_fp => %L, p_source => 'tenant', p_tp => %L)$q$, public.k('tA2'), public.fp('P'), public.k('tp1')),
    'HK_AST_PROVIDER');
  PERFORM public.as_new_run(public.k('rA3'), public.k('tA2'), p_fp => public.fp('L'), p_source => 'tenant', p_tp => public.k('tp1'));
  PERFORM public.as_ctx(public.k('B'), public.k('b1'));
  PERFORM public.as_expect_error('T12 plan without tenant providers',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, id, display_name, operator, data_location, base_url, model, auth_header,
                                                   status, last_probe_ok, last_probe_at, created_by)
              VALUES (%L, %L, 'ارائه‌دهندهٔ ب', 'B Iran AI', 'iran', 'https://llm.b.example.ir/v1', 'm', 'none', 'active', true, now(), %L)$q$,
           public.k('B'), public.k('tpB'), public.k('b1')), 'HK_AST_PROVIDER');
  -- RV-AST-15: مستأجر SaaS هرگز به شبکهٔ خصوصی (شبکهٔ سلول اپراتور) نمی‌رسد، حتی در پیش‌نویس
  PERFORM public.as_expect_error('T12 SaaS tenant cannot define a LAN provider',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, allow_private_network, created_by)
              VALUES (%L, 'سرور ب', 'B LAN', 'lan', 'http://10.0.0.7:8200/v1', 'm', 'none', true, %L)$q$, public.k('B'), public.k('b1')),
    'HK_AST_PRIVATE_NETWORK');
  PERFORM public.as_expect_error('T12 SaaS tenant cannot use plain http',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, created_by)
              VALUES (%L, 'سرور ب', 'B Foreign', 'other', 'http://llm.foreign.example/v1', 'm', 'none', %L)$q$, public.k('B'), public.k('b1')),
    'HK_AST_PRIVATE_NETWORK');
END $T$;

-- T13: لغو رضایت وسط اجرا
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_new_call(public.k('cl31'), public.k('rA3'), 1, 1000, 500);
  PERFORM public.as_finish_call(public.k('cl31'), 900, 100, 'tool_calls');
  -- RV-AST-06: ارائه‌دهندهٔ مستأجر که وسط اجرا غیرفعال شود، دور بعد را نمی‌گیرد
  UPDATE assistant.tenant_provider SET status = 'disabled' WHERE id = public.k('tp1');
  PERFORM public.as_expect_error('T13 tenant provider disabled mid-run stops the next round',
    format($q$SELECT public.as_new_call(NULL, %L, 2)$q$, public.k('rA3')), 'HK_AST_PROVIDER');
  UPDATE assistant.tenant_provider SET status = 'active' WHERE id = public.k('tp1');
  UPDATE assistant.consent SET status = 'revoked', ended_by = public.k('a1'), end_reason = 'آزمون لغو رضایت' WHERE id = public.k('cA3');
  PERFORM public.as_expect_error('T13 revoked consent stops the next round',
    format($q$SELECT public.as_new_call(NULL, %L, 2)$q$, public.k('rA3')), 'HK_AST_CONSENT');
  PERFORM public.as_expect_error('T13 revoked consent is final',
    format($q$UPDATE assistant.consent SET status = 'active', ended_at = NULL, ended_by = NULL, end_reason = NULL WHERE id = %L$q$, public.k('cA3')),
    'HK_AST_CONSENT_STATE');
  PERFORM public.as_expect_error('T13 failed run needs an error code',
    format($q$UPDATE assistant.run SET status = 'failed' WHERE id = %L$q$, public.k('rA3')), '23514');
  UPDATE assistant.run SET status = 'failed', error_code = 'assistant.consent.revoked' WHERE id = public.k('rA3');
  PERFORM public.as_expect_error('T13 no run without an active consent',
    format($q$SELECT public.as_new_run(NULL, %L)$q$, public.k('tA2')), 'HK_AST_CONSENT');
  PERFORM public.as_grant_consent(public.k('cA4'), '{chat,migration_mapping}', '{financial_aggregate,reference_names}',
                                  ARRAY[public.fp('P'), public.fp('S')]);
END $T$;

-- T14: حذف رشته = حذف محتوا؛ سنجش می‌ماند
DO $T$
DECLARE n integer;
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_assert((SELECT count(*) FROM assistant.message WHERE thread_id = public.k('tA1')) = 2
                       AND (SELECT count(*) FROM assistant.tool_call WHERE thread_id = public.k('tA1')) = 8
                       AND (SELECT count(*) FROM assistant.proposal WHERE thread_id = public.k('tA1')) = 4
                       AND (SELECT count(*) FROM assistant.feedback) = 1, 'T14 content before deletion');
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  DELETE FROM assistant.thread WHERE id = public.k('tA1');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.as_assert(n = 0, 'T14 another user cannot delete the thread');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  DELETE FROM assistant.thread WHERE id = public.k('tA1');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.as_assert(n = 1, 'T14 owner deletes the thread');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM set_config('hk.assistant_system', 'retention', true);   -- فقط برای دیدن همهٔ محتوای مستأجر در آزمون (بدون کاربر)
  PERFORM public.as_assert((SELECT count(*) FROM assistant.message WHERE thread_id = public.k('tA1')) = 0
                       AND (SELECT count(*) FROM assistant.tool_call WHERE thread_id = public.k('tA1')) = 0
                       AND (SELECT count(*) FROM assistant.proposal WHERE thread_id = public.k('tA1')) = 0
                       AND (SELECT count(*) FROM assistant.feedback) = 0, 'T14 all content cascaded');
  PERFORM set_config('hk.assistant_system', '', true);
  PERFORM public.as_assert((SELECT thread_id IS NULL AND status = 'completed' FROM assistant.run WHERE id = public.k('rA1')), 'T14 run kept, detached');
  PERFORM public.as_assert((SELECT llm_calls = 3 AND prompt_tokens = 2300 FROM assistant.v_run_usage WHERE run_id = public.k('rA1')), 'T14 metering kept');
END $T$;

-- آماده‌سازی T15: یک اجرای کامل دیگر با بازخورد (تا UPDATE و DELETE بازخورد در حالت مدل ردیف هدف داشته باشند؛ RV-AST-05)
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_new_run(public.k('rA4'), public.k('tA2'));
  INSERT INTO assistant.message (tenant_id, id, thread_id, user_id, run_id, seq, role, content)
  VALUES (public.k('A'), public.k('m3'), public.k('tA2'), public.k('a1'), public.k('rA4'), 1, 'user', 'مانده صندوق چقدر است؟');
  PERFORM public.as_new_call(public.k('cl41'), public.k('rA4'), 1, 500, 200);
  PERFORM public.as_finish_call(public.k('cl41'), 300, 50, 'stop');
  INSERT INTO assistant.message (tenant_id, id, thread_id, user_id, run_id, seq, role, content, finish)
  VALUES (public.k('A'), public.k('m4'), public.k('tA2'), public.k('a1'), public.k('rA4'), 1, 'assistant', 'مانده صندوق ۵٬۰۰۰٬۰۰۰ ریال است.', 'complete');
  UPDATE assistant.run SET status = 'completed' WHERE id = public.k('rA4');
  INSERT INTO assistant.feedback (tenant_id, id, message_id, user_id, rating) VALUES (public.k('A'), public.k('f2'), public.k('m4'), public.k('a1'), 1);
END $T$;

-- T15: منشأ تراکنش (actor_via) و تراکنش READ ONLY
DO $T$
DECLARE s text;
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'), 'assistant');
  FOREACH s IN ARRAY ARRAY[
    format($q$INSERT INTO assistant.thread (tenant_id, id, user_id, company_id) VALUES (%L, %L, %L, %L)$q$, public.k('A'), public.k('tA9'), public.k('a1'), public.k('A.C1')),
    format($q$UPDATE assistant.thread SET title = 'تغییر' WHERE id = %L$q$, public.k('tA2')),
    format($q$DELETE FROM assistant.thread WHERE id = %L$q$, public.k('tA2')),
    format($q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, limit_source) VALUES (%L, 'tenant', current_date + 40, current_date + 60, 'unlimited')$q$, public.k('A')),
    format($q$SELECT public.as_grant_consent(NULL, '{chat}', '{financial_aggregate}', ARRAY[%L])$q$, public.fp('P')),
    format($q$UPDATE assistant.run SET lease_expires_at = lease_expires_at WHERE id = %L$q$, public.k('rA1')),
    format($q$SELECT public.as_new_run(NULL, %L)$q$, public.k('tA2')),
    format($q$SELECT public.as_new_call(NULL, %L, 9)$q$, public.k('rA1')),
    format($q$INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content) VALUES (%L, %L, %L, %L, 1, 'user', 'x')$q$, public.k('A'), public.k('tA2'), public.k('a1'), public.k('rA3')),
    format($q$SELECT public.as_tool_call(NULL, %L, %L, 9, 'ledger.account_search')$q$, public.k('rA3'), public.k('cl31')),
    format($q$UPDATE assistant.tenant_provider SET display_name = 'x' WHERE id = %L$q$, public.k('tp1')),
    format($q$UPDATE assistant.consent SET status = 'revoked', ended_by = %L, end_reason = 'xyz' WHERE id = %L$q$, public.k('a1'), public.k('cA4')),
    format($q$INSERT INTO assistant.feedback (tenant_id, message_id, user_id, rating) VALUES (%L, %L, %L, -1)$q$, public.k('A'), public.k('m4'), public.k('a1')),
    format($q$UPDATE assistant.feedback SET rating = -1, reason = 'other' WHERE id = %L$q$, public.k('f2')),
    format($q$DELETE FROM assistant.feedback WHERE id = %L$q$, public.k('f2')),
    format($q$DELETE FROM assistant.run WHERE id = %L$q$, public.k('rA4')),
    format($q$DELETE FROM assistant.llm_call WHERE id = %L$q$, public.k('cl41')),
    format($q$DELETE FROM assistant.usage_period WHERE id = %L$q$, public.k('ua3')),
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, created_by)
              VALUES (%L, 'x', 'X Co', 'iran', 'https://x.example.ir/v1', 'm', 'none', %L)$q$, public.k('A'), public.k('a1'))]
  LOOP
    PERFORM public.as_expect_error('T15 model-initiated transaction writes nothing: ' || left(s, 60), s, 'HK_AST_VIA_ASSISTANT');
  END LOOP;
  PERFORM public.as_ctx(public.k('A'), public.k('a1'), 'bogus');
  PERFORM public.as_expect_error('T15 unknown actor_via value rejected',
    format($q$UPDATE assistant.thread SET title = 'تغییر' WHERE id = %L$q$, public.k('tA2')), 'HK_AST_VIA_ASSISTANT');
END $T$;

BEGIN READ ONLY;
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'), 'assistant');
  PERFORM public.as_expect_error('T15 read-only tool transaction cannot write business tables',
    format($q$INSERT INTO ledger.journal_draft (tenant_id, company_id) VALUES (%L, %L)$q$, public.k('A'), public.k('A.C1')), '25006');
  PERFORM public.as_expect_error('T15 read-only tool transaction cannot write assistant tables',
    format($q$INSERT INTO assistant.thread (tenant_id, user_id, company_id) VALUES (%L, %L, %L)$q$, public.k('A'), public.k('a1'), public.k('A.C1')), '25006');
  PERFORM public.as_assert((SELECT count(*) FROM assistant.v_usage) >= 4, 'T15 reads still work in a read-only tool transaction');
END $T$;
COMMIT;

-- T15b: صدور .hkx (RV-AST-01). صدور با app.tenant_id و بدون کاربر در تراکنش SERIALIZABLE READ ONLY DEFERRABLE اجرا می‌شود
-- (۰۲ §۵.۱۵) و بسته‌اش را مالک مستأجر دانلود می‌کند؛ پس در آن زمینه هیچ محتوای گفت‌وگویی خوانده نمی‌شود، مگر صدور
-- move_placement در حال اجرا که کارمند پلتفرم خواسته و قلاب assistant.conversations شناسه‌اش را در GUC گذاشته باشد.
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  INSERT INTO core.tenant_export (tenant_id, id, purpose, status, requested_by, requested_by_staff_id, started_at) VALUES
    (public.k('A'), public.k('exM'), 'move_placement', 'running', NULL, '80a00000-0000-7000-8000-00000000057f', now()),
    (public.k('A'), public.k('exO'), 'offboarding',    'running', public.k('a1'), NULL, now());
END $T$;
BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE;
DO $T$
DECLARE tbl text; n bigint;
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  FOREACH tbl IN ARRAY ARRAY['assistant.thread','assistant.message','assistant.tool_call','assistant.proposal','assistant.feedback'] LOOP
    EXECUTE format('SELECT count(*) FROM (SELECT to_jsonb(t) FROM %s t) x', tbl) INTO n;
    PERFORM public.as_assert(n = 0, 'T15b export-shaped read in tenant-only context returns no content: ' || tbl);
  END LOOP;
  PERFORM set_config('hk.assistant_system', 'placement_move:' || public.k('exO'), true);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.message) = 0, 'T15b an offboarding export (downloadable by the owner) gets no conversation');
  PERFORM set_config('hk.assistant_system', 'placement_move:' || public.k('exM'), true);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread) = 3 AND (SELECT count(*) FROM assistant.message) = 2
                           AND (SELECT count(*) FROM assistant.feedback) = 1,
                           'T15b a running staff placement move reads every conversation of the tenant');
  PERFORM set_config('hk.assistant_system', '', true);
END $T$;
COMMIT;
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  UPDATE core.tenant_export SET status = 'failed', error = '{"reason": "test"}' WHERE id IN (public.k('exM'), public.k('exO'));
  PERFORM set_config('hk.assistant_system', 'placement_move:' || public.k('exM'), true);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.message) = 0, 'T15b a finished placement export no longer reads content');
END $T$;

-- T16: جداسازی مستأجر
DO $T$
DECLARE tbl text; n bigint; total bigint := 0;
BEGIN
  PERFORM public.as_ctx(public.k('B'), public.k('b1'));
  FOR tbl IN SELECT c.oid::regclass::text FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
              JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id'
             WHERE ns.nspname = 'assistant' AND c.relkind = 'r'
  LOOP
    EXECUTE format('SELECT count(*) FROM %s WHERE tenant_id = %L', tbl, public.k('A')) INTO n;
    PERFORM public.as_assert(n = 0, 'T16 tenant B sees no rows of A in ' || tbl);
    EXECUTE format('SELECT count(*) FROM %s', tbl) INTO n;
    total := total + n;
  END LOOP;
  PERFORM public.as_assert(total >= 5, 'T16 tenant B sees its own rows');
  PERFORM public.as_expect_error('T16 consent of another tenant',
    format($q$SELECT public.as_new_run(NULL, %L, p_consent => %L)$q$, public.k('tB1'), public.k('cA4')), 'HK_AST_CONSENT');
  PERFORM public.as_expect_error('T16 company of another tenant',
    format($q$INSERT INTO assistant.thread (tenant_id, user_id, company_id) VALUES (%L, %L, %L)$q$, public.k('B'), public.k('b1'), public.k('A.C1')), '23503');
  PERFORM public.as_expect_error('T16 row for another tenant',
    format($q$INSERT INTO assistant.thread (tenant_id, user_id, company_id) VALUES (%L, %L, %L)$q$, public.k('A'), public.k('b1'), public.k('A.C1')), '42501');
  UPDATE assistant.tenant_policy SET document = document || '{"note": "cross-tenant"}' WHERE tenant_id = public.k('A');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.as_assert(n = 0, 'T16 cannot update another tenant policy');
  PERFORM public.as_new_run(public.k('rB1'), public.k('tB1'));
  -- هزینهٔ هر دوره یک واحد دارد، حتی وقتی سقف هزینه ندارد (B هیچ سقف هزینه‌ای ندارد؛ RV-AST-11)
  PERFORM public.as_expect_error('T16 price unit must equal the period unit even without a cost limit',
    format($q$SELECT public.as_new_call(NULL, %L, 1, 1000, 500, 'IRT')$q$, public.k('rB1')), 'HK_AST_BUDGET_UNIT');
  PERFORM public.as_new_call(NULL, public.k('rB1'), 1);
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.run WHERE tenant_id = public.k('B')) = 0, 'T16 tenant A sees no run of B');
  PERFORM public.as_assert((SELECT count(*) FROM assistant.v_usage WHERE tenant_id = public.k('B')) = 0, 'T16 views are security_invoker');
  PERFORM public.as_ctx(NULL, NULL);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread) = 0 AND (SELECT count(*) FROM assistant.run) = 0, 'T16 no tenant context sees nothing');
END $T$;

-- =====================================================================
-- بخش ۳: hk_readonly
-- =====================================================================
RESET ROLE;
SET ROLE hk_readonly;
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.run) >= 3, 'T17 readonly reads metering');
  PERFORM public.as_assert((SELECT count(*) FROM (SELECT id, role, seq FROM assistant.message) x) >= 0, 'T17 readonly reads message metadata');
  PERFORM public.as_assert((SELECT count(*) FROM assistant.message WHERE suggestion_code IS NOT NULL) >= 0, 'T17 readonly reads suggestion usage');
  PERFORM public.as_expect_error('T17 readonly cannot read message content', $q$SELECT content FROM assistant.message$q$, '42501');
  PERFORM public.as_expect_error('T17 readonly cannot read tool results', $q$SELECT result FROM assistant.tool_call$q$, '42501');
  PERFORM public.as_expect_error('T17 readonly cannot read proposal payload', $q$SELECT payload FROM assistant.proposal$q$, '42501');
  PERFORM public.as_expect_error('T17 readonly cannot read the provider key', $q$SELECT api_key_sealed FROM assistant.tenant_provider$q$, '42501');
  PERFORM public.as_expect_error('T17 readonly cannot read thread titles', $q$SELECT title FROM assistant.thread$q$, '42501');
  PERFORM public.as_expect_error('T17 readonly cannot write', $q$UPDATE assistant.run SET lease_expires_at = now()$q$, '42501');
END $T$;

-- =====================================================================
-- بخش ۴: postgres
-- =====================================================================
RESET ROLE;

-- T18: قیدهای کاتالوگ (حتی برای مالک جدول‌ها)
DO $T$
BEGIN
  PERFORM public.as_expect_error('T18 prohibited class is never grantable',
    $q$INSERT INTO assistant.data_class VALUES ('raw_ledger_rows', 'prohibited', true, 'x')$q$, '23514');
  PERFORM public.as_expect_error('T18 tool cannot use a prohibited class',
    $q$INSERT INTO assistant.tool (code, version, kind, module, service_ref, data_classes, phase, introduced_in)
       VALUES ('parties.contacts', 1, 'query', 'parties', 'hesabketab.parties.api.queries:PartyQuery.contacts', '{contact_pii}', 'v1', '1.0')$q$, 'HK_AST_CATALOG');
  PERFORM public.as_expect_error('T18 required and optional classes are disjoint',
    $q$INSERT INTO assistant.tool (code, version, kind, module, service_ref, data_classes, optional_data_classes, phase, introduced_in)
       VALUES ('sales.x', 1, 'query', 'sales', 'hesabketab.sales.api.queries:SalesQuery.x', '{item_name}', '{item_name}', 'v1', '1.0')$q$, 'HK_AST_CATALOG');
  PERFORM public.as_expect_error('T18 proposal tool belongs to the target module',
    $q$INSERT INTO assistant.tool (code, version, kind, module, service_ref, proposal_kind, phase, introduced_in)
       VALUES ('sales.propose_journal', 1, 'proposal', 'sales', 'hesabketab.sales.api.services:X.validate', 'journal_draft', 'v1', '1.0')$q$, 'HK_AST_CATALOG');
  PERFORM public.as_expect_error('T18 proposal tool needs a proposal kind',
    $q$INSERT INTO assistant.tool (code, version, kind, module, service_ref, phase, introduced_in)
       VALUES ('ledger.propose_x', 1, 'proposal', 'ledger', 'hesabketab.ledger.api.services:X.validate', 'v1', '1.0')$q$, '23514');
  PERFORM public.as_expect_error('T18 utility tool lives in the assistant module',
    $q$INSERT INTO assistant.tool (code, version, kind, module, service_ref, phase, introduced_in)
       VALUES ('ledger.calc', 1, 'utility', 'ledger', 'hesabketab.ledger.tools:Calc.run', 'v1', '1.0')$q$, '23514');
  PERFORM public.as_expect_error('T18 query tool code prefix is its module',
    $q$INSERT INTO assistant.tool (code, version, kind, module, service_ref, phase, introduced_in)
       VALUES ('sales.balance', 1, 'query', 'ledger', 'hesabketab.ledger.api.queries:X.y', 'v1', '1.0')$q$, '23514');
  PERFORM public.as_expect_error('T18 tool kind immutable',
    $q$UPDATE assistant.tool SET kind = 'proposal', proposal_kind = 'journal_draft' WHERE code = 'ledger.trial_balance'$q$, 'HK_AST_CATALOG');
  PERFORM public.as_expect_error('T18 tool version never decreases',
    $q$UPDATE assistant.tool SET version = 0 WHERE code = 'ledger.trial_balance'$q$, 'HK_AST_CATALOG');
  PERFORM public.as_expect_error('T18 utility tools hold no permissions',
    $q$INSERT INTO assistant.tool_permission VALUES ('assistant.calculate', 'ledger.report.read', 'read')$q$, 'HK_AST_CEILING_VERB');
  PERFORM public.as_expect_error('T18 critical permission never in the ceiling',
    $q$INSERT INTO assistant.tool_permission VALUES ('ledger.trial_balance', 'ledger.year.close', 'read_optional')$q$, 'HK_AST_CEILING_CRITICAL');
  PERFORM public.as_expect_error('T18 model-initiated permission must be a read',
    $q$INSERT INTO assistant.tool_permission VALUES ('ledger.trial_balance', 'ledger.journal.post', 'read')$q$, '23514');
  PERFORM public.as_expect_error('T18 materialize only on proposal tools',
    $q$INSERT INTO assistant.tool_permission VALUES ('ledger.trial_balance', 'ledger.journal.create', 'materialize')$q$, 'HK_AST_CEILING_VERB');
  PERFORM public.as_expect_error('T18 materialize verb is create or send',
    $q$INSERT INTO assistant.tool_permission VALUES ('ledger.propose_journal', 'ledger.journal.post', 'materialize')$q$, '23514');
  PERFORM public.as_expect_error('T18 suggestion needs known tools',
    $q$INSERT INTO assistant.prompt_suggestion (code, text, required_tools) VALUES ('x.bad', 'سلام دنیا', '{ledger.nothing}')$q$, 'HK_AST_CATALOG');
  PERFORM public.as_expect_error('T18 suggestion text normalized',
    $q$INSERT INTO assistant.prompt_suggestion (code, text, required_tools) VALUES ('x.bad2', 'فروش امروز چطوري بود', '{sales.summary}')$q$, '23514');
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.prompt_suggestion WHERE text <> core.fa_normalize_text(text)), 'T18 seeded suggestions normalized');
  PERFORM public.as_expect_error('T18 usage period bounds immutable even for the owner',
    format($q$UPDATE assistant.usage_period SET period_start = period_start - 1 WHERE id = %L$q$, public.k('uA')), 'HK_AST_USAGE_IMMUTABLE');
  -- RV-X1-08: مجوزی که در سقف دستیار است بعداً هم critical نمی‌شود (نگهبان روی کاتالوگ هسته)
  PERFORM public.as_expect_error('T18 a permission in the ceiling cannot become critical',
    $q$UPDATE core.permission SET risk = 'critical' WHERE code = 'ledger.journal.create'$q$, 'HK_AST_CEILING_CRITICAL');
  PERFORM public.as_expect_error('T18 a permission in the ceiling cannot be (re)registered as critical',
    $q$INSERT INTO core.permission (code, module, scope_dimensions, risk, allow_service_account, allow_impersonation_write, description_key, introduced_in)
       VALUES ('treasury.reminder.send', 'treasury', '{company}', 'critical', false, false, 'perm.treasury.reminder.send', '1.0')
       ON CONFLICT (code) DO UPDATE SET risk = EXCLUDED.risk$q$, 'HK_AST_CEILING_CRITICAL');
  PERFORM public.as_assert((SELECT risk <> 'critical' FROM core.permission WHERE code = 'ledger.journal.create'), 'T18 ceiling permission risk unchanged');
END $T$;

-- T18b: CHECKها برای هر نویسنده (تریگرها با replica خاموش؛ تراکنش برگشتی)
BEGIN;
SET LOCAL session_replication_role = replica;
DO $T$
DECLARE c text;
BEGIN
  PERFORM public.as_expect_error('T04 limited period needs a limit',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'tenant', current_date + 40, current_date + 60, 'policy')$q$, '23514');
  -- RV-AST-03: هر کد پایدار LlmError (§۵-۴ سند) در llm_call.error_code و run.error_code پذیرفته است
  FOREACH c IN ARRAY ARRAY['assistant.llm.timeout','assistant.llm.connect','assistant.llm.http_4xx','assistant.llm.http_5xx',
                           'assistant.llm.rate_limited','assistant.llm.malformed','assistant.llm.cancelled','assistant.llm.egress_denied',
                           'assistant.llm.lease_expired','assistant.run.lease_expired','assistant.consent.revoked','assistant.thread.deleted',
                           'assistant.budget.exhausted','assistant.service.disabled'] LOOP
    UPDATE assistant.llm_call SET error_code = c WHERE id = public.k('cl21');
    UPDATE assistant.run SET error_code = c WHERE id = public.k('rA3');
  END LOOP;
  PERFORM public.as_expect_error('T18 error code grammar rejects free text',
    format($q$UPDATE assistant.llm_call SET error_code = 'LLM failed' WHERE id = %L$q$, public.k('cl21')), '23514');
  PERFORM public.as_expect_error('T18 error code grammar needs the assistant prefix',
    format($q$UPDATE assistant.run SET error_code = 'ledger.llm.timeout' WHERE id = %L$q$, public.k('rA3')), '23514');
  PERFORM public.as_expect_error('T18 error code segments start with a letter',
    format($q$UPDATE assistant.run SET error_code = 'assistant.llm.5xx' WHERE id = %L$q$, public.k('rA3')), '23514');
  PERFORM public.as_assert((SELECT count(DISTINCT pg_get_constraintdef(c.oid)) = 1 FROM pg_constraint c
                             WHERE c.conname IN ('run_error_code_check','llm_call_error_code_check','tool_call_error_code_check')
                               AND c.connamespace = 'assistant'::regnamespace)
                           AND (SELECT count(*) = 3 FROM pg_constraint c
                             WHERE c.conname IN ('run_error_code_check','llm_call_error_code_check','tool_call_error_code_check')
                               AND c.connamespace = 'assistant'::regnamespace),
                           'T18 run, llm_call and tool_call share one error-code grammar');
  -- RV-X1-08: حتی اگر مجوزی بی‌نگهبان critical شود، سقف آن را در زمان خواندن کنار می‌گذارد (fail-closed)
  UPDATE core.permission SET risk = 'critical' WHERE code = 'ledger.journal.create';
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.v_permission_ceiling WHERE permission_code = 'ledger.journal.create'),
                           'T18 the ceiling view excludes a permission that became critical');
  UPDATE core.permission SET deprecated_at = now() WHERE code = 'ledger.account.read';
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.v_permission_ceiling WHERE permission_code = 'ledger.account.read'),
                           'T18 the ceiling view excludes a deprecated permission');
END $T$;
ROLLBACK;

-- T19: ردیف‌های ساختگی (بدون تریگر) برای انقضا، رهاسازی، پاک‌سازی، حذف دادهٔ شخصی، توقیف قانونی و مهلت اجرا
SET session_replication_role = replica;
INSERT INTO assistant.thread (tenant_id, id, user_id, company_id, title, created_at, last_activity_at) VALUES
  (public.k('A'), public.k('tOld'), public.k('a1'), public.k('A.C1'), 'گفت‌وگوی قدیمی', now() - interval '200 days', now() - interval '199 days'),
  (public.k('A'), public.k('tExp'), public.k('a1'), public.k('A.C1'), 'پیشنهاد منقضی', now() - interval '8 days', now() - interval '8 days'),
  (public.k('A'), public.k('tVo'),  public.k('a1'), public.k('A.C1'), 'خیلی قدیمی', now() - interval '400 days', now() - interval '400 days'),
  (public.k('A'), public.k('tHc'),  public.k('a3'), public.k('A.C2'), 'شرکت توقیف', now() - interval '200 days', now() - interval '200 days'),
  (public.k('A'), public.k('tHs'),  public.k('a2'), public.k('A.C1'), 'شخص توقیف', now() - interval '200 days', now() - interval '200 days'),
  (public.k('A'), public.k('tHr'),  public.k('a3'), public.k('A.C1'), 'رشتهٔ توقیف', now() - interval '200 days', now() - interval '200 days'),
  (public.k('A'), public.k('tA3o'), public.k('a3'), public.k('A.C1'), 'گفت‌وگوی تازهٔ فروشنده', now() - interval '10 days', now() - interval '10 days');
INSERT INTO assistant.run (tenant_id, id, thread_id, user_id, company_id, purpose, status, consent_id, provider_source, provider_code,
                           provider_version, provider_fingerprint, model, policy_version, prompt_version, prompt_sha256, toolset_sha256,
                           tenant_usage_id, user_usage_id, started_at, lease_expires_at, finished_at, error_code) VALUES
  (public.k('A'), public.k('rOld'), public.k('tOld'), public.k('a1'), public.k('A.C1'), 'chat', 'running', public.k('cA4'), 'platform', 'ir-main', 3,
   public.fp('P'), 'hoosh-7b-instruct', 1, 'fa-chat-v1', sha256('\x00'::bytea), sha256('\x00'::bytea), public.k('uA'), public.k('ua1'),
   now() - interval '30 minutes', now() - interval '20 minutes', NULL, NULL),
  (public.k('A'), public.k('rExp'), public.k('tExp'), public.k('a1'), public.k('A.C1'), 'chat', 'completed', public.k('cA4'), 'platform', 'ir-main', 3,
   public.fp('P'), 'hoosh-7b-instruct', 1, 'fa-chat-v1', sha256('\x00'::bytea), sha256('\x00'::bytea), public.k('uA'), public.k('ua1'),
   now() - interval '8 days', now() - interval '8 days' + interval '5 minutes', now() - interval '8 days' + interval '1 minute', NULL),
  (public.k('A'), public.k('rAnc'), NULL, public.k('a1'), public.k('A.C1'), 'chat', 'failed', public.k('cA4'), 'platform', 'ir-main', 3,
   public.fp('P'), 'hoosh-7b-instruct', 1, 'fa-chat-v1', sha256('\x00'::bytea), sha256('\x00'::bytea), public.k('uA'), public.k('ua1'),
   now() - interval '401 days', now() - interval '401 days' + interval '5 minutes', now() - interval '401 days' + interval '1 minute', 'assistant.run.lease_expired'),
  (public.k('A'), public.k('rHm'), NULL, public.k('a1'), public.k('A.C1'), 'chat', 'failed', public.k('cA4'), 'platform', 'ir-main', 3,
   public.fp('P'), 'hoosh-7b-instruct', 1, 'fa-chat-v1', sha256('\x00'::bytea), sha256('\x00'::bytea), public.k('uA'), public.k('ua1'),
   now() - interval '402 days', now() - interval '402 days' + interval '5 minutes', now() - interval '402 days' + interval '1 minute', 'assistant.run.lease_expired'),
  (public.k('A'), public.k('rDl'), NULL, public.k('a3'), public.k('A.C1'), 'migration_mapping', 'running', public.k('cA4'), 'platform', 'ir-main', 3,
   public.fp('P'), 'hoosh-7b-instruct', 1, 'fa-chat-v1', sha256('\x00'::bytea), sha256('\x00'::bytea), public.k('uA'), public.k('ua3'),
   now() - interval '14 minutes', now() + interval '1 minute', NULL, NULL);
INSERT INTO assistant.llm_call (tenant_id, id, run_id, round_no, user_id, tenant_usage_id, user_usage_id, provider_fingerprint, model, status,
                                started_at, lease_expires_at, finished_at, reserved_prompt_tokens, reserved_completion_tokens, prompt_tokens,
                                completion_tokens, price_unit, input_price_per_mtok, output_price_per_mtok, finish_reason) VALUES
  (public.k('A'), public.k('clOld'), public.k('rOld'), 1, public.k('a1'), public.k('uA'), public.k('ua1'), public.fp('P'), 'hoosh-7b-instruct', 'in_flight',
   now() - interval '30 minutes', now() - interval '25 minutes', NULL, 700, 300, NULL, NULL, 'IRR', 20000, 80000, NULL),
  (public.k('A'), public.k('clExp'), public.k('rExp'), 1, public.k('a1'), public.k('uA'), public.k('ua1'), public.fp('P'), 'hoosh-7b-instruct', 'completed',
   now() - interval '8 days', now() - interval '8 days' + interval '3 minutes', now() - interval '8 days' + interval '1 minute', 500, 500, 400, 100,
   'IRR', 20000, 80000, 'tool_calls');
INSERT INTO assistant.tool_call (tenant_id, id, run_id, llm_call_id, thread_id, user_id, seq, tool_code, tool_version, status, args, result,
                                 permissions_checked, latency_ms, created_at) VALUES
  (public.k('A'), public.k('tcExp'), public.k('rExp'), public.k('clExp'), public.k('tExp'), public.k('a1'), 1, 'ledger.propose_journal', 1, 'ok',
   '{}', '{"lines": 2}', '{ledger.account.read}', 15, now() - interval '8 days');
INSERT INTO assistant.message (tenant_id, thread_id, user_id, run_id, seq, role, content, created_at) VALUES
  (public.k('A'), public.k('tExp'), public.k('a1'), public.k('rExp'), 1, 'user', 'سند اجاره را پیشنهاد بده', now() - interval '8 days');
INSERT INTO assistant.proposal (tenant_id, id, tool_call_id, run_id, thread_id, user_id, company_id, kind, title, payload, valid, status,
                                created_at, expires_at) VALUES
  (public.k('A'), public.k('prExp'), public.k('tcExp'), public.k('rExp'), public.k('tExp'), public.k('a1'), public.k('A.C1'), 'journal_draft',
   'پیش‌نویس منقضی', '{"lines": 2}', true, 'proposed', now() - interval '8 days', now() - interval '1 day');
-- ردیف‌های ساختگی بدون تریگر سنجش درج شدند؛ شمارنده‌های دوره همان کاری را می‌کنند که درون‌ریزی .hkx با ردیف‌های صادرشده می‌کند
UPDATE assistant.usage_period u
   SET (tokens_in_flight, tokens_charged, cost_in_flight, cost_charged, calls, calls_in_flight) =
       (SELECT t.tokens_committed - t.tokens_charged, t.tokens_charged, t.cost_committed - t.cost_charged, t.cost_charged, t.calls, t.in_flight
          FROM assistant.usage_totals(u.tenant_id, u.id) t)
 WHERE u.tenant_id = public.k('A');
-- ImportHook دستیار: اجرای بی‌رشته (رشته صادر نشده) جدا می‌شود؛ بیرون از replica رد می‌شود
SELECT public.as_assert(assistant.import_detach_orphan_runs() = 0, 'T19 import hook: no orphan run when every thread is present');
SET session_replication_role = origin;
DO $T$
BEGIN
  PERFORM public.as_expect_error('T19 import hook runs only inside the replica import', $q$SELECT assistant.import_detach_orphan_runs()$q$, 'HK_AST_SYSTEM_ONLY');
END $T$;

CREATE OR REPLACE FUNCTION public.as_hold_then_purge() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO core.legal_hold (tenant_id, scope, reason, placed_by) VALUES (core.current_tenant_id(), 'tenant', 'دعوای حقوقی آزمایشی', public.k('a1'));
  PERFORM assistant.purge_threads(now() - interval '100 days');
END $$;

SET ROLE hk_app;
DO $T$
DECLARE n integer; v_subject_hold uuid;
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.usage_drift()), 'T19 counters match the derived usage before reaping');
  n := assistant.reap_expired();
  PERFORM public.as_assert(n = 2, 'T19 reaper handles one call and one run (got ' || n || ')');
  PERFORM public.as_assert((SELECT status = 'abandoned' AND usage_estimated AND prompt_tokens = 700 AND completion_tokens = 300
                                   AND error_code = 'assistant.llm.lease_expired' AND charged_cost = 38
                              FROM assistant.llm_call WHERE id = public.k('clOld')), 'T19 abandoned call charges its full reservation');
  PERFORM public.as_assert((SELECT status = 'failed' AND error_code = 'assistant.run.lease_expired' FROM assistant.run WHERE id = public.k('rOld')),
                           'T19 expired run failed');
  -- RV-AST-11: اجرای reaper هم رویداد سنجش دارد (پیش‌تر فقط مسیر موفق می‌نوشت)
  PERFORM public.as_assert((SELECT count(*) = 1 AND bool_and(payload->>'outcome' = 'failed' AND payload->>'usage_estimated' = 'true'
                                                     AND payload->>'cost' = '38.0000' AND payload->>'cost_unit' = 'IRR'
                                                     AND payload->>'prompt_tokens' = '700' AND NOT payload ? 'user_id')
                              FROM core.outbox_event WHERE event_type = 'assistant.run.metered' AND aggregate_id = public.k('rOld')),
                           'T19 reaped run emits assistant.run.metered (estimated usage, no user id)');
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.usage_drift()), 'T19 counters match the derived usage after reaping');
  PERFORM public.as_ctx(NULL, NULL);
  PERFORM public.as_expect_error('T19 reaper needs a tenant', $q$SELECT assistant.reap_expired()$q$, 'HK_AST_CONTEXT');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T19 purge only in system context', $q$SELECT assistant.purge_threads(now() - interval '100 days')$q$, 'HK_AST_SYSTEM_ONLY');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM set_config('app.impersonation_session_id', '80a00000-0000-7000-8000-00000000dead', true);
  PERFORM public.as_expect_error('T19 purge never under impersonation', $q$SELECT assistant.purge_threads(now() - interval '100 days')$q$, 'HK_AST_SYSTEM_ONLY');
  PERFORM set_config('app.impersonation_session_id', '', true);
  PERFORM public.as_expect_error('T19 retention at least one day', $q$SELECT assistant.purge_threads(now())$q$, 'HK_AST_RETENTION');
  -- RV-AST-22: cutoff از دورهٔ نگهداری مستأجر (core.retention_period، پیش‌فرض ۹۰ روز) تازه‌تر نمی‌شود
  PERFORM public.as_expect_error('T19 purge cutoff never newer than the tenant retention period',
    $q$SELECT assistant.purge_threads(now() - interval '30 days')$q$, 'HK_AST_RETENTION');
  PERFORM public.as_expect_error('T19 tenant-wide legal hold blocks purge', $q$SELECT public.as_hold_then_purge()$q$, 'HK_AST_LEGAL_HOLD');
  PERFORM public.as_assert((SELECT count(*) FROM core.legal_hold) = 0, 'T19 hold rolled back with the failed purge');
  -- RV-AST-02: توقیف شرکت، شخص و منبع فقط همان رشته‌ها را نگه می‌دارد (پیش‌تر نادیده گرفته می‌شدند یا کل پاک‌سازی را می‌بستند)
  INSERT INTO core.legal_hold (tenant_id, scope, company_id, reason, placed_by) VALUES (public.k('A'), 'company', public.k('A.C2'), 'توقیف شرکت کفش', public.k('a1'));
  INSERT INTO core.legal_hold (tenant_id, scope, subject_type, subject_id, reason, placed_by)
  VALUES (public.k('A'), 'subject', 'user', public.k('a2'), 'توقیف شخص حسابدار', public.k('a1')) RETURNING id INTO v_subject_hold;
  INSERT INTO core.legal_hold (tenant_id, scope, resource_type, resource_id, reason, placed_by)
  VALUES (public.k('A'), 'resource', 'assistant.thread', public.k('tHr'), 'توقیف یک گفت‌وگو', public.k('a1'));
  INSERT INTO core.legal_hold (tenant_id, scope, resource_type, resource_id, reason, placed_by)
  VALUES (public.k('A'), 'resource', 'assistant.run', public.k('rHm'), 'توقیف سنجش یک اجرا', public.k('a1'));
  n := assistant.purge_threads(now() - interval '2000 days');
  PERFORM public.as_assert(n = 1 AND NOT EXISTS (SELECT 1 FROM assistant.run WHERE thread_id = public.k('tVo')),
                           'T19 conversation retention is capped at 365 days even for an older cutoff (got ' || n || ')');
  n := assistant.purge_threads(now() - interval '100 days');
  PERFORM public.as_assert(n = 1, 'T19 purge deletes only unheld threads older than the cutoff (got ' || n || ')');
  PERFORM public.as_assert((SELECT thread_id IS NULL FROM assistant.run WHERE id = public.k('rOld')), 'T19 purged thread, run detached');
  PERFORM set_config('hk.assistant_system', 'retention', true);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread WHERE id IN (public.k('tHc'), public.k('tHs'), public.k('tHr'))) = 3
                           AND NOT EXISTS (SELECT 1 FROM assistant.thread WHERE id IN (public.k('tOld'), public.k('tVo'))),
                           'T19 company, subject and resource holds keep exactly their threads');
  PERFORM set_config('hk.assistant_system', '', true);
  -- حذف دادهٔ شخصی (ErasureHook)
  PERFORM public.as_expect_error('T19 legal hold on the person blocks erasure',
    format($q$SELECT assistant.erase_user_content(%L)$q$, public.k('a2')), 'HK_AST_LEGAL_HOLD');
  UPDATE core.legal_hold SET released_at = now(), released_by = public.k('a1') WHERE id = v_subject_hold;
  n := assistant.erase_user_content(public.k('a2'));
  PERFORM public.as_assert(n = 2, 'T19 erasure deletes every thread of the person (got ' || n || ')');
  n := assistant.erase_user_content(public.k('a3'));
  PERFORM public.as_assert(n = 1, 'T19 erasure keeps threads under a company or resource hold (got ' || n || ')');
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread) = 0 AND (SELECT count(*) FROM assistant.run WHERE user_id = public.k('a2')) >= 1,
                           'T19 erased person has no content; metering kept');
  PERFORM public.as_expect_error('T19 erasure only in system context',
    format($q$SELECT assistant.erase_user_content(%L)$q$, public.k('a2')), 'HK_AST_SYSTEM_ONLY');
  -- RV-AST-21: هیچ دوری از مهلت مطلق ۱۵ دقیقهٔ اجرا فراتر نمی‌رود
  PERFORM public.as_ctx(public.k('A'), public.k('a3'));
  PERFORM public.as_expect_error('T19 a round never outlives the 15-minute run deadline',
    format($q$SELECT public.as_new_call(NULL, %L, 1, p_lease => interval '3 minutes')$q$, public.k('rDl')), 'HK_AST_RUN_DEADLINE');
  PERFORM public.as_new_call(NULL, public.k('rDl'), 1, p_lease => interval '20 seconds');
  -- انقضای پیشنهاد
  PERFORM public.as_ctx(public.k('A'), public.k('a1'), 'assistant_confirm');
  PERFORM public.as_expect_error('T19 expired proposal cannot be materialized',
    format($q$UPDATE assistant.proposal SET status = 'materialized', decided_by = %L, target_type = 'ledger.journal_draft', target_id = uuidv7() WHERE id = %L$q$,
           public.k('a1'), public.k('prExp')), 'HK_AST_PROPOSAL_EXPIRED');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.proposal) = 0, 'T19 no proposal is visible without a user or a system purpose');
  PERFORM set_config('hk.assistant_system', 'proposal_expiry', true);
  PERFORM public.as_expect_error('T19 expiry has no actor',
    format($q$UPDATE assistant.proposal SET status = 'expired', decided_by = %L WHERE id = %L$q$, public.k('a1'), public.k('prExp')), 'HK_AST_PROPOSAL_STATE');
  PERFORM set_config('hk.assistant_system', '', true);
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T19 proposal expiry only in system context', $q$SELECT assistant.expire_proposals()$q$, 'HK_AST_SYSTEM_ONLY');
  PERFORM public.as_ctx(public.k('A'), NULL);
  n := assistant.expire_proposals();
  PERFORM public.as_assert(n = 1, 'T19 expiry job expires the due proposal (got ' || n || ')');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_assert((SELECT status = 'expired' AND decided_at IS NOT NULL AND decided_by IS NULL FROM assistant.proposal WHERE id = public.k('prExp')),
                           'T19 system context expires the proposal');
  PERFORM public.as_ctx(public.k('A'), NULL);
  -- نگهداری سنجش (و توقیف قانونی آن؛ RV-AST-02)
  DELETE FROM assistant.run WHERE id = public.k('rAnc');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.as_assert(n = 1, 'T19 metering older than 400 days can be purged');
  PERFORM public.as_expect_error('T19 legal hold keeps old metering', format($q$DELETE FROM assistant.run WHERE id = %L$q$, public.k('rHm')), 'HK_AST_LEGAL_HOLD');
  PERFORM public.as_expect_error('T19 recent run is kept', format($q$DELETE FROM assistant.run WHERE id = %L$q$, public.k('rA1')), 'HK_AST_RETENTION');
  PERFORM public.as_expect_error('T19 recent call is kept', format($q$DELETE FROM assistant.llm_call WHERE id = %L$q$, public.k('cl11')), 'HK_AST_RETENTION');
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.usage_drift()), 'T19 counters match the derived usage at the end');
END $T$;
RESET ROLE;

-- T19b: توقیف قانونی روی سنجش قدیمی دوره و دور (ردیف‌های ساختگی؛ در تراکنش برگشتی)
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO assistant.usage_period (tenant_id, id, scope, user_id, period_start, period_end, token_limit, limit_source)
VALUES (public.k('A'), '80a00000-0000-7000-8000-00000000ee99', 'user', public.k('a3'), current_date - 500, current_date - 470, 10, 'policy');
INSERT INTO assistant.llm_call (tenant_id, id, run_id, round_no, user_id, tenant_usage_id, user_usage_id, provider_fingerprint, model, status,
                                started_at, lease_expires_at, finished_at, reserved_prompt_tokens, reserved_completion_tokens, prompt_tokens,
                                completion_tokens, price_unit, input_price_per_mtok, output_price_per_mtok, error_code)
VALUES (public.k('A'), '80a00000-0000-7000-8000-000000c10099', public.k('rHm'), 1, public.k('a1'), public.k('uA'), public.k('ua1'), public.fp('P'),
        'hoosh-7b-instruct', 'failed', now() - interval '402 days', now() - interval '402 days' + interval '3 minutes',
        now() - interval '402 days' + interval '1 minute', 10, 10, 0, 0, 'IRR', 0, 0, 'assistant.llm.http_4xx');
SET LOCAL session_replication_role = origin;
SET LOCAL ROLE hk_app;
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  INSERT INTO core.legal_hold (tenant_id, scope, subject_type, subject_id, reason, placed_by)
  VALUES (public.k('A'), 'subject', 'user', public.k('a3'), 'توقیف شخص فروشنده', public.k('a1'));
  PERFORM public.as_expect_error('T19b limits of an ended usage period are history',
    $q$UPDATE assistant.usage_period SET token_limit = 5 WHERE id = '80a00000-0000-7000-8000-00000000ee99'$q$, 'HK_AST_USAGE_IMMUTABLE');
  PERFORM public.as_expect_error('T19b legal hold on the person keeps an old usage period',
    $q$DELETE FROM assistant.usage_period WHERE id = '80a00000-0000-7000-8000-00000000ee99'$q$, 'HK_AST_LEGAL_HOLD');
  PERFORM public.as_expect_error('T19b legal hold on a run keeps its old model calls',
    $q$DELETE FROM assistant.llm_call WHERE id = '80a00000-0000-7000-8000-000000c10099'$q$, 'HK_AST_LEGAL_HOLD');
END $T$;
ROLLBACK;

-- T20: lint امنیتی هسته روی اسکیمای assistant، lint کاتالوگ، grantها
DO $T$
DECLARE v_def text; v_bad text;
BEGIN
  -- C-AS-04 پذیرفته شد: security_lint هسته اسکیماها را از core.data_plane_schemas() می‌گیرد، پس assistant را هم lint می‌کند
  PERFORM public.as_assert(EXISTS (SELECT 1 FROM core.data_plane_schemas() s WHERE s.nspname = 'assistant'), 'T20 core security lint covers the assistant schema');
  SELECT string_agg(object || ' ' || problem, '; ') INTO v_bad FROM core.security_lint() WHERE object LIKE 'assistant.%';
  PERFORM public.as_assert(v_bad IS NULL, 'T20 core security lint clean for assistant: ' || coalesce(v_bad, ''));
  PERFORM public.as_assert((SELECT count(*) FROM core.export_table_registry WHERE schema_name = 'assistant') = 11, 'T20 every assistant table is in the export registry');
  -- RV-AST-01: محتوای گفت‌وگو هرگز «rows» (صدور خام در بستهٔ قابل دانلود مالک) نیست
  PERFORM public.as_assert((SELECT count(*) FROM core.export_table_registry WHERE schema_name = 'assistant' AND mode = 'hook'
                              AND table_name IN ('thread','message','tool_call','proposal','feedback')) = 5
                           AND NOT EXISTS (SELECT 1 FROM core.export_table_registry WHERE schema_name = 'assistant' AND mode = 'rows'
                                             AND cardinality(pii_columns) > 0 AND table_name <> 'consent'),
                           'T20 conversation tables are exported only through the assistant.conversations hook');
  -- RV-AST-13: هر FK درون اسکیمای assistant (به جدول مستأجری) نمایه‌ای با همان ستون‌های پیشرو دارد
  --          (نمایه با (tenant_id, ستونِ ارجاع‌دهنده به id مقصد) آغاز شود؛ حذف رشته و پاک‌سازی بدون پویش کامل)
  WITH fk AS (
    SELECT c.conrelid, c.conname,
           (SELECT c.conkey[j] FROM generate_subscripts(c.confkey, 1) j
             WHERE c.confkey[j] = (SELECT a.attnum FROM pg_attribute a WHERE a.attrelid = c.confrelid AND a.attname = 'id')) AS id_col,
           (SELECT a.attnum FROM pg_attribute a WHERE a.attrelid = c.conrelid AND a.attname = 'tenant_id') AS tenant_col
      FROM pg_constraint c
     WHERE c.contype = 'f' AND c.connamespace = 'assistant'::regnamespace
       AND c.confrelid::regclass::text LIKE 'assistant.%'
       AND EXISTS (SELECT 1 FROM pg_attribute x WHERE x.attrelid = c.confrelid AND x.attname = 'tenant_id'))
  SELECT string_agg(fk.conrelid::regclass || ' ' || fk.conname, '; ') INTO v_bad
    FROM fk
   WHERE NOT EXISTS (SELECT 1 FROM pg_index i
                      WHERE i.indrelid = fk.conrelid AND i.indkey[0] = fk.tenant_col AND i.indkey[1] = fk.id_col);
  PERFORM public.as_assert(v_bad IS NULL, 'T20 every intra-schema FK has a supporting index: ' || coalesce(v_bad, ''));
  SELECT string_agg(object || ' ' || problem, '; ') INTO v_bad FROM assistant.catalog_lint() WHERE problem <> 'permission_not_in_core_catalog';
  PERFORM public.as_assert(v_bad IS NULL, 'T20 catalog lint clean (except catalog sync of other modules): ' || coalesce(v_bad, ''));
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.v_permission_ceiling c JOIN core.permission p ON p.code = c.permission_code WHERE p.risk = 'critical'),
                           'T20 no critical permission in the ceiling');
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.v_permission_ceiling c WHERE c.model_initiated AND c.permission_code !~ '\.read$'),
                           'T20 model-initiated ceiling is read-only');
  PERFORM public.as_assert(NOT has_table_privilege('hk_app', 'assistant.message', 'UPDATE') AND NOT has_table_privilege('hk_app', 'assistant.message', 'DELETE')
                           AND NOT has_table_privilege('hk_app', 'assistant.tool_call', 'UPDATE') AND NOT has_table_privilege('hk_app', 'assistant.tool_call', 'DELETE')
                           AND NOT has_table_privilege('hk_app', 'assistant.consent', 'DELETE') AND NOT has_table_privilege('hk_app', 'assistant.tenant_policy', 'DELETE')
                           AND NOT has_table_privilege('hk_app', 'assistant.tool', 'INSERT'), 'T20 append-only and catalog grants');
  PERFORM public.as_assert((SELECT count(*) FROM core.permission WHERE module = 'assistant') = 5
                           AND (SELECT count(*) FROM core.setting_def WHERE module = 'assistant') = 5
                           AND NOT EXISTS (SELECT 1 FROM core.setting_def WHERE key = 'assistant.retention_days')
                           AND (SELECT count(*) FROM core.retention_class WHERE code LIKE 'assistant_%') = 2, 'T20 core catalogs registered');
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM core.role_template_permission WHERE permission_code IN ('assistant.consent.manage','assistant.provider.manage')),
                           'T20 consent and provider management stay with the owner role');
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'assistant' AND p.prosecdef),
                           'T20 no SECURITY DEFINER in assistant');
  PERFORM public.as_expect_error('T20 messages immutable even for the owner',
    $q$UPDATE assistant.message SET input_mode = 'text'$q$, 'HK_IMMUTABLE');
  PERFORM public.as_expect_error('T20 tool calls immutable even for the owner',
    $q$UPDATE assistant.tool_call SET latency_ms = 1$q$, 'HK_IMMUTABLE');
  -- RV-AST-24: حذف تکی پیام یا فراخوانی ابزار حتی برای مالک جدول ممنوع است (فقط آبشاری از رشته)
  PERFORM public.as_expect_error('T20 single message delete rejected even for the owner',
    format($q$DELETE FROM assistant.message WHERE id = %L$q$, public.k('m4')), 'HK_AST_APPEND_ONLY');
  PERFORM public.as_expect_error('T20 single tool call delete rejected even for the owner',
    format($q$DELETE FROM assistant.tool_call WHERE id = %L$q$, public.k('tcExp')), 'HK_AST_APPEND_ONLY');
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.v_permission_ceiling c LEFT JOIN core.permission p ON p.code = c.permission_code
                                        WHERE p.code IS NULL), 'T20 ceiling lists only registered permissions');
  -- RV-AST-11: پایان هر اجرا (کامل، لغو، شکست، reaper) دقیقاً یک رویداد سنجش بی‌محتوا دارد
  PERFORM public.as_assert((SELECT count(*) FROM core.outbox_event e WHERE e.event_type = 'assistant.run.metered'
                              AND e.aggregate_id IN (public.k('rA1'), public.k('rA2'), public.k('rA3'), public.k('rA4'), public.k('rOld'))) = 5
                           AND (SELECT payload->>'llm_calls' = '3' AND payload->>'prompt_tokens' = '2300' AND payload->>'outcome' = 'completed'
                                       AND payload->>'cost_unit' = 'IRR' AND NOT payload ? 'content'
                                  FROM core.outbox_event WHERE event_type = 'assistant.run.metered' AND aggregate_id = public.k('rA1'))
                           AND (SELECT payload->>'outcome' = 'cancelled' FROM core.outbox_event
                                 WHERE event_type = 'assistant.run.metered' AND aggregate_id = public.k('rA2'))
                           AND EXISTS (SELECT 1 FROM core.outbox_delivery d JOIN core.outbox_event e ON e.id = d.event_id
                                        WHERE e.aggregate_id = public.k('rA1') AND d.subscriber = 'uplink'),
                           'T20 every finished run emitted exactly one assistant.run.metered (delivered to uplink)');
  PERFORM public.as_assert((SELECT count(*) FROM core.outbox_event WHERE event_type = 'assistant.run.metered') =
                           (SELECT count(*) FROM assistant.run WHERE status <> 'running' AND id NOT IN (public.k('rExp'), public.k('rHm'))),
                           'T20 no finished run without its metering event (rExp and rHm are T19 rows inserted without triggers)');
  -- RV-AST-11: ریال صحیح ai.cost بدون ضرب پنهان و با گرد کردن رو به بالا
  PERFORM public.as_assert(assistant.cost_to_irr(38.0000, 'IRR') = 38 AND assistant.cost_to_irr(38.0001, 'IRR') = 39
                           AND assistant.cost_to_irr(12.3456, 'IRT') = 124 AND assistant.cost_to_irr(1.5, 'IRR_NEW', 10000) = 15000
                           AND assistant.cost_to_irr(0, 'IRT') = 0, 'T20 cost_to_irr vectors');
  PERFORM public.as_expect_error('T20 IRR_NEW cost needs the dated redenomination factor',
    $q$SELECT assistant.cost_to_irr(1.5, 'IRR_NEW')$q$, 'HK_AST_COST_UNIT');
  PERFORM public.as_expect_error('T20 negative cost rejected', $q$SELECT assistant.cost_to_irr(-1, 'IRR')$q$, 'HK_AST_COST_UNIT');
  -- RV-AST-12: شمارنده‌ها با تعریف مرجع برابرند (هر دو مستأجر)
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.usage_drift()), 'T20 tenant A usage counters equal the derived totals');
  PERFORM public.as_ctx(public.k('B'), NULL);
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.usage_drift()), 'T20 tenant B usage counters equal the derived totals');
  PERFORM public.as_ctx(NULL, NULL);
END $T$;

-- T20b: مسیر «تریگر تو در تو» نگهبان رشته: فقط پیشروی شمارنده مجاز است (در تراکنش برگشتی)
BEGIN;
CREATE TEMP TABLE as_nested_probe (x int);
CREATE FUNCTION pg_temp.as_nested_rename() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  UPDATE assistant.thread SET title = 'تغییر تو در تو' WHERE id = public.k('tA2');
  RETURN NEW;
END $f$;
CREATE TRIGGER as_nested BEFORE INSERT ON as_nested_probe FOR EACH ROW EXECUTE FUNCTION pg_temp.as_nested_rename();
DO $T$
BEGIN
  PERFORM public.as_expect_error('T20b nested trigger may only advance the message counter',
    $q$INSERT INTO as_nested_probe VALUES (1)$q$, 'HK_AST_THREAD_IMMUTABLE');
END $T$;
ROLLBACK;

-- T21: نگهبان پیشنهادی هسته (C-AS-02) روی جدول ثبت دفتر کل؛ در تراکنش برگشتی نصب و آزموده می‌شود
BEGIN;
CREATE TRIGGER "0_assistant_guard_demo" BEFORE INSERT ON ledger.journal_line FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant();
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'), 'assistant_confirm');
  PERFORM public.as_expect_error('T21 human-confirmed assistant transaction cannot post GL lines',
    format($q$INSERT INTO ledger.journal_line (tenant_id) VALUES (%L)$q$, public.k('A')), 'HK_AST_VIA_ASSISTANT');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'), 'assistant');
  PERFORM public.as_expect_error('T21 model-initiated transaction cannot post GL lines',
    format($q$INSERT INTO ledger.journal_line (tenant_id) VALUES (%L)$q$, public.k('A')), 'HK_AST_VIA_ASSISTANT');
END $T$;
ROLLBACK;

-- T22: بردار اثرانگشت مشترک با پایتون
SELECT public.as_assert(count(*) = 7 AND bool_and(assistant.provider_fingerprint(v->>'operator', v->>'base_url', v->>'data_location', v->>'model') = v->>'expected'),
                        'T22 provider fingerprint vectors hkllm2 (SQL == Python)')
  FROM jsonb_array_elements((:'fp_vectors')::jsonb -> 'vectors') v;
SELECT public.as_assert(count(*) = 3 AND bool_and(NOT assistant.is_clean_operator(v->>'operator')), 'T22 ambiguous operators are rejected before hashing')
  FROM jsonb_array_elements((:'fp_vectors')::jsonb -> 'rejected_operators') v;

-- =====================================================================
-- T23: هم‌روندی واقعی (دو نشست با dblink، نقش hk_app) و سطح جداسازی — RV-AST-04، RV-AST-05.
-- سقف هم‌زمانی و بودجه با «قفل ردیف، سپس خواندن تازه» اجبار می‌شوند؛ نشست دوم باید منتظر قفل بماند و پس از commit
-- نشست اول با HK_AST_CONCURRENCY یا HK_AST_BUDGET_TOKENS رد شود. جهش «بدون FOR UPDATE» این آزمون را می‌شکند.
-- پیش‌نیاز: افزونهٔ contrib «dblink» و احراز trust/peer روی سوکت محلی (همان پیش‌نیاز T29 دفتر کل)؛ در نبود آن NOTICE «SKIP».
-- =====================================================================
RESET ROLE;
BEGIN;
INSERT INTO core.tenant (id, slug, display_name, deployment) VALUES (public.k('C'), 'as-tenant-c', 'C', 'saas_shared');
INSERT INTO core.company (tenant_id, id, code, name) VALUES (public.k('C'), public.k('C.C1'), 'C1', 'کافه پ');
INSERT INTO core.app_user (id, kind, display_name) VALUES
  (public.k('c1'), 'human', 'مالک پ'), (public.k('c2'), 'human', 'صندوق‌دار پ'), (public.k('c3'), 'human', 'حسابدار پ');
INSERT INTO core.tenant_membership (tenant_id, user_id, status, is_owner, joined_at) VALUES
  (public.k('C'), public.k('c1'), 'active', true, now()), (public.k('C'), public.k('c2'), 'active', false, now()),
  (public.k('C'), public.k('c3'), 'active', false, now());
COMMIT;
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('C'), NULL);
  PERFORM public.as_expect_error('T23 no usage period without the tenant assistant policy',
    format($q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, token_limit, limit_source)
              VALUES (%L, 'tenant', current_date - 10, current_date + 20, 10000, 'policy')$q$, public.k('C')), 'HK_AST_USAGE_LIMIT');
  INSERT INTO assistant.tenant_policy (tenant_id, id, source, document, signature, signer_kid)
  VALUES (public.k('C'), public.k('polC'), 'dev_fixture',
          public.as_policy_doc(1, '{chat}', public.fp('P'), NULL, false, 10000, NULL, NULL, 1),
          decode(repeat('ef', 64), 'hex'), 'dev-key');
  INSERT INTO assistant.usage_period (tenant_id, id, scope, user_id, period_start, period_end, token_limit, limit_source) VALUES
    (public.k('C'), public.k('uC'),  'tenant', NULL,           current_date - 10, current_date + 20, 10000, 'policy'),
    (public.k('C'), public.k('uc1'), 'user',   public.k('c1'), current_date - 10, current_date + 20, NULL,  'unlimited'),
    (public.k('C'), public.k('uc2'), 'user',   public.k('c2'), current_date - 10, current_date + 20, NULL,  'unlimited'),
    (public.k('C'), public.k('uc3'), 'user',   public.k('c3'), current_date - 10, current_date + 20, NULL,  'unlimited');
  PERFORM public.as_ctx(public.k('C'), public.k('c1'));
  PERFORM public.as_grant_consent(public.k('cC1'), '{chat}', '{financial_aggregate}', ARRAY[public.fp('P')]);
  INSERT INTO assistant.thread (tenant_id, id, user_id, company_id) VALUES (public.k('C'), public.k('tC1'), public.k('c1'), public.k('C.C1'));
  PERFORM public.as_ctx(public.k('C'), public.k('c2'));
  INSERT INTO assistant.thread (tenant_id, id, user_id, company_id) VALUES (public.k('C'), public.k('tC2'), public.k('c2'), public.k('C.C1'));
  PERFORM public.as_ctx(public.k('C'), public.k('c3'));
  INSERT INTO assistant.thread (tenant_id, id, user_id, company_id) VALUES (public.k('C'), public.k('tC3'), public.k('c3'), public.k('C.C1'));
END $T$;

-- سطح جداسازی: درج اجرا و دور فقط در READ COMMITTED (در REPEATABLE READ شمارش زیر قفل کار هم‌زمان را نمی‌دید)
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL ROLE hk_app;
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('C'), public.k('c2'));
  PERFORM public.as_expect_error('T23 run start refused outside READ COMMITTED',
    format($q$SELECT public.as_new_run(NULL, %L)$q$, public.k('tC2')), 'HK_AST_ISOLATION');
END $T$;
ROLLBACK;
BEGIN ISOLATION LEVEL SERIALIZABLE;
SET LOCAL ROLE hk_app;
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('C'), public.k('c2'));
  PERFORM public.as_expect_error('T23 run start refused at SERIALIZABLE too',
    format($q$SELECT public.as_new_run(NULL, %L)$q$, public.k('tC2')), 'HK_AST_ISOLATION');
END $T$;
ROLLBACK;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'dblink') THEN
    CREATE SCHEMA IF NOT EXISTS as_dbl;
    CREATE EXTENSION IF NOT EXISTS dblink SCHEMA as_dbl;
  ELSE
    RAISE NOTICE 'SKIP T23 races: the contrib extension dblink is not installed';
  END IF;
END $$;

-- نشست تازه با hk_app در تراکنش باز و زمینهٔ مستأجر C؛ pid برمی‌گرداند
CREATE OR REPLACE FUNCTION public.as_dbl_open(p_name text, p_user uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_pid integer;
BEGIN
  PERFORM as_dbl.dblink_connect(p_name, format('dbname=%s user=%s host=%s port=%s', current_database(), current_user,
                                               split_part(current_setting('unix_socket_directories'), ',', 1), current_setting('port')));
  PERFORM as_dbl.dblink_exec(p_name, 'SET ROLE hk_app');
  PERFORM as_dbl.dblink_exec(p_name, 'BEGIN');
  PERFORM 1 FROM as_dbl.dblink(p_name, format('SELECT public.as_ctx(%L, %L)::text', public.k('C'), p_user)) AS x(v text);
  SELECT x.pid INTO v_pid FROM as_dbl.dblink(p_name, 'SELECT pg_backend_pid()') AS x(pid integer);
  RETURN v_pid;
END $$;

-- آیا نشست منتظر قفلی است که هنوز به آن نرسیده؟ (تا ۴ ثانیه)
CREATE OR REPLACE FUNCTION public.as_dbl_blocked(p_pid integer) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  FOR i IN 1..200 LOOP
    IF EXISTS (SELECT 1 FROM pg_locks WHERE pid = p_pid AND NOT granted) THEN RETURN true; END IF;
    PERFORM pg_sleep(0.02);
  END LOOP;
  RETURN false;
END $$;

-- نتیجهٔ دستور ناهمگام: مقدار ستون اول، یا «ERROR: پیام»
CREATE OR REPLACE FUNCTION public.as_dbl_finish(p_name text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v text; e text;
BEGIN
  SELECT x.v INTO v FROM as_dbl.dblink_get_result(p_name, false) AS x(v text);
  e := as_dbl.dblink_error_message(p_name);
  PERFORM 1 FROM as_dbl.dblink_get_result(p_name, false) AS x(v text);
  RETURN CASE WHEN e = 'OK' THEN v ELSE 'ERROR: ' || regexp_replace(e, '^ERROR:\s+', '') END;
END $$;

-- سقف اجرای هم‌زمان مستأجر (max_concurrent_runs = 1): اجرای دوم منتظر قفل سیاست می‌ماند و پس از commit اولی رد می‌شود
DO $T$
DECLARE pid_y integer; v text;
BEGIN
  IF to_regnamespace('as_dbl') IS NULL THEN RETURN; END IF;
  PERFORM public.as_dbl_open('x', public.k('c1'));
  PERFORM 1 FROM as_dbl.dblink('x', format('SELECT public.as_new_run(%L, %L)::text', public.k('rC1'), public.k('tC1'))) AS r(v text);
  pid_y := public.as_dbl_open('y', public.k('c2'));
  PERFORM as_dbl.dblink_send_query('y', format('SELECT public.as_new_run(%L, %L)::text', public.k('rC2'), public.k('tC2')));
  PERFORM public.as_assert(public.as_dbl_blocked(pid_y), 'T23 a concurrent run start waits for the tenant policy row lock');
  PERFORM as_dbl.dblink_exec('x', 'COMMIT');
  v := public.as_dbl_finish('y');
  PERFORM as_dbl.dblink_exec('y', 'ROLLBACK');
  PERFORM as_dbl.dblink_disconnect('x');
  PERFORM as_dbl.dblink_disconnect('y');
  PERFORM public.as_assert(v LIKE 'ERROR: HK_AST_CONCURRENCY%', 'T23 tenant concurrency cap holds under a real race (got ' || coalesce(v, 'NULL') || ')');
  PERFORM public.as_ctx(public.k('C'), NULL);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.run WHERE tenant_id = public.k('C') AND status = 'running') = 1,
                           'T23 exactly one running run after the race');
END $T$;

-- بودجهٔ توکن مستأجر (۱۰٬۰۰۰): دو رزرو ۶٬۰۰۰ هم‌زمان؛ دومی منتظر قفل ردیف دوره می‌ماند و پس از commit اولی رد می‌شود
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('C'), NULL);
  PERFORM public.as_policy_patch('{"quotas": {"max_concurrent_runs": 2}}');
  PERFORM public.as_ctx(public.k('C'), public.k('c3'));
  PERFORM public.as_new_run(public.k('rC3'), public.k('tC3'));
END $T$;
DO $T$
DECLARE pid_y integer; v text;
BEGIN
  IF to_regnamespace('as_dbl') IS NULL THEN RETURN; END IF;
  PERFORM public.as_dbl_open('x', public.k('c1'));
  PERFORM 1 FROM as_dbl.dblink('x', format('SELECT public.as_new_call(NULL, %L, 1, 5000, 1000)::text', public.k('rC1'))) AS r(v text);
  pid_y := public.as_dbl_open('y', public.k('c3'));
  PERFORM as_dbl.dblink_send_query('y', format('SELECT public.as_new_call(NULL, %L, 1, 5000, 1000)::text', public.k('rC3')));
  PERFORM public.as_assert(public.as_dbl_blocked(pid_y), 'T23 a concurrent reservation waits for the tenant usage row lock');
  PERFORM as_dbl.dblink_exec('x', 'COMMIT');
  v := public.as_dbl_finish('y');
  PERFORM as_dbl.dblink_exec('y', 'ROLLBACK');
  PERFORM as_dbl.dblink_disconnect('x');
  PERFORM as_dbl.dblink_disconnect('y');
  PERFORM public.as_assert(v LIKE 'ERROR: HK_AST_BUDGET_TOKENS%', 'T23 tenant token budget holds under a real race (got ' || coalesce(v, 'NULL') || ')');
  PERFORM public.as_ctx(public.k('C'), NULL);
  PERFORM public.as_assert((SELECT tokens_committed = 6000 AND tokens_committed <= effective_token_limit FROM assistant.v_usage WHERE id = public.k('uC')),
                           'T23 committed tokens never exceed the cap after the race');
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.usage_drift()), 'T23 counters equal the derived totals after the race');
END $T$;

\echo 'ALL 80_assistant TESTS PASSED'
