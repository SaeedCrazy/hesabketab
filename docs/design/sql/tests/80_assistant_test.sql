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
--   بخش ۴ (postgres): T18 قیدهای کاتالوگ، T19 ردیف‌های ساختگی منقضی (با session_replication_role=replica) و
--          آزمون reap/purge/انقضا با hk_app، T20 lint امنیتی هسته روی اسکیمای assistant و lint کاتالوگ،
--          T21 نمایش نگهبان پیشنهادی هسته روی ledger.journal_line (در تراکنش برگشتی)، T22 بردار اثرانگشت مشترک با پایتون.
-- خروجی موفق با «ALL 80_assistant TESTS PASSED» پایان می‌یابد؛ هر شکست «TEST FAILED [...]» می‌دهد و psql با کد ≠ ۰
-- خارج می‌شود. بردار مشترک: -v fp_vectors_file=docs/design/sql/tests/assistant_fingerprint_v1.json
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
\if :{?fp_vectors_file}
\else
  \set fp_vectors_file docs/design/sql/tests/assistant_fingerprint_v1.json
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
  WHEN 'f1'    THEN '80a00000-0000-7000-8000-000000ac0001'
END)::uuid $$;

-- اثرانگشت‌ها: P = پروفایل اصلی پلتفرم، S = پروفایل دوم (failover)، L = سرور LAN مستأجر، X = مقصدی که سیاست ندارد
CREATE OR REPLACE FUNCTION public.fp(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
SELECT CASE p
  WHEN 'P' THEN '4a43acd40cff6f3730caef30f6d857ecf139d4ed89d983b1c2e435f9ebb2f8f2'
  WHEN 'S' THEN 'da5ba91c78fbaf85dc3aad3834ae740cb300f798034ed343b00cd8a200eb868a'
  WHEN 'L' THEN '78d64de18c546ad3ac0e81d061d818428e6861248a39ebb766c73ccf8c1b2e8e'
  WHEN 'X' THEN '1111111111111111111111111111111111111111111111111111111111111111'
END $$;

BEGIN;
INSERT INTO core.tenant (id, slug, display_name) VALUES
  (public.k('A'), 'as-tenant-a', 'A'), (public.k('B'), 'as-tenant-b', 'B');
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
                                             p_lease interval DEFAULT interval '5 minutes', p_status text DEFAULT 'running') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE p assistant.tenant_policy; v uuid; u uuid := coalesce(p_user, core.current_user_id()); v_company uuid;
BEGIN
  SELECT * INTO p FROM assistant.tenant_policy WHERE tenant_id = core.current_tenant_id();
  SELECT company_id INTO v_company FROM assistant.thread WHERE tenant_id = core.current_tenant_id() AND id = p_thread;
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

CREATE OR REPLACE FUNCTION public.as_proposal(p_id uuid, p_tool_call uuid, p_kind text, p_valid boolean DEFAULT true) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE tc assistant.tool_call; v uuid;
BEGIN
  SELECT * INTO tc FROM assistant.tool_call WHERE tenant_id = core.current_tenant_id() AND id = p_tool_call;
  INSERT INTO assistant.proposal (tenant_id, id, tool_call_id, run_id, thread_id, user_id, company_id, kind, title, payload, validation,
                                  valid, expires_at)
  VALUES (tc.tenant_id, coalesce(p_id, uuidv7()), tc.id, tc.run_id, tc.thread_id, tc.user_id,
          (SELECT company_id FROM assistant.run WHERE id = tc.run_id), p_kind, 'پیش‌نویس سند اجاره',
          '{"date": "2026-11-17", "lines": [{"account": "6101", "debit": "50000000"}, {"account": "1101", "credit": "50000000"}]}',
          jsonb_build_object('ok', p_valid), p_valid, now() + interval '1 day')
  RETURNING id INTO v;
  RETURN v;
END $$;

-- مستأجر A: سیاست، دوره‌های مصرف، رضایت اول، رشتهٔ a1
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  INSERT INTO assistant.tenant_policy (tenant_id, id, policy_version, source, document, signature, signer_kid, entitled, platform_enabled,
                                       features, profile_code, profile_version, profile_fingerprint, secondary_fingerprints,
                                       allow_tenant_provider, tenant_monthly_tokens, tenant_monthly_cost, cost_unit, user_monthly_tokens,
                                       max_concurrent_runs, max_rounds, max_tool_calls)
  VALUES (public.k('A'), public.k('polA'), 1, 'dev_fixture', '{"v": 1}', decode(repeat('ab', 64), 'hex'), 'dev-key', true, true,
          '{chat,proposals,migration_mapping}', 'ir-main', 3, public.fp('P'), ARRAY[public.fp('S')], true, 100000, 5000000, 'IRR', 50000,
          2, 6, 12);
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
  INSERT INTO assistant.tenant_policy (tenant_id, id, policy_version, source, document, signature, signer_kid, entitled, platform_enabled,
                                       features, profile_code, profile_version, profile_fingerprint, allow_tenant_provider,
                                       tenant_monthly_tokens, user_monthly_tokens, max_concurrent_runs)
  VALUES (public.k('B'), public.k('polB'), 1, 'dev_fixture', '{"v": 1}', decode(repeat('cd', 64), 'hex'), 'dev-key', true, true,
          '{chat}', 'ir-main', 3, public.fp('P'), false, 100000, 50000, 3);
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

-- T02: سیاست مستأجر
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_expect_error('T02 policy version must increase',
    $q$UPDATE assistant.tenant_policy SET policy_version = policy_version, max_rounds = 5$q$, 'HK_AST_POLICY_VERSION');
  PERFORM public.as_expect_error('T02 replayed older policy rejected',
    $q$UPDATE assistant.tenant_policy SET policy_version = 0$q$, 'HK_AST_POLICY_VERSION');
  PERFORM public.as_expect_error('T02 disabled needs a reason',
    $q$UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, platform_enabled = false$q$, '23514');
  PERFORM public.as_expect_error('T02 enabled tenant needs a provider source',
    $q$UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, profile_code = NULL, profile_version = NULL,
         profile_fingerprint = NULL, allow_tenant_provider = false$q$, '23514');
  PERFORM public.as_expect_error('T02 signature is Ed25519 sized',
    $q$UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, signature = '\x00'::bytea$q$, '23514');
  PERFORM public.as_expect_error('T02 secondary fingerprints are hex64',
    $q$UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, secondary_fingerprints = '{abc}'$q$, '23514');
  PERFORM public.as_expect_error('T02 one policy row per tenant',
    $q$INSERT INTO assistant.tenant_policy (tenant_id, policy_version, source, document, signature, signer_kid, entitled, platform_enabled, kill_reason)
       VALUES ('80a00000-0000-7000-8000-000000000001', 9, 'dev_fixture', '{}', decode(repeat('ab', 64), 'hex'), 'dev-key', false, false, 'off')$q$, '23505');
  PERFORM public.as_expect_error('T02 policy cannot be deleted by the app', $q$DELETE FROM assistant.tenant_policy$q$, '42501');
  PERFORM public.as_expect_error('T02 policy identity immutable',
    $q$UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, id = uuidv7()$q$, 'HK_AST_POLICY_VERSION');
  UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, document = '{"v": 2}';
  PERFORM public.as_assert((SELECT policy_version = 2 AND row_version = 2 FROM assistant.tenant_policy), 'T02 policy v2 applied');
  PERFORM public.as_assert((SELECT document_sha256 = sha256(convert_to('{"v": 2}', 'UTF8')) FROM assistant.tenant_policy), 'T02 document hash generated');
  PERFORM set_config('app.actor_via', 'assistant', true);
  PERFORM public.as_expect_error('T02 assistant-originated tx cannot touch policy',
    $q$UPDATE assistant.tenant_policy SET policy_version = policy_version + 1$q$, 'HK_AST_VIA_ASSISTANT');
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

-- T04: دورهٔ مصرف
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_expect_error('T04 user scope needs a user',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, token_limit, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'user', current_date + 40, current_date + 60, 10, 'policy')$q$, '23514');
  PERFORM public.as_expect_error('T04 overlapping periods rejected',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, token_limit, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'tenant', current_date - 5, current_date + 25, 10, 'policy')$q$, '23P01');
  PERFORM public.as_expect_error('T04 limited period needs a limit',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'tenant', current_date + 40, current_date + 60, 'policy')$q$, '23514');
  PERFORM public.as_expect_error('T04 unlimited period has no limit',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, token_limit, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'tenant', current_date + 40, current_date + 60, 10, 'unlimited')$q$, '23514');
  PERFORM public.as_expect_error('T04 period at most 62 days',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, period_start, period_end, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'tenant', current_date + 40, current_date + 140, 'unlimited')$q$, '23514');
  PERFORM public.as_expect_error('T04 user of another tenant',
    $q$INSERT INTO assistant.usage_period (tenant_id, scope, user_id, period_start, period_end, limit_source)
       VALUES ('80a00000-0000-7000-8000-000000000001', 'user', '80b00000-0000-7000-8000-0000000000b1', current_date + 40, current_date + 60, 'unlimited')$q$,
    '23503');
  PERFORM public.as_expect_error('T04 period bounds not writable by the app (column grant)',
    format($q$UPDATE assistant.usage_period SET period_start = period_start - 1 WHERE id = %L$q$, public.k('uA')), '42501');
  PERFORM public.as_expect_error('T04 only limit columns are writable',
    format($q$UPDATE assistant.usage_period SET scope = 'user' WHERE id = %L$q$, public.k('uA')), '42501');
  PERFORM public.as_expect_error('T04 recent period cannot be deleted',
    format($q$DELETE FROM assistant.usage_period WHERE id = %L$q$, public.k('ua3')), 'HK_AST_RETENTION');
  UPDATE assistant.usage_period SET token_limit = 120000 WHERE id = public.k('uA');
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
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_assert((SELECT count(*) FROM assistant.thread) = 4, 'T05 system context sees every thread of the tenant');
END $T$;

-- T06: اجرا — سیاست، رضایت، ارائه‌دهنده، مصرف، هم‌زمانی
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
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
  -- کلید قطع مستأجر
  PERFORM public.as_ctx(public.k('A'), NULL);
  UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, platform_enabled = false, kill_reason = 'خاموشی اضطراری';
  PERFORM public.as_ctx(public.k('A'), public.k('a3'));
  PERFORM public.as_expect_error('T06 kill switch blocks new runs',
    format($q$SELECT public.as_new_run(NULL, %L)$q$, public.k('tA31')), 'HK_AST_DISABLED');
  PERFORM public.as_ctx(public.k('A'), NULL);
  UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, platform_enabled = true, kill_reason = NULL, features = '{chat,proposals}';
  PERFORM public.as_ctx(public.k('A'), public.k('a3'));
  PERFORM public.as_expect_error('T06 feature not in plan',
    format($q$SELECT public.as_new_run(NULL, %L, p_purpose => 'migration_mapping')$q$, public.k('tA31')), 'HK_AST_DISABLED');
  PERFORM public.as_ctx(public.k('A'), NULL);
  UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, entitled = false;
  PERFORM public.as_ctx(public.k('A'), public.k('a3'));
  PERFORM public.as_expect_error('T06 plan without assistant',
    format($q$SELECT public.as_new_run(NULL, %L)$q$, public.k('tA31')), 'HK_AST_DISABLED');
  PERFORM public.as_ctx(public.k('A'), NULL);
  UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, entitled = true, features = '{chat,proposals,migration_mapping}';
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
  PERFORM public.as_expect_error('T07 round number unique per run',
    format($q$SELECT public.as_new_call(NULL, %L, 1)$q$, public.k('rA1')), '23505');
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
  UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, platform_enabled = false, kill_reason = 'خاموشی سراسری';
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T07 kill switch stops the next round',
    format($q$SELECT public.as_new_call(NULL, %L, 2)$q$, public.k('rA1')), 'HK_AST_DISABLED');
  PERFORM public.as_ctx(public.k('A'), NULL);
  UPDATE assistant.tenant_policy SET policy_version = policy_version + 1, platform_enabled = true, kill_reason = NULL;
  -- خطای ارائه‌دهنده و لغو کاربر
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_expect_error('T07 failed needs an error code',
    format($q$UPDATE assistant.llm_call SET status = 'failed' WHERE id = %L$q$, public.k('cl21')), '23514');
  UPDATE assistant.llm_call SET status = 'failed', error_code = 'assistant.llm.timeout', finish_reason = 'timeout' WHERE id = public.k('cl21');
  PERFORM public.as_assert((SELECT charged_cost = 0 FROM assistant.llm_call WHERE id = public.k('cl21')), 'T07 failed call without usage costs nothing');
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
  UPDATE assistant.llm_call SET status = 'failed', error_code = 'assistant.llm.provider_error' WHERE id = public.k('cl12');
  PERFORM public.as_ctx(public.k('A'), public.k('a2'));
  PERFORM public.as_assert((SELECT count(*) FROM assistant.tool_call) = 0, 'T08 tool calls visible to their owner only');
END $T$;

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
  INSERT INTO assistant.message (tenant_id, id, thread_id, user_id, run_id, seq, role, content, finish, blocks, grounding)
  VALUES (public.k('A'), public.k('m2'), public.k('tA1'), public.k('a1'), public.k('rA1'), 1, 'assistant',
          'تراز آزمایشی آماده است. جمع بدهکار ۱٬۲۰۰٬۰۰۰ ریال است.', 'complete',
          jsonb_build_array(jsonb_build_object('type', 'table', 'tool_call_id', public.k('tc1'))), '{"checked": 1, "ungrounded": []}');
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
  PERFORM public.as_expect_error('T12 URL without credentials or query',
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, display_name, operator, data_location, base_url, model, auth_header, created_by)
              VALUES (%L, 'x', 'Evil', 'other', 'https://user:pass@evil.example/v1?x=1', 'm', 'none', %L)$q$, public.k('A'), public.k('a1')), '23514');
  INSERT INTO assistant.tenant_provider (tenant_id, id, display_name, operator, data_location, base_url, model, auth_header, allow_private_network, created_by)
  VALUES (public.k('A'), public.k('tp1'), 'سرور محلی', '  Our LAN vLLM ', 'lan', 'http://10.0.0.5:8000/v1', 'qwen2.5-7b', 'none', true, public.k('a1'));
  PERFORM public.as_assert((SELECT fingerprint = public.fp('L') FROM assistant.tenant_provider WHERE id = public.k('tp1')), 'T12 fingerprint generated');
  PERFORM public.as_expect_error('T12 activation needs a successful probe',
    format($q$UPDATE assistant.tenant_provider SET status = 'active' WHERE id = %L$q$, public.k('tp1')), '23514');
  UPDATE assistant.tenant_provider SET last_probe_ok = true, last_probe_at = now(), last_probe_report = '{"tools": true, "stream_usage": false}' WHERE id = public.k('tp1');
  UPDATE assistant.tenant_provider SET status = 'active' WHERE id = public.k('tp1');
  PERFORM public.as_assert((SELECT updated_by = public.k('a1') FROM assistant.tenant_provider WHERE id = public.k('tp1')), 'T12 updated_by from context');
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
    format($q$INSERT INTO assistant.tenant_provider (tenant_id, id, display_name, operator, data_location, base_url, model, auth_header, allow_private_network,
                                                   status, last_probe_ok, last_probe_at, created_by)
              VALUES (%L, %L, 'سرور ب', 'B LAN', 'lan', 'http://10.1.0.5:8000/v1', 'm', 'none', true, 'active', true, now(), %L)$q$,
           public.k('B'), public.k('tpB'), public.k('b1')), 'HK_AST_PROVIDER');
END $T$;

-- T13: لغو رضایت وسط اجرا
DO $T$
BEGIN
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_new_call(public.k('cl31'), public.k('rA3'), 1, 1000, 500);
  PERFORM public.as_finish_call(public.k('cl31'), 900, 100, 'tool_calls');
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
                       AND (SELECT count(*) FROM assistant.tool_call WHERE thread_id = public.k('tA1')) = 7
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
  PERFORM public.as_assert((SELECT count(*) FROM assistant.message WHERE thread_id = public.k('tA1')) = 0
                       AND (SELECT count(*) FROM assistant.tool_call WHERE thread_id = public.k('tA1')) = 0
                       AND (SELECT count(*) FROM assistant.proposal WHERE thread_id = public.k('tA1')) = 0
                       AND (SELECT count(*) FROM assistant.feedback) = 0, 'T14 all content cascaded');
  PERFORM public.as_assert((SELECT thread_id IS NULL AND status = 'completed' FROM assistant.run WHERE id = public.k('rA1')), 'T14 run kept, detached');
  PERFORM public.as_assert((SELECT llm_calls = 3 AND prompt_tokens = 2300 FROM assistant.v_run_usage WHERE run_id = public.k('rA1')), 'T14 metering kept');
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
    format($q$UPDATE assistant.consent SET status = 'revoked', ended_by = %L, end_reason = 'xyz' WHERE id = %L$q$, public.k('a1'), public.k('cA4'))]
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
  UPDATE assistant.tenant_policy SET policy_version = policy_version + 100 WHERE tenant_id = public.k('A');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.as_assert(n = 0, 'T16 cannot update another tenant policy');
  PERFORM public.as_new_run(public.k('rB1'), public.k('tB1'));
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
END $T$;

-- T19: ردیف‌های ساختگی (بدون تریگر) برای انقضا، رهاسازی و پاک‌سازی
SET session_replication_role = replica;
INSERT INTO assistant.thread (tenant_id, id, user_id, company_id, title, created_at, last_activity_at) VALUES
  (public.k('A'), public.k('tOld'), public.k('a1'), public.k('A.C1'), 'گفت‌وگوی قدیمی', now() - interval '200 days', now() - interval '199 days'),
  (public.k('A'), public.k('tExp'), public.k('a1'), public.k('A.C1'), 'پیشنهاد منقضی', now() - interval '8 days', now() - interval '8 days');
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
   now() - interval '401 days', now() - interval '401 days' + interval '5 minutes', now() - interval '401 days' + interval '1 minute', 'assistant.run.lease_expired');
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
SET session_replication_role = origin;

CREATE OR REPLACE FUNCTION public.as_hold_then_purge() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO core.legal_hold (tenant_id, scope, reason, placed_by) VALUES (core.current_tenant_id(), 'tenant', 'دعوای حقوقی آزمایشی', public.k('a1'));
  PERFORM assistant.purge_threads(now() - interval '100 days');
END $$;

SET ROLE hk_app;
DO $T$
DECLARE n integer;
BEGIN
  PERFORM public.as_ctx(public.k('A'), NULL);
  n := assistant.reap_expired();
  PERFORM public.as_assert(n = 2, 'T19 reaper handles one call and one run (got ' || n || ')');
  PERFORM public.as_assert((SELECT status = 'abandoned' AND usage_estimated AND prompt_tokens = 700 AND completion_tokens = 300
                                   AND error_code = 'assistant.llm.lease_expired' AND charged_cost = 38
                              FROM assistant.llm_call WHERE id = public.k('clOld')), 'T19 abandoned call charges its full reservation');
  PERFORM public.as_assert((SELECT status = 'failed' AND error_code = 'assistant.run.lease_expired' FROM assistant.run WHERE id = public.k('rOld')),
                           'T19 expired run failed');
  PERFORM public.as_ctx(NULL, NULL);
  PERFORM public.as_expect_error('T19 reaper needs a tenant', $q$SELECT assistant.reap_expired()$q$, 'HK_AST_CONTEXT');
  PERFORM public.as_ctx(public.k('A'), public.k('a1'));
  PERFORM public.as_expect_error('T19 purge only in system context', $q$SELECT assistant.purge_threads(now() - interval '100 days')$q$, 'HK_AST_SYSTEM_ONLY');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_expect_error('T19 retention at least one day', $q$SELECT assistant.purge_threads(now())$q$, 'HK_AST_RETENTION');
  PERFORM public.as_expect_error('T19 legal hold blocks purge', $q$SELECT public.as_hold_then_purge()$q$, 'HK_AST_LEGAL_HOLD');
  PERFORM public.as_assert((SELECT count(*) FROM core.legal_hold) = 0, 'T19 hold rolled back with the failed purge');
  n := assistant.purge_threads(now() - interval '100 days');
  PERFORM public.as_assert(n = 1, 'T19 purge deletes only threads older than the cutoff');
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM assistant.thread WHERE id = public.k('tOld'))
                           AND (SELECT thread_id IS NULL FROM assistant.run WHERE id = public.k('rOld')), 'T19 purged thread, run detached');
  -- انقضای پیشنهاد
  PERFORM public.as_ctx(public.k('A'), public.k('a1'), 'assistant_confirm');
  PERFORM public.as_expect_error('T19 expired proposal cannot be materialized',
    format($q$UPDATE assistant.proposal SET status = 'materialized', decided_by = %L, target_type = 'ledger.journal_draft', target_id = uuidv7() WHERE id = %L$q$,
           public.k('a1'), public.k('prExp')), 'HK_AST_PROPOSAL_EXPIRED');
  PERFORM public.as_ctx(public.k('A'), NULL);
  PERFORM public.as_expect_error('T19 expiry has no actor',
    format($q$UPDATE assistant.proposal SET status = 'expired', decided_by = %L WHERE id = %L$q$, public.k('a1'), public.k('prExp')), 'HK_AST_PROPOSAL_STATE');
  UPDATE assistant.proposal SET status = 'expired' WHERE id = public.k('prExp');
  PERFORM public.as_assert((SELECT status = 'expired' AND decided_at IS NOT NULL AND decided_by IS NULL FROM assistant.proposal WHERE id = public.k('prExp')),
                           'T19 system context expires the proposal');
  -- نگهداری سنجش
  DELETE FROM assistant.run WHERE id = public.k('rAnc');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.as_assert(n = 1, 'T19 metering older than 400 days can be purged');
  PERFORM public.as_expect_error('T19 recent run is kept', format($q$DELETE FROM assistant.run WHERE id = %L$q$, public.k('rA1')), 'HK_AST_RETENTION');
  PERFORM public.as_expect_error('T19 recent call is kept', format($q$DELETE FROM assistant.llm_call WHERE id = %L$q$, public.k('cl11')), 'HK_AST_RETENTION');
END $T$;
RESET ROLE;

-- T20: lint امنیتی هسته روی اسکیمای assistant، lint کاتالوگ، grantها
DO $T$
DECLARE v_def text; v_bad text;
BEGIN
  v_def := pg_get_functiondef('core.security_lint()'::regprocedure);
  PERFORM public.as_assert(position($s$'migration','reports']$s$ IN v_def) > 0, 'T20 security_lint source has the schema list');
  v_def := replace(v_def, 'FUNCTION core.security_lint()', 'FUNCTION public.as_security_lint()');
  v_def := replace(v_def, $s$'migration','reports']$s$, $s$'migration','reports','assistant']$s$);
  EXECUTE v_def;
  SELECT string_agg(object || ' ' || problem, '; ') INTO v_bad FROM public.as_security_lint() WHERE object LIKE 'assistant.%';
  PERFORM public.as_assert(v_bad IS NULL, 'T20 core security lint clean for assistant: ' || coalesce(v_bad, ''));
  PERFORM public.as_assert((SELECT count(*) FROM core.export_table_registry WHERE schema_name = 'assistant') = 11, 'T20 every assistant table is in the export registry');
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
                           AND (SELECT count(*) FROM core.setting_def WHERE module = 'assistant') = 6
                           AND (SELECT count(*) FROM core.retention_class WHERE code LIKE 'assistant_%') = 2, 'T20 core catalogs registered');
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM core.role_template_permission WHERE permission_code IN ('assistant.consent.manage','assistant.provider.manage')),
                           'T20 consent and provider management stay with the owner role');
  PERFORM public.as_assert(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'assistant' AND p.prosecdef),
                           'T20 no SECURITY DEFINER in assistant');
  PERFORM public.as_expect_error('T20 messages immutable even for the owner',
    $q$UPDATE assistant.message SET input_mode = 'text'$q$, 'HK_IMMUTABLE');
  PERFORM public.as_expect_error('T20 tool calls immutable even for the owner',
    $q$UPDATE assistant.tool_call SET latency_ms = 1$q$, 'HK_IMMUTABLE');
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
SELECT public.as_assert(count(*) = 3 AND bool_and(assistant.provider_fingerprint(v->>'operator', v->>'base_url', v->>'data_location') = v->>'expected'),
                        'T22 provider fingerprint vectors (SQL == Python)')
  FROM jsonb_array_elements((:'fp_vectors')::jsonb -> 'vectors') v;

\echo 'ALL 80_assistant TESTS PASSED'
