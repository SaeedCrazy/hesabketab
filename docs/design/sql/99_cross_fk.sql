-- =====================================================================
-- حساب‌کتاب — 99_cross_fk.sql   (مالک: یکپارچه‌ساز)
-- کلیدهای خارجی بین‌ماژولی + سیم‌کشی‌های بین‌ماژولی که فقط روی پایگاه یکپارچه معنا دارند.
--
-- ترتیب: همیشه آخرین فایل صفحهٔ داده و پیش از هر داده (run_all.sh؛ C-L18):
--   00 → 10 → 20 → 25 → 30 → 40 → 50 → 60 → 80 → 99   (یا 00 → 10 → 25 → 20 → …)
-- هرگز روی پایگاه کنترل (70_platform) اجرا نمی‌شود: هیچ FK بین دو پایگاه داده نیست (۰۹ §۱۲).
--
-- قواعد (docs/design/change-requests.md، «قواعد یکپارچه‌سازی»):
--   R-XFK-1  هر FK بین دو جدول مستأجری ترکیبی است و tenant_id اولین ستون است. اگر هر دو سو company_id
--            دارند و مقصد UNIQUE (tenant_id, company_id, id) دارد، FK سه‌ستونیِ «همان شرکت» است.
--   R-XFK-2  FK به جدول سراسری (ref.*، rules.tax_category) تک‌ستونی است.
--   R-XFK-3  نام: fk_<from_table>__<to_schema>_<to_table>[_<نقش ستون>] (۰۱ §۱۲ بند ۴). اگر نام سند
--            مبدأ فرق دارد، در توضیح همان سطر آمده و سند باید نام این فایل را بپذیرد.
--   R-XFK-4  idempotent: اگر قیدی با همین نام هست باید هم‌تعریف باشد (وگرنه HK_XFK_NAME_CLASH)؛ اگر FK
--            هم‌ارز (همان ستون‌ها و همان مقصد) با نام دیگری در فایل ماژول هست، این‌جا چیزی افزوده نمی‌شود.
--   R-XFK-5  هر FK بین‌اسکیمایی که جفت (مبدأ، مقصد) آن در depends_on جدول ۰۱ §۵-۱ (core.module_registry() در
--            00_foundation) نیست — خلاف جهت، هم‌لایه یا رو به پایینِ اعلام‌نشده — فقط با برچسب HK_DAG_EXCEPTION
--            (COMMENT ON CONSTRAINT) مجاز است؛ core.xfk_dag_violations() همین را از کاتالوگ می‌خواند (خودآزمایی بخش ۸ و
--            lint آزمون test_cross_schema_fks_follow_dag). مقایسهٔ شمارهٔ لایه کافی نیست (RV-ARCH-08). کد ماژول
--            پایین‌دست هرگز ماژول بالادست را import نمی‌کند؛ شناسه را از payload فرمان/رویداد می‌گیرد.
--   R-XFK-6  FKهایی که مقصدشان در فایل‌های پیش‌نیاز همان ماژول است جایشان در فایل خود ماژول است (R-ORDER).
--            FKهای بخش ۰۳ و ۰۴ به core فعلاً این‌جا هستند تا آن دو بخش 10_core را پیش‌نیاز کنند و آن‌ها را
--            به فایل خود ببرند؛ پس از انتقال، بند R-XFK-4 آن‌ها را بی‌اثر می‌کند.
-- =====================================================================
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

-- ---------- پیش‌شرط: همهٔ فایل‌های صفحهٔ داده اعمال شده‌اند ----------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['core.tenant_membership','ledger.journal','parties.party','catalog.item',
                           'inventory.warehouse','sales.invoice','treasury.money_document','pos.ticket',
                           'tax.invoice','payroll.workshop','assets.disposal','rules.tax_category',
                           'migration.job','assistant.purpose'] LOOP
    IF to_regclass(t) IS NULL THEN
      RAISE EXCEPTION 'HK_PREREQ: 99_cross_fk.sql needs every data-plane file applied first (missing %)', t;
    END IF;
  END LOOP;
  IF EXISTS (SELECT FROM pg_namespace WHERE nspname = 'platform') THEN
    RAISE EXCEPTION 'HK_WRONG_DATABASE: 99_cross_fk.sql must not be applied to the control-plane database';
  END IF;
  IF to_regprocedure('core.xfk_dag_violations()') IS NULL THEN
    RAISE EXCEPTION 'HK_PREREQ: 99_cross_fk.sql needs core.xfk_dag_violations() from the current 00_foundation.sql';
  END IF;
END $$;

-- ---------- کمک‌تابع موقت (فقط همین نشست؛ چیزی در پایگاه نمی‌ماند) ----------
CREATE OR REPLACE FUNCTION pg_temp.hk_add_fk(p_name text, p_from regclass, p_cols text[],
                                             p_to regclass, p_refcols text[], p_dag_exception text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_conkey  int2[];
  v_confkey int2[];
  v_con     record;
  v_name    text;
  v_status  text;
BEGIN
  SELECT array_agg(a.attnum ORDER BY u.ord) INTO v_conkey
    FROM unnest(p_cols) WITH ORDINALITY AS u(col, ord)
    JOIN pg_attribute a ON a.attrelid = p_from AND a.attname = u.col AND NOT a.attisdropped;
  SELECT array_agg(a.attnum ORDER BY u.ord) INTO v_confkey
    FROM unnest(p_refcols) WITH ORDINALITY AS u(col, ord)
    JOIN pg_attribute a ON a.attrelid = p_to AND a.attname = u.col AND NOT a.attisdropped;
  IF coalesce(cardinality(v_conkey), 0) <> cardinality(p_cols) THEN
    RAISE EXCEPTION 'HK_XFK_COLUMN: %(%) does not exist', p_from, array_to_string(p_cols, ',');
  END IF;
  IF coalesce(cardinality(v_confkey), 0) <> cardinality(p_refcols) THEN
    RAISE EXCEPTION 'HK_XFK_COLUMN: %(%) does not exist', p_to, array_to_string(p_refcols, ',');
  END IF;

  SELECT c.oid, c.contype, c.confrelid, c.conkey, c.confkey INTO v_con
    FROM pg_constraint c WHERE c.conrelid = p_from AND c.conname = p_name;
  IF FOUND THEN
    IF v_con.contype <> 'f' OR v_con.confrelid <> p_to OR v_con.conkey <> v_conkey OR v_con.confkey <> v_confkey THEN
      RAISE EXCEPTION 'HK_XFK_NAME_CLASH: % on % already exists with another definition: %',
        p_name, p_from, pg_get_constraintdef(v_con.oid);
    END IF;
    v_name := p_name; v_status := 'exists';
  ELSE
    SELECT c.conname INTO v_name FROM pg_constraint c
     WHERE c.contype = 'f' AND c.conrelid = p_from AND c.confrelid = p_to
       AND c.conkey = v_conkey AND c.confkey = v_confkey
     ORDER BY c.conname LIMIT 1;
    IF FOUND THEN
      v_status := 'equivalent:' || v_name;
    ELSE
      EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%s) REFERENCES %s (%s)',
                     p_from, p_name,
                     (SELECT string_agg(quote_ident(x), ', ') FROM unnest(p_cols) x),
                     p_to,
                     (SELECT string_agg(quote_ident(x), ', ') FROM unnest(p_refcols) x));
      v_name := p_name; v_status := 'added';
    END IF;
  END IF;

  IF p_dag_exception IS NOT NULL THEN
    EXECUTE format('COMMENT ON CONSTRAINT %I ON %s IS %L', v_name, p_from, 'HK_DAG_EXCEPTION: ' || p_dag_exception);
  END IF;
  RETURN v_status;
END $$;

-- =====================================================================
-- ۱. core → ماژول‌های بالاتر (دامنهٔ رکوردِ انتساب نقش) — خلاف DAG، مجاز با برچسب (R-XFK-5)
--    مبدأ: 02-core-platform.md:1520-1536 (§۱۲)؛ هم‌چنین 05-commerce.md:1382-1383 و 06-treasury-pos.md:2224-2228.
--    نام سند ۰۲: role_assignment_scope_<x>_fk ← نام این فایل طبق R-XFK-3.
--    ستون company_id این جدول برای ابعاد غیرشرکت NULL است، پس FK دوستونی است (CHECK num_nonnulls = 1).
-- =====================================================================
SELECT fk, pg_temp.hk_add_fk(fk, src::regclass, cols, dst::regclass, refcols, dag) AS status FROM (VALUES
  -- 02-core-platform.md:1524-1526 ؛ 05-commerce.md:1382-1383
  ('fk_role_assignment_scope__inventory_warehouse', 'core.role_assignment_scope', '{tenant_id,warehouse_id}'::text[],
   'inventory.warehouse', '{tenant_id,id}'::text[],
   'L0 core -> L4 inventory; record-scope integrity; core code never imports inventory (CR-C07)'),
  -- 02-core-platform.md:1527-1529 ؛ 06-treasury-pos.md:2225-2226
  ('fk_role_assignment_scope__treasury_cash_box', 'core.role_assignment_scope', '{tenant_id,cash_box_id}',
   'treasury.cash_box', '{tenant_id,id}',
   'L0 core -> L4 treasury; record-scope integrity'),
  -- 02-core-platform.md:1530-1532 ؛ 06-treasury-pos.md:2227-2228
  ('fk_role_assignment_scope__pos_terminal', 'core.role_assignment_scope', '{tenant_id,pos_terminal_id}',
   'pos.terminal', '{tenant_id,id}',
   'L0 core -> L6 pos; record-scope integrity'),
  -- 02-core-platform.md:1533-1535
  ('fk_role_assignment_scope__ledger_dimension_value', 'core.role_assignment_scope', '{tenant_id,cost_center_id}',
   'ledger.dimension_value', '{tenant_id,id}',
   'L0 core -> L3 ledger; record-scope integrity')
) AS v(fk, src, cols, dst, refcols, dag);

-- =====================================================================
-- ۲. ledger → core و parties (هم‌جهت DAG). مبدأ: 03-ledger.md:1383-1432 (§۱۲؛ ۲۱ دستور، نام‌ها بی‌تغییر)
--    پس از آن‌که 10_core پیش‌نیاز 20_ledger شود (R-ORDER) جای این‌ها در 20_ledger.sql است (R-XFK-6).
-- =====================================================================
SELECT fk, pg_temp.hk_add_fk(fk, src::regclass, cols, dst::regclass, refcols) AS status FROM (VALUES
  ('fk_journal__core_number_issued',             'ledger.journal',             '{tenant_id,number_issued_id}'::text[],    'core.number_issued',     '{tenant_id,id}'::text[]),      -- 03-ledger.md:1385
  ('fk_journal__core_approval_request',          'ledger.journal',             '{tenant_id,approval_request_id}',         'core.approval_request',  '{tenant_id,id}'),              -- 03-ledger.md:1387
  ('fk_journal_draft__core_approval_request',    'ledger.journal_draft',       '{tenant_id,approval_request_id}',         'core.approval_request',  '{tenant_id,id}'),              -- 03-ledger.md:1389
  ('fk_fiscal_period__core_approval_request',    'ledger.fiscal_period',       '{tenant_id,status_approval_ref}',         'core.approval_request',  '{tenant_id,id}'),              -- 03-ledger.md:1391
  ('fk_period_status_event__core_approval_request', 'ledger.period_status_event', '{tenant_id,approval_ref}',          'core.approval_request',  '{tenant_id,id}'),              -- 03-ledger.md:1393
  ('fk_eledger_export__core_attachment',         'ledger.eledger_export',      '{tenant_id,file_attachment_id}',          'core.attachment',        '{tenant_id,id}'),              -- 03-ledger.md:1395
  -- ستون‌های کنشگر → عضویت (C-L08 / R-ACTOR). کنشگر سیستمی = NULL.
  ('fk_journal__core_tenant_membership_posted',     'ledger.journal',         '{tenant_id,posted_by}',          'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1399
  ('fk_journal__core_tenant_membership_reviewed',   'ledger.journal',         '{tenant_id,reviewed_by}',        'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1401
  ('fk_journal__core_tenant_membership_finalized',  'ledger.journal',         '{tenant_id,finalized_by}',       'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1403
  ('fk_journal_draft__core_tenant_membership',      'ledger.journal_draft',   '{tenant_id,created_by}',         'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1405
  ('fk_fiscal_year__core_tenant_membership_closed', 'ledger.fiscal_year',     '{tenant_id,closed_by}',          'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1407
  ('fk_fiscal_year__core_tenant_membership_locked', 'ledger.fiscal_year',     '{tenant_id,locked_by}',          'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1409
  ('fk_fiscal_period__core_tenant_membership_status','ledger.fiscal_period',  '{tenant_id,status_changed_by}',  'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1411
  ('fk_period_status_event__core_tenant_membership','ledger.period_status_event','{tenant_id,actor_user_id}',   'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1413
  ('fk_period_module_lock__core_tenant_membership', 'ledger.period_module_lock','{tenant_id,locked_by}',        'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1415
  ('fk_exchange_rate__core_tenant_membership',      'ledger.exchange_rate',   '{tenant_id,entered_by}',         'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1417
  ('fk_recurring_journal__core_tenant_membership',  'ledger.recurring_journal','{tenant_id,created_by}',        'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1419
  ('fk_year_close_run__core_tenant_membership',     'ledger.year_close_run',  '{tenant_id,started_by}',         'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1421
  ('fk_fx_revaluation_run__core_tenant_membership', 'ledger.fx_revaluation_run','{tenant_id,created_by}',       'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1423
  ('fk_eledger_export__core_tenant_membership',     'ledger.eledger_export',  '{tenant_id,generated_by}',       'core.tenant_membership', '{tenant_id,user_id}'),   -- 03-ledger.md:1425
  -- ledger (L3) → parties (L2)؛ 03-ledger.md:1430 و 04-masterdata.md:1808
  ('fk_dimension_value__parties_party',             'ledger.dimension_value', '{tenant_id,party_id}',           'parties.party',          '{tenant_id,id}')
) AS v(fk, src, cols, dst, refcols);

-- =====================================================================
-- ۳. parties / catalog → core و rules (هم‌جهت DAG). مبدأ: 04-masterdata.md:1758-1790 (§۱۲) و
--    07-compliance.md:1422-1428 (پاسخ CR-08). نام‌های سند ۰۴ (fk_party__created_by، …) ← R-XFK-3.
-- =====================================================================
SELECT fk, pg_temp.hk_add_fk(fk, src::regclass, cols, dst::regclass, refcols) AS status FROM (VALUES
  ('fk_party__core_tenant_membership_created_by',          'parties.party',          '{tenant_id,created_by}'::text[],         'core.tenant_membership', '{tenant_id,user_id}'::text[]),  -- 04-masterdata.md:1760 (fk_party__created_by)
  ('fk_party__core_tenant_membership_national_id_override','parties.party',          '{tenant_id,national_id_override_by}',    'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1762
  ('fk_party_hold__core_tenant_membership_placed_by',      'parties.party_hold',     '{tenant_id,placed_by}',                  'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1764
  ('fk_party_hold__core_tenant_membership_released_by',    'parties.party_hold',     '{tenant_id,released_by}',                'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1766
  ('fk_party_merge__core_tenant_membership',               'parties.party_merge',    '{tenant_id,merged_by}',                  'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1768
  ('fk_duplicate_dismissal__core_tenant_membership',       'parties.duplicate_dismissal', '{tenant_id,dismissed_by}',          'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1770
  ('fk_party_taxpayer_inquiry__core_tenant_membership',    'parties.party_taxpayer_inquiry', '{tenant_id,inquired_by}',        'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1772
  ('fk_item__core_tenant_membership',                      'catalog.item',           '{tenant_id,created_by}',                 'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1774
  ('fk_barcode__core_tenant_membership',                   'catalog.barcode',        '{tenant_id,created_by}',                 'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1776
  ('fk_price_list__core_tenant_membership',                'catalog.price_list',     '{tenant_id,created_by}',                 'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1778
  ('fk_price_list_item__core_tenant_membership',           'catalog.price_list_item','{tenant_id,created_by}',                 'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1780
  ('fk_bom__core_tenant_membership_created_by',            'catalog.bom',            '{tenant_id,created_by}',                 'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1782
  ('fk_bom__core_tenant_membership_activated_by',          'catalog.bom',            '{tenant_id,activated_by}',               'core.tenant_membership', '{tenant_id,user_id}'),  -- 04-masterdata.md:1784
  ('fk_item_image__core_attachment',                       'catalog.item_image',     '{tenant_id,attachment_id}',              'core.attachment',        '{tenant_id,id}'),       -- 04-masterdata.md:1788
  -- catalog (L2) → rules (L1)، جدول سراسری ⇒ تک‌ستونی (R-XFK-2)
  ('fk_item__rules_tax_category',                          'catalog.item',           '{tax_category_code}',                    'rules.tax_category',     '{code}'),               -- 07-compliance.md:1423 ؛ 04-masterdata.md:1803
  ('fk_item__rules_tax_category_other',                    'catalog.item',           '{other_tax_category_code}',              'rules.tax_category',     '{code}'),               -- 07-compliance.md:1425
  ('fk_item_category__rules_tax_category',                 'catalog.item_category',  '{default_tax_category_code}',            'rules.tax_category',     '{code}')                -- 07-compliance.md:1427
) AS v(fk, src, cols, dst, refcols);

-- =====================================================================
-- ۴. sales ↔ tax ، pos → inventory/sales/tax (R-XFK-1: سه‌ستونی هم‌شرکت)
--    05-commerce.md:1375-1376 و 07-compliance.md:1413-1414 هر دو FK دوستونی sales.invoice → tax.invoice نوشته‌اند؛
--    این فایل نسخهٔ سه‌ستونی را می‌گذارد (tax.invoice UNIQUE (tenant_id, company_id, id) دارد).
--    06-treasury-pos.md:2216-2222 دوستونی و 07-compliance.md:1415-1421 سه‌ستونی ⇒ سه‌ستونی (CR-T16 / CR-CMP-05).
--    TODO(RV-IT-SALESTAX): هم‌خوانی دوطرفهٔ sales.invoice.tax_document_id و tax.invoice.sales_invoice_id با FK
--    تضمین نمی‌شود (UNIQUE (tenant_id, company_id, id, sales_invoice_id) روی tax.invoice نیست).
-- =====================================================================
SELECT fk, pg_temp.hk_add_fk(fk, src::regclass, cols, dst::regclass, refcols, dag) AS status FROM (VALUES
  -- sales (L5) → tax (L4)، هم‌جهت DAG؛ 05-commerce.md:1376 (fk_invoice__tax_invoice)
  ('fk_invoice__tax_invoice',      'sales.invoice', '{tenant_id,company_id,tax_document_id}'::text[], 'tax.invoice', '{tenant_id,company_id,id}'::text[], NULL::text),
  -- pos (L6) → inventory (L4)؛ 06-treasury-pos.md:2211-2212 (terminal_warehouse_fk) ؛ 05-commerce.md:1384-1385 (دوستونی، کنار گذاشته شد)
  ('fk_terminal__inventory_warehouse', 'pos.terminal', '{tenant_id,company_id,warehouse_id}', 'inventory.warehouse', '{tenant_id,company_id,id}', NULL),
  -- pos (L6) → sales (L5)؛ 06-treasury-pos.md:2213-2214 (ticket_sales_doc_fk) ؛ 05-commerce.md:1386-1387
  ('fk_ticket__sales_invoice',     'pos.ticket',   '{tenant_id,company_id,sales_doc_id}',   'sales.invoice', '{tenant_id,company_id,id}', NULL),
  -- pos (L6) → tax (L4)؛ 06-treasury-pos.md:2217-2222 ؛ 07-compliance.md:1416-1421
  ('fk_terminal__tax_memory',      'pos.terminal', '{tenant_id,company_id,tax_memory_ref}', 'tax.memory',    '{tenant_id,company_id,id}', NULL),
  ('fk_ticket__tax_memory',        'pos.ticket',   '{tenant_id,company_id,tax_memory_ref}', 'tax.memory',    '{tenant_id,company_id,id}', NULL),
  ('fk_ticket__tax_invoice',       'pos.ticket',   '{tenant_id,company_id,tax_doc_id}',     'tax.invoice',   '{tenant_id,company_id,id}', NULL),
  -- tax (L4) → sales (L5): خلاف DAG؛ 07-compliance.md:1389-1392 (fk_tax_invoice__sales_invoice، fk_tax_issue_line__sales_invoice_line)
  ('fk_invoice__sales_invoice',    'tax.invoice',  '{tenant_id,company_id,sales_invoice_id}', 'sales.invoice', '{tenant_id,company_id,id}',
   'L4 tax -> L5 sales; tax stores the id from SalesTaxSnapshot and never reads sales (07 D-CMP push model)'),
  ('fk_invoice_issue_line__sales_invoice_line', 'tax.invoice_issue_line', '{tenant_id,source_line_id}', 'sales.invoice_line', '{tenant_id,id}',
   'L4 tax -> L5 sales; id from SalesTaxSnapshot; NULL for migration-sourced issues'),
  -- assets (L4) → sales (L5): خلاف DAG؛ 07-compliance.md:1394-1396 (fk_asset_disposal__sales_invoice)
  ('fk_disposal__sales_invoice',   'assets.disposal', '{tenant_id,company_id,sales_invoice_id}', 'sales.invoice', '{tenant_id,company_id,id}',
   'L4 assets -> L5 sales; id passed by sales when an asset is sold')
) AS v(fk, src, cols, dst, refcols, dag);

-- =====================================================================
-- ۵. payroll → treasury (هم‌جهت DAG) و rules → payroll (خلاف DAG). مبدأ: 07-compliance.md:1398-1406
-- =====================================================================
SELECT fk, pg_temp.hk_add_fk(fk, src::regclass, cols, dst::regclass, refcols, dag) AS status FROM (VALUES
  ('fk_payslip__treasury_money_document', 'payroll.payslip', '{tenant_id,company_id,payment_doc_ref}'::text[],  'treasury.money_document', '{tenant_id,company_id,id}'::text[], NULL::text),  -- 07-compliance.md:1399
  ('fk_loan__treasury_money_document',    'payroll.loan',    '{tenant_id,company_id,disbursement_ref}', 'treasury.money_document', '{tenant_id,company_id,id}', NULL),         -- 07-compliance.md:1401
  ('fk_param_override__payroll_workshop', 'rules.param_override', '{tenant_id,company_id,workshop_ref}', 'payroll.workshop', '{tenant_id,company_id,id}',                    -- 07-compliance.md:1405
   'L1 rules -> L5 payroll; workshop-level parameter override; rules code never imports payroll (CR-CMP-08)')
) AS v(fk, src, cols, dst, refcols, dag);

-- =====================================================================
-- ۵-ب. pos → ledger (رو به پایین ولی بیرون از pos.depends_on؛ 01 §۵-۱ و 06 INV-POS-14) — استثنای برچسب‌دار (RV-ARCH-08)
--    pos.cash_movement.posting_key کد کاتالوگ سراسری ledger.posting_key است (بدون tenant_id ⇒ تک‌ستونی، R-XFK-2).
--    40_treasury_pos.sql آن را درون‌خطی با نام خودکار cash_movement_posting_key_fkey می‌سازد؛ hk_add_fk آن را «هم‌ارز»
--    می‌شناسد و همان را برچسب می‌زند. اگر 40 قید را با نام R-XFK-3 بسازد یا بردارد، این سطر همان را برچسب می‌زند یا
--    می‌سازد. کد pos هرگز ledger را import نمی‌کند: کد را از فهرست دلیل‌های ورود/خروج نقد treasury می‌گیرد و
--    treasury سند را ثبت می‌کند. FK فقط وجود کد را تضمین می‌کند.
-- =====================================================================
SELECT fk, pg_temp.hk_add_fk(fk, src::regclass, cols, dst::regclass, refcols, dag) AS status FROM (VALUES
  ('fk_cash_movement__ledger_posting_key', 'pos.cash_movement', '{posting_key}'::text[], 'ledger.posting_key', '{key}'::text[],
   'L6 pos -> L3 ledger, not in pos.depends_on; FK to the global code catalog ledger.posting_key only; pos never imports ledger (06 INV-POS-14); treasury posts the pay-in/out (RV-ARCH-08)')
) AS v(fk, src, cols, dst, refcols, dag);

-- ---------- عمداً بیرون از این فایل ----------
-- * migration.posting.{stock_doc_id, cheque_id, open_item_id} (08-migration.md:1940-1952): پیشنهادی و
--   «فقط اگر ستون‌ها افزوده شوند». این فایل ستون نمی‌سازد؛ تصمیم CR-MG-OPT در change-requests.md (رد).
-- * ارجاع‌های نرم مستند (چندریختی یا خلاف DAG بدون نیاز به یکپارچگی): ledger.journal.source_doc_id،
--   treasury.open_item.source_*، inventory.stock_move.source_*، sales.gl_batch.source_ref، *_legacy_code.migration_run_id،
--   assistant.proposal.target_*، tax.purchase_entry.source_*، rules.recalc_proposal.target_id (§۱۲ هر بخش).
-- * هیچ FK به پایگاه کنترل (platform.*) — 09-owner-platform.md:2581.

-- =====================================================================
-- ۶. ثبت موجودیت‌های دارای فیلد سفارشی (داده، نه FK) — 04-masterdata.md:1791-1795
--    و اتصال اعتبارسنجی و نمایه (02-core-platform.md:1544 «custom jsonb + core.attach_custom_fields»).
--    TODO(RV-IT-CUSTOM): پس از R-ORDER جای این دو در 25_masterdata.sql است.
-- =====================================================================
INSERT INTO core.custom_field_entity (entity_type, module, table_name, json_column, max_fields, description_key) VALUES
  ('parties.party', 'parties', 'parties.party', 'custom', 50, 'custom_field.entity.parties.party'),
  ('catalog.item',  'catalog', 'catalog.item',  'custom', 50, 'custom_field.entity.catalog.item')
ON CONFLICT (entity_type) DO NOTHING;
SELECT core.attach_custom_fields('parties.party', 'parties.party');
SELECT core.attach_custom_fields('catalog.item',  'catalog.item');

-- =====================================================================
-- ۷. نگهبان TRUNCATE روی هر جدول فقط‌افزودنی (۰۲ §۱۳ بند ۸؛ R-APPEND)
--    هر جدولی که تریگر سطری core.forbid_mutation برای UPDATE یا DELETE دارد، تریگر سطح دستور
--    BEFORE TRUNCATE هم می‌گیرد. پاک‌سازی/درون‌ریزی با session_replication_role=replica از آن می‌گذرد.
-- =====================================================================
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT DISTINCT t.tgrelid::regclass AS rel
      FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
      JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'core' AND p.proname = 'forbid_mutation'
     WHERE NOT t.tgisinternal AND (t.tgtype & 1) = 1                    -- FOR EACH ROW
       AND (t.tgtype & (8 | 16)) <> 0                                   -- DELETE یا UPDATE
       AND NOT EXISTS (SELECT 1 FROM pg_trigger x
                        WHERE x.tgrelid = t.tgrelid AND NOT x.tgisinternal AND (x.tgtype & 32) <> 0)  -- TRUNCATE
  LOOP
    EXECUTE format('CREATE TRIGGER trg_no_truncate BEFORE TRUNCATE ON %s FOR EACH STATEMENT EXECUTE FUNCTION core.forbid_mutation()', r.rel);
  END LOOP;
END $$;

-- =====================================================================
-- ۸. خودآزمایی پایانی (روی کل پایگاه، نه فقط این فایل): هیچ FK «NOT VALID» نمانده، هر FK بین دو جدول
--    مستأجری tenant_id دارد، و هر FK بین‌اسکیمایی بیرون از depends_on (core.xfk_dag_violations()) برچسب
--    HK_DAG_EXCEPTION دارد.
--    (وجود تک‌تک FKهای بالا را pg_temp.hk_add_fk تضمین می‌کند: یا افزوده/موجود/هم‌ارز، یا خطا.)
-- =====================================================================
DO $$
DECLARE
  v_missing int;
  v_bad     text;
BEGIN
  SELECT count(*) INTO v_missing FROM pg_constraint c
   WHERE c.contype = 'f' AND NOT c.convalidated
     AND c.conrelid::regclass::text ~ '^(core|ledger|parties|catalog|inventory|sales|purchase|treasury|pos|tax|payroll|assets|rules|migration|assistant)\.';
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'HK_XFK_NOT_VALIDATED: % foreign keys are NOT VALID', v_missing;
  END IF;

  -- FK بین دو جدول مستأجری بدون tenant_id (تکرار عمدی lint هسته، برای همهٔ اسکیماها)
  SELECT string_agg(c.conrelid::regclass || '/' || c.conname, ', ') INTO v_bad
    FROM pg_constraint c
   WHERE c.contype = 'f'
     AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.conrelid  AND a.attname = 'tenant_id' AND NOT a.attisdropped)
     AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.confrelid AND a.attname = 'tenant_id' AND NOT a.attisdropped)
     AND c.confrelid <> 'core.tenant'::regclass
     AND NOT ((SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'tenant_id') = ANY (c.conkey));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'HK_XFK_NO_TENANT: %', v_bad;
  END IF;

  -- FK بین‌اسکیمایی بیرون از depends_on (۰۱ §۵-۱ + تصمیم‌ها) بدون برچسب HK_DAG_EXCEPTION؛ شامل هم‌لایه و چرخه
  SELECT string_agg(v.from_table || '/' || v.conname || ' -> ' || v.to_table || ' [' || v.problem || ']', ', '
                    ORDER BY v.from_table::text, v.conname) INTO v_bad
    FROM core.xfk_dag_violations() v;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'HK_XFK_DAG: cross-schema FK outside the module DAG (01 §5-1 depends_on) without HK_DAG_EXCEPTION: %', v_bad;
  END IF;
END $$;

RESET client_min_messages;
