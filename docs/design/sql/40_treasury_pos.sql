-- =====================================================================
-- حساب‌کتاب — 40_treasury_pos.sql   (سند طراحی: docs/design/06-treasury-pos.md)
-- خزانه‌داری (treasury): صندوق، بانک، تنخواه، اسناد دریافت/پرداخت چندابزاری، اقلام باز و
-- تسویه، چک صیادی (دریافتی/پرداختی/تضمینی) با ماشین حالت رویدادمحور، دسته‌چک و چاپ چک،
-- کارتخوان و تطبیق تسویهٔ شاپرک، درگاه پرداخت مستأجر، ورود صورتحساب و مغایرت‌گیری.
-- صندوق فروشگاهی (pos): پایانه، روز کاری، شیفت، سفارش باز رستوران، رسید تغییرناپذیر،
-- پروتکل همگام‌سازی آفلاین (فرمان امضاشده با زنجیرهٔ hash)، جریان‌های دادهٔ پایه.
--
-- پیش‌نیاز: 00_foundation → 10_core → 20_ledger → 25_masterdata (ترتیب این فایل‌ها مهم نیست
-- مگر اینکه همه پیش از این فایل اجرا شده باشند). اجرا با نقش migrator/superuser.
-- قواعد: PK = id uuid DEFAULT uuidv7()؛ هر جدول مستأجری tenant_id + UNIQUE (tenant_id, id) +
-- core.enable_tenant_rls؛ ارجاع بین جدول‌های مستأجری FK ترکیبی؛ ستون کنشگر → عضویت.
-- ارجاع به inventory، sales و tax فقط uuid است و FK آن در 99_cross_fk (سند §۱۲) می‌آید.
-- کدهای خطا: HK_TRS_* (خزانه)، HK_CHQ_* (چک)، HK_BNK_* (صورتحساب و مغایرت)، HK_CRD_* (کارتخوان)،
-- HK_GW_* (درگاه)، HK_POS_* (صندوق)، HK_SYNC_* (همگام‌سازی). نگاشت به کد API در سند §۵-۱۶.
-- =====================================================================

DO $$
BEGIN
  IF current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'HK_ENCODING: data-plane database must be UTF8 (found %)', current_setting('server_encoding');
  END IF;
  IF to_regclass('core.number_series') IS NULL OR to_regclass('ledger.journal') IS NULL
     OR to_regclass('parties.party') IS NULL OR to_regclass('catalog.item_variant') IS NULL THEN
    RAISE EXCEPTION 'HK_PREREQ: 40_treasury_pos.sql needs 00_foundation, 10_core, 20_ledger and 25_masterdata applied first';
  END IF;
END $$;

-- =====================================================================
-- ۱. دادهٔ مرجع سراسری (ref) — فقط SELECT برای برنامه؛ به‌روزرسانی فقط با migration/بستهٔ امضاشده
-- =====================================================================
-- رنگ‌بندی اعتباری صیاد: فقط برچسبِ رنگی که استعلام نشان می‌دهد. هیچ آستانهٔ تعداد/مبلغی ذخیره
-- نمی‌شود و حساب‌کتاب رنگ را خودش محاسبه نمی‌کند (پژوهش ۰۵ §۲-۱-۳، قید راستی‌آزمایی).
CREATE TABLE IF NOT EXISTS ref.sayad_credit_status (
  code          text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  name_fa       text NOT NULL,
  display_hex   text CHECK (display_hex ~ '^#[0-9A-Fa-f]{6}$'),
  severity      smallint NOT NULL CHECK (severity BETWEEN 0 AND 9),   -- فقط ترتیب نمایش و هشدار داخلی
  is_active     boolean NOT NULL DEFAULT true,
  source        text NOT NULL,
  confidence    text NOT NULL CHECK (confidence IN ('high','medium','low')),
  data_version  text NOT NULL
);
INSERT INTO ref.sayad_credit_status (code, name_fa, display_hex, severity, source, confidence, data_version) VALUES
  ('white',     'سفید',       '#FFFFFF', 0, 'research-05 §2-1-3 (labels only)', 'low', 'sayad-colors-v1'),
  ('yellow',    'زرد',        '#F5C518', 1, 'research-05 §2-1-3 (labels only)', 'low', 'sayad-colors-v1'),
  ('orange',    'نارنجی',     '#F28C28', 2, 'research-05 §2-1-3 (labels only)', 'low', 'sayad-colors-v1'),
  ('brown',     'قهوه‌ای',     '#8B5A2B', 3, 'research-05 §2-1-3 (labels only)', 'low', 'sayad-colors-v1'),
  ('red',       'قرمز',       '#D32F2F', 4, 'research-05 §2-1-3 (labels only)', 'low', 'sayad-colors-v1'),
  ('not_shown', 'نمایش داده نشد', NULL,  9, 'product: inquiry without a colour', 'high', 'sayad-colors-v1')
ON CONFLICT (code) DO NOTHING;

-- شرکت‌های PSP (کارتخوان و درگاه بانکی). داده‌محور؛ نام درایور در integrations همین کد است.
CREATE TABLE IF NOT EXISTS ref.psp (
  code          text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  name_fa       text NOT NULL,
  name_en       text NOT NULL,
  services      text[] NOT NULL CHECK (cardinality(services) >= 1 AND services <@ ARRAY['card_pos','ipg']::text[]),
  is_active     boolean NOT NULL DEFAULT true,
  source        text NOT NULL,
  confidence    text NOT NULL CHECK (confidence IN ('high','medium','low')),
  data_version  text NOT NULL
);
INSERT INTO ref.psp (code, name_fa, name_en, services, source, confidence, data_version) VALUES
  ('behpardakht', 'به‌پرداخت ملت',             'Behpardakht Mellat',      '{card_pos,ipg}', 'research-05 §2-5-1', 'medium', 'psp-v1'),
  ('sadad',       'سداد (بانک ملی)',           'Sadad',                   '{card_pos,ipg}', 'research-05 §2-5-1', 'medium', 'psp-v1'),
  ('sep',         'سامان کیش',                 'Saman Electronic Payment','{card_pos,ipg}', 'research-05 §2-5-1', 'medium', 'psp-v1'),
  ('irankish',    'ایران‌کیش',                  'Iran Kish',               '{card_pos,ipg}', 'research-05 §2-5-1', 'medium', 'psp-v1'),
  ('pna',         'پرداخت نوین آرین',           'Pardakht Novin Arian',    '{card_pos,ipg}', 'research-05 §2-5-1', 'medium', 'psp-v1'),
  ('pec',         'تجارت الکترونیک پارسیان',    'Parsian E-Commerce',      '{card_pos,ipg}', 'research-05 §2-5-1', 'medium', 'psp-v1'),
  ('fanava',      'فن‌آوا کارت',                'Fanava Card',             '{card_pos,ipg}', 'research-05 §2-5-1', 'medium', 'psp-v1'),
  ('sepehr',      'پرداخت الکترونیک سپهر',      'Sepehr',                  '{card_pos,ipg}', 'research-05 §2-5-1', 'medium', 'psp-v1'),
  ('asanpardakht','آسان‌پرداخت',                'Asan Pardakht',           '{card_pos,ipg}', 'research-05 §2-5-1', 'medium', 'psp-v1'),
  ('pep',         'پرداخت الکترونیک پاسارگاد',  'Pasargad E-Payment',      '{card_pos,ipg}', 'research-05 §2-5-1', 'medium', 'psp-v1')
ON CONFLICT (code) DO NOTHING;

-- =====================================================================
-- ۲. کاتالوگ‌های کدمحور treasury (بدون tenant_id؛ hk_app فقط SELECT)
-- =====================================================================
-- وضعیت‌های چک به ازای (جهت، کاربرد). is_holding = «هنوز نزد ما یا به عهدهٔ ما» (مبنای زیردفتر)؛
-- sayad_unique = این وضعیت در یکتایی شناسهٔ صیاد شمرده می‌شود.
CREATE TABLE IF NOT EXISTS treasury.cheque_state (
  direction     text NOT NULL CHECK (direction IN ('received','issued')),
  purpose       text NOT NULL CHECK (purpose IN ('payment','guarantee')),
  state         text NOT NULL CHECK (state ~ '^[a-z][a-z_]{1,40}$'),
  is_holding    boolean NOT NULL,
  is_terminal   boolean NOT NULL,
  sayad_unique  boolean NOT NULL,
  name_fa       text NOT NULL,
  PRIMARY KEY (direction, purpose, state),
  CHECK (NOT (is_holding AND is_terminal))
);
INSERT INTO treasury.cheque_state (direction, purpose, state, is_holding, is_terminal, sayad_unique, name_fa) VALUES
  ('received','payment','in_hand',                 true,  false, true,  'نزد صندوق'),
  ('received','payment','deposited',               true,  false, true,  'در جریان وصول'),
  ('received','payment','partially_collected',     true,  false, true,  'وصول بخشی'),
  ('received','payment','bounced',                 true,  false, true,  'برگشتی'),
  ('received','payment','returned_by_third_party', true,  false, true,  'برگشت از شخص ثالث'),
  ('received','payment','endorsed',                false, false, false, 'خرج‌شده (انتقال به غیر)'),
  ('received','payment','collected',               false, true,  false, 'وصول‌شده'),
  ('received','payment','settled',                 false, true,  false, 'تسویهٔ برگشتی'),
  ('received','payment','replaced',                false, true,  false, 'تعویض‌شده'),
  ('received','payment','returned_to_drawer',      false, true,  false, 'عودت به صادرکننده'),
  ('received','payment','cancelled',               false, true,  false, 'ابطال ثبت'),
  ('received','guarantee','held',                  true,  false, true,  'ضمانت نزد ما'),
  ('received','guarantee','returned_to_drawer',    false, true,  false, 'ضمانت عودت‌شده'),
  ('received','guarantee','enforced',              false, true,  false, 'ضمانت به اجرا گذاشته‌شده'),
  ('received','guarantee','cancelled',             false, true,  false, 'ابطال ثبت'),
  ('issued','payment','issued',                    true,  false, true,  'صادره'),
  ('issued','payment','bounced',                   true,  false, true,  'برگشتی (چک ما)'),
  ('issued','payment','cleared',                   false, true,  true,  'پاس‌شده'),
  ('issued','payment','returned',                  false, true,  true,  'عودت از گیرنده'),
  ('issued','payment','cancelled',                 false, true,  false, 'ابطال ثبت'),
  ('issued','guarantee','issued',                  true,  false, true,  'ضمانت صادره'),
  ('issued','guarantee','returned',                false, true,  true,  'ضمانت عودت‌شده'),
  ('issued','guarantee','enforced',                false, true,  true,  'ضمانت اجراشده'),
  ('issued','guarantee','cancelled',               false, true,  false, 'ابطال ثبت')
ON CONFLICT DO NOTHING;

-- گذارهای مجاز. جدول پژوهش ۰۵ §۲-۲-۲ (R1..R14 با R3' و R5') و §۲-۲-۳ (P1..P7) عیناً (is_research_row)،
-- به‌اضافهٔ گذارهای ضمانت (G*)، ورود مهاجرت (IMP_*) و چند افزودهٔ مستند (X*).
-- journal_template: آرایهٔ سطر {side, key, amount, dim}. key یا کلید نگاشت ledger است یا نماد:
--   @holding (اسناد دریافتنی جاری یا بلندمدت)، @holding_payable، @counter (حساب طرف که در دریافت/پرداخت
--   ثبت شد)، @bounce_target (طبق سیاست: چک برگشتی یا دریافتنی شخص)، @fund (صندوق یا بانک رویداد)،
--   @cost_target (هزینهٔ واخواست یا دریافتنی شخص). amount: face|partial|remainder|outstanding|explicit.
-- برای هر قالب، چندمجموعهٔ amount در دو طرف برابر است (آزمون T02 تراز ساختاری را می‌سنجد).
CREATE TABLE IF NOT EXISTS treasury.cheque_transition (
  code              text PRIMARY KEY CHECK (code ~ '^[A-Z][A-Za-z0-9_]{0,39}$'),
  direction         text NOT NULL,
  purpose           text NOT NULL,
  from_state        text,                         -- NULL = ایجاد چک
  to_state          text NOT NULL,
  op                text NOT NULL CHECK (op ~ '^[a-z][a-z_]{1,40}$'),
  requires_journal  boolean NOT NULL,
  amount_rule       text NOT NULL CHECK (amount_rule IN ('none','face','partial','outstanding','explicit','installment')),
  requires_fund     boolean NOT NULL DEFAULT false,      -- بانک یا صندوق رویداد لازم است
  requires_counterparty boolean NOT NULL DEFAULT false,  -- طرف تازه (گیرندهٔ انتقال، ...)
  journal_template  jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(journal_template) = 'array'),
  name_fa           text NOT NULL,
  research_ref      text NOT NULL,
  is_research_row   boolean NOT NULL,
  FOREIGN KEY (direction, purpose, to_state) REFERENCES treasury.cheque_state (direction, purpose, state),
  FOREIGN KEY (direction, purpose, from_state) REFERENCES treasury.cheque_state (direction, purpose, state),
  CHECK (NOT requires_journal OR jsonb_array_length(journal_template) >= 2),
  CHECK (requires_journal OR jsonb_array_length(journal_template) = 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS cheque_transition_shape_uq ON treasury.cheque_transition
  (direction, purpose, from_state, to_state, op) NULLS NOT DISTINCT;

INSERT INTO treasury.cheque_transition (code, direction, purpose, from_state, to_state, op, requires_journal, amount_rule,
                                        requires_fund, requires_counterparty, journal_template, name_fa, research_ref, is_research_row) VALUES
  -- ---------- چک دریافتی (پرداخت) ----------
  ('R1',  'received','payment', NULL,          'in_hand',   'receive',          true, 'face', false, false,
   '[{"side":"debit","key":"@holding","amount":"face","dim":"party:from"},{"side":"credit","key":"@counter","amount":"face","dim":"party:from"}]',
   'دریافت چک', '05 §2-2-2 R1', true),
  ('R2',  'received','payment', 'in_hand',     'deposited', 'deposit',          true, 'face', true, false,
   '[{"side":"debit","key":"treasury.cheque_in_collection","amount":"face","dim":"fund"},{"side":"credit","key":"@holding","amount":"face","dim":"party:from"}]',
   'واگذاری به بانک', '05 §2-2-2 R2', true),
  ('R3',  'received','payment', 'deposited',   'collected', 'collect',          true, 'face', true, false,
   '[{"side":"debit","key":"@fund","amount":"face","dim":"fund"},{"side":"credit","key":"treasury.cheque_in_collection","amount":"face","dim":"deposit_bank"}]',
   'وصول', '05 §2-2-2 R3', true),
  ('R3B', 'received','payment', 'in_hand',     'collected', 'collect_direct',   true, 'face', true, false,
   '[{"side":"debit","key":"@fund","amount":"face","dim":"fund"},{"side":"credit","key":"@holding","amount":"face","dim":"party:from"}]',
   'وصول مستقیم (R3'')', '05 §2-2-2 R3''', true),
  ('R4',  'received','payment', 'deposited',   'partially_collected', 'collect_partial', true, 'partial', true, false,
   '[{"side":"debit","key":"@fund","amount":"partial","dim":"fund"},{"side":"debit","key":"@bounce_target","amount":"remainder","dim":"party:from"},{"side":"credit","key":"treasury.cheque_in_collection","amount":"partial","dim":"deposit_bank"},{"side":"credit","key":"treasury.cheque_in_collection","amount":"remainder","dim":"deposit_bank"}]',
   'وصول بخشی', '05 §2-2-2 R4', true),
  ('R5',  'received','payment', 'deposited',   'bounced',   'bounce',           true, 'face', false, false,
   '[{"side":"debit","key":"@bounce_target","amount":"face","dim":"party:from"},{"side":"credit","key":"treasury.cheque_in_collection","amount":"face","dim":"deposit_bank"}]',
   'برگشت از بانک', '05 §2-2-2 R5', true),
  ('R5B', 'received','payment', 'in_hand',     'bounced',   'bounce_at_counter', true, 'face', false, false,
   '[{"side":"debit","key":"@bounce_target","amount":"face","dim":"party:from"},{"side":"credit","key":"@holding","amount":"face","dim":"party:from"}]',
   'برگشت در شعبه (R5'')', '05 §2-2-2 R5''', true),
  ('R6',  'received','payment', 'bounced',     'bounced',   'protest_cost',     true, 'explicit', true, false,
   '[{"side":"debit","key":"@cost_target","amount":"explicit","dim":"party:from"},{"side":"credit","key":"@fund","amount":"explicit","dim":"fund"}]',
   'هزینهٔ گواهی عدم پرداخت', '05 §2-2-2 R6', true),
  ('R6B', 'received','payment', 'partially_collected', 'partially_collected', 'protest_cost', true, 'explicit', true, false,
   '[{"side":"debit","key":"@cost_target","amount":"explicit","dim":"party:from"},{"side":"credit","key":"@fund","amount":"explicit","dim":"fund"}]',
   'هزینهٔ گواهی (وصول بخشی)', '05 §2-2-2 R6 (applied to R4 remainder)', false),
  ('R6C', 'received','payment', 'returned_by_third_party', 'returned_by_third_party', 'protest_cost', true, 'explicit', true, false,
   '[{"side":"debit","key":"@cost_target","amount":"explicit","dim":"party:from"},{"side":"credit","key":"@fund","amount":"explicit","dim":"fund"}]',
   'هزینهٔ گواهی (برگشت از ثالث)', '05 §2-2-2 R6 (applied to R10)', false),
  ('R7',  'received','payment', 'bounced',     'settled',   'settle',           true, 'outstanding', true, false,
   '[{"side":"debit","key":"@fund","amount":"outstanding","dim":"fund"},{"side":"credit","key":"@bounce_target","amount":"outstanding","dim":"party:from"}]',
   'تسویهٔ چک برگشتی', '05 §2-2-2 R7', true),
  ('R7B', 'received','payment', 'partially_collected', 'settled', 'settle',     true, 'outstanding', true, false,
   '[{"side":"debit","key":"@fund","amount":"outstanding","dim":"fund"},{"side":"credit","key":"@bounce_target","amount":"outstanding","dim":"party:from"}]',
   'تسویهٔ باقی‌ماندهٔ وصول بخشی', '05 §2-2-2 R7 (after R4)', false),
  ('R7C', 'received','payment', 'returned_by_third_party', 'settled', 'settle', true, 'outstanding', true, false,
   '[{"side":"debit","key":"@fund","amount":"outstanding","dim":"fund"},{"side":"credit","key":"treasury.cheque_bounced","amount":"outstanding","dim":"party:from"}]',
   'تسویهٔ چک برگشتی از ثالث', '05 §2-2-2 R7 (after R10)', false),
  -- تسویهٔ قسطی (افزوده): 0 < مبلغ < مانده؛ collected_amount به‌اندازهٔ قسط بالا می‌رود و چک در همان وضعیت می‌ماند
  ('R7P', 'received','payment', 'bounced',     'bounced',   'settle_partial',   true, 'installment', true, false,
   '[{"side":"debit","key":"@fund","amount":"explicit","dim":"fund"},{"side":"credit","key":"@bounce_target","amount":"explicit","dim":"party:from"}]',
   'تسویهٔ قسطی چک برگشتی', '05 §2-2-2 R7 (installment)', false),
  ('R7PB','received','payment', 'partially_collected', 'partially_collected', 'settle_partial', true, 'installment', true, false,
   '[{"side":"debit","key":"@fund","amount":"explicit","dim":"fund"},{"side":"credit","key":"@bounce_target","amount":"explicit","dim":"party:from"}]',
   'تسویهٔ قسطی باقی‌ماندهٔ وصول بخشی', '05 §2-2-2 R7 (installment after R4)', false),
  ('R8',  'received','payment', 'bounced',     'replaced',  'replace',          true, 'outstanding', false, false,
   '[{"side":"debit","key":"@holding","amount":"outstanding","dim":"party:from"},{"side":"credit","key":"@bounce_target","amount":"outstanding","dim":"party:from"}]',
   'تعویض چک برگشتی', '05 §2-2-2 R8', true),
  ('R8B', 'received','payment', 'partially_collected', 'replaced', 'replace',   true, 'outstanding', false, false,
   '[{"side":"debit","key":"@holding","amount":"outstanding","dim":"party:from"},{"side":"credit","key":"@bounce_target","amount":"outstanding","dim":"party:from"}]',
   'تعویض باقی‌ماندهٔ وصول بخشی', '05 §2-2-2 R8 (after R4)', false),
  ('R8C', 'received','payment', 'returned_by_third_party', 'replaced', 'replace', true, 'outstanding', false, false,
   '[{"side":"debit","key":"@holding","amount":"outstanding","dim":"party:from"},{"side":"credit","key":"treasury.cheque_bounced","amount":"outstanding","dim":"party:from"}]',
   'تعویض چک برگشتی از ثالث', '05 §2-2-2 R8 (after R10)', false),
  ('R9',  'received','payment', 'in_hand',     'endorsed',  'endorse',          true, 'face', false, true,
   '[{"side":"debit","key":"@counter","amount":"face","dim":"party:endorsee"},{"side":"credit","key":"@holding","amount":"face","dim":"party:from"}]',
   'خرج چک (انتقال به غیر)', '05 §2-2-2 R9', true),
  ('R10', 'received','payment', 'endorsed',    'returned_by_third_party', 'third_party_return', true, 'face', false, false,
   '[{"side":"debit","key":"treasury.cheque_bounced","amount":"face","dim":"party:from"},{"side":"credit","key":"@counter","amount":"face","dim":"party:endorsee"}]',
   'برگشت از شخص ثالث', '05 §2-2-2 R10', true),
  ('R11', 'received','payment', 'in_hand',     'returned_to_drawer', 'return_to_drawer', true, 'face', false, false,
   '[{"side":"debit","key":"@counter","amount":"face","dim":"party:from"},{"side":"credit","key":"@holding","amount":"face","dim":"party:from"}]',
   'عودت به صادرکننده', '05 §2-2-2 R11', true),
  ('R12', 'received','payment', 'deposited',   'in_hand',   'withdraw_deposit', true, 'face', false, false,
   '[{"side":"debit","key":"@holding","amount":"face","dim":"party:from"},{"side":"credit","key":"treasury.cheque_in_collection","amount":"face","dim":"deposit_bank"}]',
   'برگشت از بانک بدون ارائه', '05 §2-2-2 R12', true),
  ('R13A','received','payment', 'in_hand',     'cancelled', 'cancel',           false,'none', false, false, '[]', 'ابطال ثبت', '05 §2-2-2 R13', true),
  ('R13B','received','payment', 'deposited',   'cancelled', 'cancel',           false,'none', false, false, '[]', 'ابطال ثبت', '05 §2-2-2 R13', true),
  ('R13C','received','payment', 'partially_collected','cancelled','cancel',     false,'none', false, false, '[]', 'ابطال ثبت', '05 §2-2-2 R13', true),
  ('R13D','received','payment', 'bounced',     'cancelled', 'cancel',           false,'none', false, false, '[]', 'ابطال ثبت', '05 §2-2-2 R13', true),
  ('R13E','received','payment', 'returned_by_third_party','cancelled','cancel', false,'none', false, false, '[]', 'ابطال ثبت', '05 §2-2-2 R13', true),
  ('R13F','received','payment', 'endorsed',    'cancelled', 'cancel',           false,'none', false, false, '[]', 'ابطال ثبت', '05 §2-2-2 R13', true),
  ('R14', 'received','payment', 'in_hand',     'in_hand',   'reclassify_current', true, 'face', false, false,
   '[{"side":"debit","key":"treasury.cheque_receivable","amount":"face","dim":"party:from"},{"side":"credit","key":"treasury.cheque_receivable_lt","amount":"face","dim":"party:from"}]',
   'انتقال از بلندمدت به جاری', '05 §2-2-2 R14', true),
  -- ---------- چک پرداختی ----------
  ('P1',  'issued','payment', NULL,           'issued',    'issue',            true, 'face', false, false,
   '[{"side":"debit","key":"@counter","amount":"face","dim":"party:payee"},{"side":"credit","key":"@holding_payable","amount":"face","dim":"party:payee"}]',
   'صدور چک', '05 §2-2-3 P1', true),
  ('P2',  'issued','payment', 'issued',       'cleared',   'clear',            true, 'face', true, false,
   '[{"side":"debit","key":"@holding_payable","amount":"face","dim":"party:payee"},{"side":"credit","key":"treasury.bank","amount":"face","dim":"own_bank"}]',
   'پاس شدن', '05 §2-2-3 P2', true),
  ('P3',  'issued','payment', 'issued',       'bounced',   'bounce',           true, 'face', false, false,
   '[{"side":"debit","key":"@holding_payable","amount":"face","dim":"party:payee"},{"side":"credit","key":"@counter","amount":"face","dim":"party:payee"}]',
   'برگشت چک ما', '05 §2-2-3 P3', true),
  ('P4',  'issued','payment', 'issued',       'returned',  'return',           true, 'face', false, false,
   '[{"side":"debit","key":"@holding_payable","amount":"face","dim":"party:payee"},{"side":"credit","key":"@counter","amount":"face","dim":"party:payee"}]',
   'عودت از گیرنده', '05 §2-2-3 P4', true),
  ('P7',  'issued','payment', 'issued',       'issued',    'reclassify_current', true, 'face', false, false,
   '[{"side":"debit","key":"treasury.cheque_payable_lt","amount":"face","dim":"party:payee"},{"side":"credit","key":"treasury.cheque_payable","amount":"face","dim":"party:payee"}]',
   'انتقال از بلندمدت به جاری', '05 §2-2-3 P7', true),
  ('X2',  'issued','payment', 'bounced',      'cleared',   'clear_after_bounce', true, 'face', true, false,
   '[{"side":"debit","key":"@counter","amount":"face","dim":"party:payee"},{"side":"credit","key":"treasury.bank","amount":"face","dim":"own_bank"}]',
   'پاس شدن پس از برگشت (ارائهٔ دوباره)', 'design addition (re-presentation after P3)', false),
  ('X4',  'issued','payment', 'bounced',      'returned',  'return_after_bounce', false, 'none', false, false, '[]',
   'عودت برگ برگشتی پس از تسویهٔ دیگر', 'design addition (after P3, no journal)', false),
  ('XC1', 'issued','payment', 'issued',       'cancelled', 'cancel',           false,'none', false, false, '[]', 'ابطال ثبت', 'design addition (mirror of R13)', false),
  -- ---------- چک تضمینی (فقط حساب‌های انتظامی) ----------
  ('G1',  'received','guarantee', NULL,       'held',      'receive',          true, 'face', false, false,
   '[{"side":"debit","key":"treasury.guarantee_received","amount":"face","dim":"party:from"},{"side":"credit","key":"treasury.guarantee_received_contra","amount":"face","dim":"party:from"}]',
   'دریافت چک تضمینی', '05 §2-2-2 (guarantee)', true),
  ('G2',  'received','guarantee', 'held',     'returned_to_drawer', 'return_to_drawer', true, 'face', false, false,
   '[{"side":"debit","key":"treasury.guarantee_received_contra","amount":"face","dim":"party:from"},{"side":"credit","key":"treasury.guarantee_received","amount":"face","dim":"party:from"}]',
   'عودت چک تضمینی', '05 §2-2-2 (guarantee)', true),
  ('G3',  'received','guarantee', 'held',     'enforced',  'enforce',          true, 'face', false, false,
   '[{"side":"debit","key":"treasury.guarantee_received_contra","amount":"face","dim":"party:from"},{"side":"credit","key":"treasury.guarantee_received","amount":"face","dim":"party:from"}]',
   'به اجرا گذاشتن ضمانت (سپس R1 روی چک تبدیل‌شده)', '05 §2-2-2 (guarantee)', true),
  ('GXR', 'received','guarantee', 'held',     'cancelled', 'cancel',           false,'none', false, false, '[]', 'ابطال ثبت', '05 §2-2-2 R13 (guarantee)', false),
  ('G4',  'issued','guarantee', NULL,         'issued',    'issue',            true, 'face', false, false,
   '[{"side":"debit","key":"treasury.guarantee_given","amount":"face","dim":"party:payee"},{"side":"credit","key":"treasury.guarantee_given_contra","amount":"face","dim":"party:payee"}]',
   'صدور چک تضمینی', '05 §2-2-3 (guarantee)', true),
  ('G5',  'issued','guarantee', 'issued',     'returned',  'return',           true, 'face', false, false,
   '[{"side":"debit","key":"treasury.guarantee_given_contra","amount":"face","dim":"party:payee"},{"side":"credit","key":"treasury.guarantee_given","amount":"face","dim":"party:payee"}]',
   'عودت چک تضمینی ما', '05 §2-2-3 (guarantee)', true),
  ('G6',  'issued','guarantee', 'issued',     'enforced',  'enforce',          true, 'face', false, false,
   '[{"side":"debit","key":"treasury.guarantee_given_contra","amount":"face","dim":"party:payee"},{"side":"credit","key":"treasury.guarantee_given","amount":"face","dim":"party:payee"}]',
   'اجرای ضمانت علیه ما (سپس P1 روی چک تبدیل‌شده)', '05 §2-2-3 (guarantee)', true),
  ('GXI', 'issued','guarantee', 'issued',     'cancelled', 'cancel',           false,'none', false, false, '[]', 'ابطال ثبت', 'design addition (guarantee)', false),
  -- ---------- ورود از نرم‌افزار قبلی: رکورد چک با وضعیت جاری، بدون سند (مانده از افتتاحیه) ----------
  ('IMP_RP_IN_HAND',   'received','payment', NULL, 'in_hand',   'import', false, 'none', false, false, '[]', 'ورود: نزد صندوق', '05 §3-9', true),
  ('IMP_RP_DEPOSITED', 'received','payment', NULL, 'deposited', 'import', false, 'none', false, false, '[]', 'ورود: در جریان وصول', '05 §3-9', true),
  ('IMP_RP_BOUNCED',   'received','payment', NULL, 'bounced',   'import', false, 'none', false, false, '[]', 'ورود: برگشتی', '05 §3-9', true),
  ('IMP_RG_HELD',      'received','guarantee', NULL, 'held',    'import', false, 'none', false, false, '[]', 'ورود: ضمانت نزد ما', '05 §3-9', true),
  ('IMP_IP_ISSUED',    'issued','payment', NULL, 'issued',      'import', false, 'none', false, false, '[]', 'ورود: صادرهٔ پاس‌نشده', '05 §3-9', true),
  ('IMP_IG_ISSUED',    'issued','guarantee', NULL, 'issued',    'import', false, 'none', false, false, '[]', 'ورود: ضمانت صادره', '05 §3-9', true)
ON CONFLICT (code) DO NOTHING;

-- درگاه‌های پرداخت (رجیستری آداپترهای integrations). status=blocked یعنی پیکربندی جدید ممنوع.
-- واحد مبلغ API فقط برای تبدیل در آداپتر است؛ ذخیره همیشه ریال صحیح.
CREATE TABLE IF NOT EXISTS treasury.gateway_provider (
  code               text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  name_fa            text NOT NULL,
  provider_kind      text NOT NULL CHECK (provider_kind IN ('psp_bank','payment_facilitator')),
  psp_code           text REFERENCES ref.psp(code),
  api_amount_unit    core.amount_unit NOT NULL,
  verify_deadline_s  integer CHECK (verify_deadline_s > 0),
  needs_settle       boolean NOT NULL DEFAULT false,
  supports_inquiry   boolean NOT NULL,
  supports_refund    boolean NOT NULL,
  status             text NOT NULL CHECK (status IN ('active','deprecated','blocked')),
  status_note        text,
  source             text NOT NULL,
  confidence         text NOT NULL CHECK (confidence IN ('high','medium','low')),
  data_version       text NOT NULL,
  CHECK (status = 'active' OR status_note IS NOT NULL),
  CHECK (provider_kind = 'payment_facilitator' OR psp_code IS NOT NULL)
);
INSERT INTO treasury.gateway_provider (code, name_fa, provider_kind, psp_code, api_amount_unit, verify_deadline_s, needs_settle,
                                       supports_inquiry, supports_refund, status, status_note, source, confidence, data_version) VALUES
  ('zarinpal', 'زرین‌پال',        'payment_facilitator', NULL, 'IRR', NULL, false, true,  true,  'active', NULL, 'research-05 §2-6-1 (official SDK)', 'high', 'gw-v1'),
  ('zibal',    'زیبال',           'payment_facilitator', NULL, 'IRR', NULL, false, true,  false, 'active', NULL, 'research-05 §2-6-1', 'high', 'gw-v1'),
  ('vandar',   'وندار',           'payment_facilitator', NULL, 'IRR', NULL, false, true,  false, 'active', NULL, 'research-05 §2-6-1 (multipay only)', 'medium', 'gw-v1'),
  ('payping',  'پی‌پینگ',          'payment_facilitator', NULL, 'IRT', NULL, false, false, false, 'active', NULL, 'research-05 §2-6-1 (multipay only)', 'medium', 'gw-v1'),
  ('nextpay',  'نکست‌پی',          'payment_facilitator', NULL, 'IRT', NULL, false, false, false, 'active', NULL, 'research-05 §2-6-1 (multipay only)', 'medium', 'gw-v1'),
  ('jibit',    'جیبیت',           'payment_facilitator', NULL, 'IRR', NULL, false, true,  false, 'active', NULL, 'research-05 §2-6-1 (multipay only)', 'medium', 'gw-v1'),
  ('sep',      'سامان (SEP)',     'psp_bank', 'sep',          'IRR', 1800, false, false, false, 'active', NULL, 'research-05 §2-6-1', 'high', 'gw-v1'),
  ('mellat',   'به‌پرداخت ملت',    'psp_bank', 'behpardakht',  'IRR', NULL, true,  true,  false, 'active', NULL, 'research-05 §2-6-1 (codes 43/45 duplicate, 48 reversed)', 'high', 'gw-v1'),
  ('sadad',    'سداد',            'psp_bank', 'sadad',        'IRR', NULL, false, false, false, 'active', NULL, 'research-05 §2-6-1', 'high', 'gw-v1'),
  ('idpay',    'آیدی‌پی',          'payment_facilitator', NULL, 'IRR', NULL, false, false, false, 'blocked',
   'removed from multipay 2025-02-20 (suspicious activity); not recommended', 'research-05 §2-6-1', 'high', 'gw-v1')
ON CONFLICT (code) DO NOTHING;

-- فرهنگ مترادف سرستون صورتحساب (تشخیص خودکار). synonym نرمال‌شده با core.fa_search_key.
CREATE TABLE IF NOT EXISTS treasury.statement_header_synonym (
  field         text NOT NULL CHECK (field IN ('date','time','datetime','value_date','description','debit','credit',
                                               'amount','balance','reference','cheque_no','deposit_id','branch','counterparty')),
  synonym       text NOT NULL CHECK (synonym = core.fa_search_key(synonym) AND char_length(synonym) BETWEEN 1 AND 80),
  weight        numeric(4,2) NOT NULL DEFAULT 1 CHECK (weight > 0 AND weight <= 10),
  data_version  text NOT NULL,
  PRIMARY KEY (field, synonym)
);
INSERT INTO treasury.statement_header_synonym (field, synonym, weight, data_version)
SELECT v.f, core.fa_search_key(v.s), v.w, 'stmt-syn-v1' FROM (VALUES
  ('date','تاریخ',1.0), ('date','تاریخ تراکنش',2.0), ('date','تاریخ سند',1.5), ('date','تاریخ ثبت',1.5),
  ('time','ساعت',1.5), ('time','زمان',1.0),
  ('description','شرح',2.0), ('description','شرح تراکنش',2.5), ('description','شرح عملیات',2.0), ('description','توضیحات',1.5), ('description','بابت',1.0),
  ('debit','برداشت',2.5), ('debit','بدهکار',2.0), ('debit','مبلغ برداشت',3.0), ('debit','بدهکار (ریال)',3.0),
  ('credit','واریز',2.5), ('credit','بستانکار',2.0), ('credit','مبلغ واریز',3.0), ('credit','بستانکار (ریال)',3.0),
  ('amount','مبلغ',1.0), ('amount','مبلغ تراکنش',2.0),
  ('balance','مانده',2.5), ('balance','موجودی',2.0), ('balance','مانده حساب',3.0),
  ('reference','شماره سند',2.0), ('reference','شماره پیگیری',2.5), ('reference','شماره مرجع',2.5), ('reference','کد رهگیری',2.5), ('reference','شماره ارجاع',2.0),
  ('cheque_no','شماره چک',3.0), ('cheque_no','سریال چک',3.0),
  ('deposit_id','شناسه واریز',3.0), ('deposit_id','شناسه پرداخت',2.5),
  ('branch','کد شعبه',2.0), ('branch','شعبه',1.0), ('branch','نام شعبه',1.5),
  ('counterparty','نام واریزکننده',2.5), ('counterparty','شماره کارت مبدا',2.0), ('counterparty','شبای مقصد',2.0)
) AS v(f, s, w)
ON CONFLICT DO NOTHING;

-- قواعد کلیدواژهٔ شرح (طبقه‌بندی اولیه؛ پژوهش ۰۵ §۲-۳-۴). الگو regex روی شرح نرمال‌شده است.
CREATE TABLE IF NOT EXISTS treasury.statement_keyword (
  code                   text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  pattern                text NOT NULL,
  txn_class              text NOT NULL CHECK (txn_class IN ('paya','satna','pol','card_transfer','pos_settlement','ipg_settlement',
                                                            'cheque','bank_fee','interest','atm','loan','internal','other')),
  direction              text CHECK (direction IN ('in','out')),
  suggested_posting_key  text,
  priority               smallint NOT NULL DEFAULT 100,
  confidence             text NOT NULL CHECK (confidence IN ('high','medium','low')),
  data_version           text NOT NULL
);

-- پروفایل سراسری ورود صورتحساب (منتشرشده از پنل مالک). config: نگاشت ستون، قالب تاریخ، حالت مبلغ، ترتیب، پانویس.
CREATE TABLE IF NOT EXISTS treasury.statement_profile_global (
  code                text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_.-]{1,60}$'),
  version             integer NOT NULL CHECK (version >= 1),
  bank_code           text REFERENCES ref.bank(code),
  name_fa             text NOT NULL,
  config              jsonb NOT NULL CHECK (jsonb_typeof(config) = 'object'),
  status              text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','retired')),
  sample_fixture_ref  text,
  source              text NOT NULL,
  confidence          text NOT NULL CHECK (confidence IN ('high','medium','low')),
  published_at        timestamptz,
  PRIMARY KEY (code, version),
  CHECK (status <> 'published' OR published_at IS NOT NULL)
);
INSERT INTO treasury.statement_profile_global (code, version, bank_code, name_fa, config, status, source, confidence, published_at) VALUES
  ('generic.split', 1, NULL, 'عمومی: ستون برداشت و واریز جدا',
   '{"amount_mode":"split","date_formats":["jalali_slash","jalali_compact","jalali_dash"],"header_detect":"synonym_score","order":"auto","amount_unit":"IRR","footer_regex":"(جمع|مجموع)"}',
   'published', 'design default; per-bank profiles come from pilot samples (research-05 §4 Q1)', 'low', '2026-11-17T00:00:00Z'),
  ('generic.signed', 1, NULL, 'عمومی: یک ستون مبلغ با علامت',
   '{"amount_mode":"signed","date_formats":["jalali_slash","jalali_compact","jalali_dash"],"header_detect":"synonym_score","order":"auto","amount_unit":"IRR","footer_regex":"(جمع|مجموع)"}',
   'published', 'design default', 'low', '2026-11-17T00:00:00Z')
ON CONFLICT DO NOTHING;

-- =====================================================================
-- ۳. توابع کمکی treasury
-- =====================================================================
-- کارت فقط ماسک‌شده: ۱۶ نویسه، ۴ تا ۶ رقم اول، دست‌کم ۲ ستاره، ۴ رقم آخر. شمارهٔ کامل هرگز ذخیره نمی‌شود.
CREATE OR REPLACE FUNCTION treasury.is_masked_pan(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT coalesce(char_length(p) = 16 AND p ~ '^[0-9]{4,6}\*{2,8}[0-9]{4}$', false)
$$;

CREATE OR REPLACE FUNCTION treasury.all_masked_pans(p text[]) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT coalesce(bool_and(treasury.is_masked_pan(x)), true) FROM unnest(p) AS x
$$;

-- شخص مؤثر (پس از ادغام). parties ادغام زنجیره‌ای را فشرده می‌کند، پس یک گام کافی است.
CREATE OR REPLACE FUNCTION treasury.canonical_party(p_tenant uuid, p_party uuid) RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT coalesce(p.merged_into_id, p.id) FROM parties.party p WHERE p.tenant_id = p_tenant AND p.id = p_party
$$;

-- مقدار بُعد دفتر کل یک «منبع وجه» باید از نوع درست و متعلق به همین موجودیت باشد.
CREATE OR REPLACE FUNCTION treasury.assert_fund_dimension(p_tenant uuid, p_dim_value uuid, p_type_code text, p_entity uuid)
RETURNS void LANGUAGE plpgsql STABLE AS $$
DECLARE v_type text; v_module text; v_entity uuid;
BEGIN
  IF p_dim_value IS NULL THEN RETURN; END IF;
  SELECT t.code, v.source_module, v.source_entity_id INTO v_type, v_module, v_entity
    FROM ledger.dimension_value v JOIN ledger.dimension_type t ON t.tenant_id = v.tenant_id AND t.id = v.dimension_type_id
   WHERE v.tenant_id = p_tenant AND v.id = p_dim_value;
  IF v_type IS DISTINCT FROM p_type_code OR v_module IS DISTINCT FROM 'treasury' OR v_entity IS DISTINCT FROM p_entity THEN
    PERFORM core.raise_hk('HK_TRS_FUND_DIMENSION',
      format('dimension value must be type %s owned by treasury entity %s (got type %s, module %s, entity %s)',
             p_type_code, p_entity, v_type, v_module, v_entity));
  END IF;
END $$;

-- محافظ عمومی: ستون‌های فهرست‌شده پس از درج تغییرناپذیرند (نام ستون‌ها در TG_ARGV).
-- نکته: ستون‌های GENERATED در NEW تریگر BEFORE هنوز محاسبه نشده‌اند؛ مقایسهٔ to_jsonb باید آن‌ها را کنار بگذارد.
CREATE OR REPLACE FUNCTION treasury.freeze_columns() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c text; o jsonb := to_jsonb(OLD); n jsonb := to_jsonb(NEW);
BEGIN
  FOREACH c IN ARRAY TG_ARGV LOOP
    IF (o -> c) IS DISTINCT FROM (n -> c) THEN
      PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', format('%s.%s.%s cannot change after creation', TG_TABLE_SCHEMA, TG_TABLE_NAME, c));
    END IF;
  END LOOP;
  RETURN NEW;
END $$;

-- =====================================================================
-- ۴. منابع وجه: حساب بانکی، صندوق، تنخواه، پایانهٔ کارتخوان، حساب درگاه
-- =====================================================================
CREATE TABLE IF NOT EXISTS treasury.bank_account (
  tenant_id                    uuid NOT NULL REFERENCES core.tenant(id),
  id                           uuid NOT NULL DEFAULT uuidv7(),
  company_id                   uuid NOT NULL,
  branch_id                    uuid,
  code                         text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
  name                         text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  bank_code                    text NOT NULL REFERENCES ref.bank(code),
  bank_branch_code             text CHECK (bank_branch_code ~ '^[0-9]{1,6}$'),
  bank_branch_name             text CHECK (bank_branch_name = core.fa_normalize_text(bank_branch_name)),
  account_no                   text CHECK (account_no ~ '^[0-9][0-9./-]{2,30}$'),
  sheba                        text CHECK (sheba IS NULL OR ref.is_valid_sheba(sheba)),
  card_masks                   text[] NOT NULL DEFAULT '{}' CHECK (treasury.all_masked_pans(card_masks)),
  account_type                 text NOT NULL CHECK (account_type IN ('current','qard_hasan_savings','short_term_deposit',
                                                                     'long_term_deposit','foreign_currency','other')),
  currency                     char(3) NOT NULL DEFAULT 'IRR' REFERENCES ref.currency(code),
  holder_name                  text CHECK (holder_name = core.fa_normalize_text(holder_name)),
  supports_deposit_id          boolean NOT NULL DEFAULT false,
  dimension_value_id           uuid,
  sheba_verified_owner         text,
  sheba_verified_at            timestamptz,
  sheba_verification_provider  text,
  sheba_verification_ref       text,
  opened_on                    date,
  closed_on                    date,
  is_active                    boolean NOT NULL DEFAULT true,
  created_by                   uuid,
  created_at                   timestamptz NOT NULL DEFAULT now(),
  updated_at                   timestamptz NOT NULL DEFAULT now(),
  row_version                  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, dimension_value_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT bank_account_identifier CHECK (num_nonnulls(sheba, account_no) >= 1),
  CONSTRAINT bank_account_verification CHECK ((sheba_verified_at IS NULL) = (sheba_verified_owner IS NULL)
                                              AND (sheba_verified_at IS NULL) = (sheba_verification_provider IS NULL)),
  CONSTRAINT bank_account_closed CHECK (closed_on IS NULL OR NOT is_active),
  CONSTRAINT bank_account_fx CHECK ((account_type = 'foreign_currency') = (currency <> 'IRR'))
);
SELECT core.enable_tenant_rls('treasury.bank_account');
CREATE UNIQUE INDEX IF NOT EXISTS bank_account_sheba_uq ON treasury.bank_account (tenant_id, sheba) WHERE sheba IS NOT NULL;

CREATE TABLE IF NOT EXISTS treasury.cash_box (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  company_id          uuid NOT NULL,
  branch_id           uuid,
  code                text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
  name                text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  kind                text NOT NULL DEFAULT 'main' CHECK (kind IN ('main','pos_drawer','safe','other')),
  currency            char(3) NOT NULL DEFAULT 'IRR' REFERENCES ref.currency(code),
  custodian_user_id   uuid,
  dimension_value_id  uuid,
  allow_negative      boolean NOT NULL DEFAULT false,
  is_active           boolean NOT NULL DEFAULT true,
  created_by          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, custodian_user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, dimension_value_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT cash_box_pos_branch CHECK (kind <> 'pos_drawer' OR branch_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('treasury.cash_box');

-- تنخواه‌گردان: نگه‌دارنده یک شخص (کارمند) است؛ سقف تنخواه (imprest) مبنای درخواست جایگزینی است.
CREATE TABLE IF NOT EXISTS treasury.petty_cash_fund (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid NOT NULL,
  branch_id            uuid,
  code                 text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
  name                 text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  custodian_party_id   uuid NOT NULL,
  custodian_user_id    uuid,
  currency             char(3) NOT NULL DEFAULT 'IRR' REFERENCES ref.currency(code),
  imprest_amount       core.amount NOT NULL CHECK (imprest_amount > 0),
  dimension_value_id   uuid,
  status               text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended','closed')),
  created_by           uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, custodian_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, custodian_user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, dimension_value_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('treasury.petty_cash_fund');

-- پایانهٔ کارتخوان (دستگاه PSP؛ نوع بُعد «pos_terminal» در دفتر کل). با pos.terminal (ایستگاه صندوق) فرق دارد.
CREATE TABLE IF NOT EXISTS treasury.card_terminal (
  tenant_id                   uuid NOT NULL REFERENCES core.tenant(id),
  id                          uuid NOT NULL DEFAULT uuidv7(),
  company_id                  uuid NOT NULL,
  branch_id                   uuid,
  psp_code                    text NOT NULL REFERENCES ref.psp(code),
  terminal_no                 text NOT NULL CHECK (terminal_no ~ '^[0-9A-Za-z]{4,16}$'),
  merchant_no                 text CHECK (merchant_no ~ '^[0-9A-Za-z]{4,20}$'),
  name                        text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  settlement_bank_account_id  uuid NOT NULL,
  connection                  text NOT NULL DEFAULT 'standalone' CHECK (connection IN ('standalone','pc_pos','android_integrated')),
  split_rules                 jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(split_rules) = 'array'),
  tax_file_linked             boolean NOT NULL DEFAULT false,
  dimension_value_id          uuid,
  is_active                   boolean NOT NULL DEFAULT true,
  created_by                  uuid,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  row_version                 integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, psp_code, terminal_no),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, settlement_bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, dimension_value_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('treasury.card_terminal');

-- حساب درگاه پرداخت خودِ مستأجر (پول مشتریان مستأجر هرگز از درگاه حساب‌کتاب عبور نمی‌کند).
-- اعتبارنامه فقط مهروموم‌شده (envelope؛ KeyManager) است و hk_readonly آن را نمی‌بیند.
CREATE TABLE IF NOT EXISTS treasury.gateway_account (
  tenant_id                   uuid NOT NULL REFERENCES core.tenant(id),
  id                          uuid NOT NULL DEFAULT uuidv7(),
  company_id                  uuid NOT NULL,
  code                        text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
  name                        text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  provider_code               text NOT NULL REFERENCES treasury.gateway_provider(code),
  mode                        text NOT NULL DEFAULT 'live' CHECK (mode IN ('sandbox','live')),
  merchant_public_ref         text CHECK (char_length(merchant_public_ref) BETWEEN 1 AND 100),
  credentials_sealed          bytea NOT NULL CHECK (octet_length(credentials_sealed) BETWEEN 16 AND 16384),
  credentials_key_ref         text NOT NULL CHECK (credentials_key_ref ~ '^[a-z][a-z0-9:._/-]{2,200}$'),
  callback_base_url           text NOT NULL CHECK (callback_base_url ~ '^https://[A-Za-z0-9.-]+(:[0-9]{2,5})?(/[A-Za-z0-9._~/-]*)?$'),
  settlement_bank_account_id  uuid NOT NULL,
  settles_net_of_fee          boolean NOT NULL DEFAULT true,
  dimension_value_id          uuid,
  is_active                   boolean NOT NULL DEFAULT true,
  created_by                  uuid,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  row_version                 integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, settlement_bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, dimension_value_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('treasury.gateway_account');

-- =====================================================================
-- ۵. اسناد خزانه: دریافت/پرداخت، اقلام باز و تسویه، انتقال وجه، شمارش نقد، تنخواه
-- =====================================================================
-- سند دریافت/پرداخت (چندابزاری). چرخه: draft → posted → cancelled (با سند برگشت). سطرهای ابزار و
-- طرف حساب فقط در draft تغییر می‌کنند. شماره: core.number_next با doc_type = treasury.receipt|treasury.payment.
CREATE TABLE IF NOT EXISTS treasury.money_document (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid NOT NULL,
  branch_id            uuid,
  direction            text NOT NULL CHECK (direction IN ('receipt','payment')),
  doc_date             date NOT NULL,
  party_id             uuid,
  currency             char(3) NOT NULL DEFAULT 'IRR' REFERENCES ref.currency(code),
  total_amount         core.amount NOT NULL CHECK (total_amount > 0),
  status               text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','cancelled')),
  number_issued_id     uuid,
  doc_no               text CHECK (char_length(doc_no) BETWEEN 1 AND 100),
  journal_id           uuid,
  cancel_journal_id    uuid,
  cancelled_at         timestamptz,
  cancel_reason        text,
  origin               text NOT NULL DEFAULT 'manual'
                       CHECK (origin IN ('manual','pos','gateway','statement','migration','payroll','api','petty_cash','assistant')),
  origin_ref           uuid,
  input_amount_unit    core.amount_unit,
  description          text,
  approval_request_id  uuid,
  posted_by            uuid,
  posted_at            timestamptz,
  created_by           uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, cancel_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, approval_request_id) REFERENCES core.approval_request(tenant_id, id),
  FOREIGN KEY (tenant_id, posted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT money_doc_posted_cols CHECK ((status IN ('posted','cancelled'))
        = (journal_id IS NOT NULL AND number_issued_id IS NOT NULL AND doc_no IS NOT NULL AND posted_at IS NOT NULL)),
  CONSTRAINT money_doc_cancel_cols CHECK ((status = 'cancelled')
        = (cancel_journal_id IS NOT NULL AND cancelled_at IS NOT NULL AND char_length(btrim(coalesce(cancel_reason, ''))) >= 5)),
  CONSTRAINT money_doc_cancel_distinct CHECK (cancel_journal_id IS NULL OR cancel_journal_id <> journal_id),
  CONSTRAINT money_doc_input_unit CHECK (origin NOT IN ('api','migration') OR input_amount_unit IS NOT NULL),
  CONSTRAINT money_doc_origin_ref CHECK (origin IN ('manual','api','assistant','migration') OR origin_ref IS NOT NULL)
);
SELECT core.enable_tenant_rls('treasury.money_document');
CREATE UNIQUE INDEX IF NOT EXISTS money_document_number_uq ON treasury.money_document (tenant_id, number_issued_id)
  WHERE number_issued_id IS NOT NULL;
-- یک سند زنده به ازای هر مبدأ خودکار (رسید صندوق، پرداخت درگاه، سطر صورتحساب): idempotency ساختاری
CREATE UNIQUE INDEX IF NOT EXISTS money_document_origin_uq ON treasury.money_document (tenant_id, origin, origin_ref)
  WHERE origin_ref IS NOT NULL AND status <> 'cancelled';
CREATE INDEX IF NOT EXISTS money_document_party_idx ON treasury.money_document (tenant_id, party_id, doc_date);
CREATE INDEX IF NOT EXISTS money_document_date_idx ON treasury.money_document (tenant_id, company_id, doc_date);

-- اقلام باز طرف‌حساب (زیردفتر تسویه). فاکتور فروش/خرید، برگشتی، رسید و پرداخت هر کدام یک قلم‌اند؛
-- direction اثر در حساب شخص است (debit = بدهی شخص به ما بیشتر/طلب ما کمتر). sales، purchase، payroll و خود treasury
-- اقلام را از راه OpenItemService.register در همان تراکنش ثبت سند مبدأ درج می‌کنند.
CREATE TABLE IF NOT EXISTS treasury.open_item (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  company_id        uuid NOT NULL,
  branch_id         uuid,
  party_id          uuid NOT NULL,
  party_role        text NOT NULL CHECK (party_role IN ('customer','supplier','employee','other')),
  account_class     text NOT NULL CHECK (account_class IN ('receivable','payable')),
  direction         text NOT NULL CHECK (direction IN ('debit','credit')),
  source_module     text NOT NULL CHECK (source_module ~ '^[a-z][a-z0-9_]{1,30}$'),
  source_doc_type   text NOT NULL CHECK (source_doc_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  source_doc_id     uuid NOT NULL,
  source_doc_no     text,
  source_line_key   text NOT NULL DEFAULT 'main' CHECK (source_line_key ~ '^[a-z0-9][a-z0-9:._-]{0,59}$'),
  doc_date          date NOT NULL,
  due_date          date NOT NULL,
  currency          char(3) NOT NULL REFERENCES ref.currency(code),
  amount            core.amount NOT NULL CHECK (amount > 0),
  amount_base       core.amount NOT NULL CHECK (amount_base > 0),
  allocated_amount  core.amount NOT NULL DEFAULT 0 CHECK (allocated_amount >= 0),
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed','cancelled')),
  journal_id        uuid,
  cancelled_at      timestamptz,
  cancel_reason     text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  CONSTRAINT open_item_allocated CHECK (allocated_amount <= amount),
  CONSTRAINT open_item_status CHECK (status = 'cancelled' OR (status = 'closed') = (allocated_amount = amount)),
  CONSTRAINT open_item_cancel CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)
                                     AND (status <> 'cancelled' OR allocated_amount = 0)),
  CONSTRAINT open_item_due CHECK (due_date >= doc_date)
);
SELECT core.enable_tenant_rls('treasury.open_item');
CREATE UNIQUE INDEX IF NOT EXISTS open_item_source_uq ON treasury.open_item
  (tenant_id, source_module, source_doc_type, source_doc_id, source_line_key) WHERE status <> 'cancelled';
CREATE INDEX IF NOT EXISTS open_item_party_open_idx ON treasury.open_item (tenant_id, company_id, party_id, due_date)
  WHERE status = 'open';

-- تسویه (تخصیص): جفت کردن یک قلم بدهکار با یک قلم بستانکار. فقط درج یا «برگشت» (active → reversed).
CREATE TABLE IF NOT EXISTS treasury.allocation (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  debit_item_id    uuid NOT NULL,
  credit_item_id   uuid NOT NULL,
  amount           core.amount NOT NULL CHECK (amount > 0),
  currency         char(3) NOT NULL REFERENCES ref.currency(code),
  allocation_date  date NOT NULL,
  kind             text NOT NULL DEFAULT 'normal' CHECK (kind IN ('normal','offset')),
  journal_id       uuid,
  source           text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','auto','pos','gateway','statement','migration','payroll')),
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active','reversed')),
  reversed_at      timestamptz,
  reversed_by      uuid,
  reverse_reason   text,
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, debit_item_id) REFERENCES treasury.open_item(tenant_id, id),
  FOREIGN KEY (tenant_id, credit_item_id) REFERENCES treasury.open_item(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, reversed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT allocation_distinct CHECK (debit_item_id <> credit_item_id),
  CONSTRAINT allocation_reversed CHECK ((status = 'reversed') = (reversed_at IS NOT NULL)
                                       AND (status <> 'reversed' OR char_length(btrim(coalesce(reverse_reason, ''))) >= 5)),
  CONSTRAINT allocation_offset_journal CHECK (kind <> 'offset' OR journal_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('treasury.allocation');
CREATE INDEX IF NOT EXISTS allocation_debit_idx ON treasury.allocation (tenant_id, debit_item_id) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS allocation_credit_idx ON treasury.allocation (tenant_id, credit_item_id) WHERE status = 'active';

-- انتقال وجه داخلی بین صندوق، بانک و تنخواه (واریز نقد به بانک، برداشت، جایگزینی تنخواه، تخلیهٔ کشوی صندوق).
-- via_in_transit: دو مرحله (ارسال ← «وجوه در راه» ← دریافت). draft → sent → posted یا draft → posted؛ لغو با سند برگشت.
CREATE TABLE IF NOT EXISTS treasury.fund_transfer (
  tenant_id                uuid NOT NULL REFERENCES core.tenant(id),
  id                       uuid NOT NULL DEFAULT uuidv7(),
  company_id               uuid NOT NULL,
  branch_id                uuid,
  doc_date                 date NOT NULL,
  amount                   core.amount NOT NULL CHECK (amount > 0),
  currency                 char(3) NOT NULL DEFAULT 'IRR' REFERENCES ref.currency(code),
  fee_amount               core.amount NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
  from_cash_box_id         uuid,
  from_bank_account_id     uuid,
  from_petty_cash_fund_id  uuid,
  to_cash_box_id           uuid,
  to_bank_account_id       uuid,
  to_petty_cash_fund_id    uuid,
  purpose                  text NOT NULL DEFAULT 'transfer'
                           CHECK (purpose IN ('transfer','deposit_cash','withdraw_cash','petty_replenish','pos_drop','pos_float')),
  transfer_method          text CHECK (transfer_method IN ('internal','paya','satna','pol','card_to_card','cash','unknown')),
  reference_no             text CHECK (char_length(reference_no) BETWEEN 1 AND 40),
  via_in_transit           boolean NOT NULL DEFAULT false,
  received_date            date,
  status                   text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','posted','cancelled')),
  number_issued_id         uuid,
  doc_no                   text,
  journal_id               uuid,
  receive_journal_id       uuid,
  cancel_journal_id        uuid,
  cancel_reason            text,
  origin                   text NOT NULL DEFAULT 'manual' CHECK (origin IN ('manual','pos','statement','migration','api')),
  origin_ref               uuid,
  description              text,
  created_by               uuid,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  row_version              integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, from_cash_box_id) REFERENCES treasury.cash_box(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, from_bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, from_petty_cash_fund_id) REFERENCES treasury.petty_cash_fund(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, to_cash_box_id) REFERENCES treasury.cash_box(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, to_bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, to_petty_cash_fund_id) REFERENCES treasury.petty_cash_fund(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, receive_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, cancel_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT fund_transfer_one_source CHECK (num_nonnulls(from_cash_box_id, from_bank_account_id, from_petty_cash_fund_id) = 1),
  CONSTRAINT fund_transfer_one_target CHECK (num_nonnulls(to_cash_box_id, to_bank_account_id, to_petty_cash_fund_id) = 1),
  CONSTRAINT fund_transfer_not_self CHECK ((from_cash_box_id IS DISTINCT FROM to_cash_box_id OR from_cash_box_id IS NULL)
        AND (from_bank_account_id IS DISTINCT FROM to_bank_account_id OR from_bank_account_id IS NULL)
        AND (from_petty_cash_fund_id IS DISTINCT FROM to_petty_cash_fund_id OR from_petty_cash_fund_id IS NULL)),
  CONSTRAINT fund_transfer_fee CHECK (fee_amount < amount),
  CONSTRAINT fund_transfer_posted CHECK ((status IN ('sent','posted','cancelled')) = (journal_id IS NOT NULL AND number_issued_id IS NOT NULL)),
  CONSTRAINT fund_transfer_transit CHECK ((via_in_transit OR status <> 'sent')
        AND (via_in_transit OR receive_journal_id IS NULL)
        AND (NOT via_in_transit OR status NOT IN ('posted') OR (receive_journal_id IS NOT NULL AND received_date IS NOT NULL))),
  CONSTRAINT fund_transfer_cancel CHECK ((status = 'cancelled') = (cancel_journal_id IS NOT NULL AND cancel_reason IS NOT NULL)),
  CONSTRAINT fund_transfer_petty CHECK (purpose <> 'petty_replenish' OR to_petty_cash_fund_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('treasury.fund_transfer');
CREATE UNIQUE INDEX IF NOT EXISTS fund_transfer_origin_uq ON treasury.fund_transfer (tenant_id, origin, origin_ref)
  WHERE origin_ref IS NOT NULL AND status <> 'cancelled';

-- شمارش نقد (بستن شیفت صندوق یا شمارش دوره‌ای صندوق). اختلاف = شمارش‌شده − مورد انتظار؛ سند کسری/اضافه
-- با کلید treasury.cash_over_short. source_ref شناسهٔ شیفت pos است (بدون FK؛ pos بالادست است و خودش FK دارد).
CREATE TABLE IF NOT EXISTS treasury.cash_count (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  cash_box_id      uuid NOT NULL,
  counted_at       timestamptz NOT NULL,
  business_date    date NOT NULL,
  expected_amount  core.amount NOT NULL,
  counted_amount   core.amount NOT NULL CHECK (counted_amount >= 0),
  difference       core.amount GENERATED ALWAYS AS (counted_amount - expected_amount) STORED,
  denominations    jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(denominations) = 'array'),
  source           text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','pos_shift')),
  source_ref       uuid,
  status           text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted')),
  journal_id       uuid,
  counted_by       uuid,
  approved_by      uuid,
  note             text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, cash_box_id) REFERENCES treasury.cash_box(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, counted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, approved_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT cash_count_source CHECK ((source = 'pos_shift') = (source_ref IS NOT NULL)),
  CONSTRAINT cash_count_posted CHECK (status <> 'posted' OR counted_amount = expected_amount OR journal_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('treasury.cash_count');
CREATE UNIQUE INDEX IF NOT EXISTS cash_count_source_uq ON treasury.cash_count (tenant_id, source, source_ref) WHERE source_ref IS NOT NULL;

-- صورت‌خرج تنخواه: draft → submitted → approved → posted (یا rejected/cancelled). تأییدکننده ≠ ارسال‌کننده.
CREATE TABLE IF NOT EXISTS treasury.petty_cash_claim (
  tenant_id                   uuid NOT NULL REFERENCES core.tenant(id),
  id                          uuid NOT NULL DEFAULT uuidv7(),
  company_id                  uuid NOT NULL,
  fund_id                     uuid NOT NULL,
  claim_date                  date NOT NULL,
  total_amount                core.amount NOT NULL CHECK (total_amount > 0),
  status                      text NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft','submitted','approved','posted','rejected','cancelled')),
  submitted_by                uuid,
  submitted_at                timestamptz,
  approved_by                 uuid,
  approved_at                 timestamptz,
  approval_request_id         uuid,
  number_issued_id            uuid,
  doc_no                      text,
  journal_id                  uuid,
  replenished_by_transfer_id  uuid,
  reject_reason               text,
  note                        text,
  created_by                  uuid,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  row_version                 integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, fund_id) REFERENCES treasury.petty_cash_fund(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, submitted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, approved_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, approval_request_id) REFERENCES core.approval_request(tenant_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, replenished_by_transfer_id) REFERENCES treasury.fund_transfer(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT petty_claim_submitted CHECK (status IN ('draft','cancelled') OR (submitted_by IS NOT NULL AND submitted_at IS NOT NULL)),
  CONSTRAINT petty_claim_approved CHECK (status NOT IN ('approved','posted') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
  CONSTRAINT petty_claim_sod CHECK (approved_by IS NULL OR approved_by <> submitted_by),
  CONSTRAINT petty_claim_posted CHECK ((status = 'posted') = (journal_id IS NOT NULL AND number_issued_id IS NOT NULL)),
  CONSTRAINT petty_claim_rejected CHECK ((status = 'rejected') = (reject_reason IS NOT NULL)),
  CONSTRAINT petty_claim_replenish CHECK (replenished_by_transfer_id IS NULL OR status = 'posted')
);
SELECT core.enable_tenant_rls('treasury.petty_cash_claim');

CREATE TABLE IF NOT EXISTS treasury.petty_cash_claim_line (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  claim_id              uuid NOT NULL,
  line_no               smallint NOT NULL CHECK (line_no BETWEEN 1 AND 500),
  expense_date          date NOT NULL,
  description           text NOT NULL CHECK (description = core.fa_normalize_text(description) AND char_length(description) BETWEEN 1 AND 500),
  amount                core.amount NOT NULL CHECK (amount > 0),
  vat_amount            core.amount NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
  posting_key           text REFERENCES ledger.posting_key(key),
  account_id            uuid,
  cost_center_value_id  uuid,
  project_value_id      uuid,
  vendor_party_id       uuid,
  attachment_id         uuid,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, claim_id, line_no),
  FOREIGN KEY (tenant_id, claim_id) REFERENCES treasury.petty_cash_claim(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, account_id) REFERENCES ledger.account(tenant_id, id),
  FOREIGN KEY (tenant_id, cost_center_value_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, project_value_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, vendor_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, attachment_id) REFERENCES core.attachment(tenant_id, id),
  CONSTRAINT petty_line_account CHECK (num_nonnulls(posting_key, account_id) = 1),
  CONSTRAINT petty_line_vat CHECK (vat_amount < amount)
);
SELECT core.enable_tenant_rls('treasury.petty_cash_claim_line');

-- =====================================================================
-- ۶. چک: دسته‌چک، برگ، چک، رویداد (ماشین حالت)، استعلام صیاد، قالب و لاگ چاپ
-- =====================================================================
CREATE TABLE IF NOT EXISTS treasury.cheque_book (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  bank_account_id  uuid NOT NULL,
  medium           text NOT NULL CHECK (medium IN ('paper','electronic')),
  series           text NOT NULL CHECK (series ~ '^[0-9A-Za-z/-]{1,20}$'),
  serial_from      bigint NOT NULL CHECK (serial_from >= 0),
  serial_to        bigint NOT NULL,
  received_on      date NOT NULL,
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active','exhausted','cancelled')),
  note             text,
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT cheque_book_range CHECK (serial_to >= serial_from AND serial_to - serial_from < 500),
  CONSTRAINT cheque_book_no_overlap EXCLUDE USING gist (tenant_id WITH =, bank_account_id WITH =, series WITH =,
                                                        int8range(serial_from, serial_to, '[]') WITH &&)
);
SELECT core.enable_tenant_rls('treasury.cheque_book');

-- برگ دسته‌چک: unused → issued | void (P5) | lost (P6)؛ issued → unused فقط وقتی چکِ آن ابطال ثبت شده است.
CREATE TABLE IF NOT EXISTS treasury.cheque_leaf (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  cheque_book_id    uuid NOT NULL,
  serial_no         bigint NOT NULL,
  sayad_id          text CHECK (sayad_id ~ '^[0-9]{16}$'),
  state             text NOT NULL DEFAULT 'unused' CHECK (state IN ('unused','issued','void','lost')),
  state_reason      text,
  state_changed_at  timestamptz,
  state_changed_by  uuid,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, cheque_book_id, serial_no),
  FOREIGN KEY (tenant_id, cheque_book_id) REFERENCES treasury.cheque_book(tenant_id, id),
  FOREIGN KEY (tenant_id, state_changed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT cheque_leaf_reason CHECK (state NOT IN ('void','lost') OR char_length(btrim(coalesce(state_reason, ''))) >= 3)
);
SELECT core.enable_tenant_rls('treasury.cheque_leaf');
CREATE UNIQUE INDEX IF NOT EXISTS cheque_leaf_sayad_uq ON treasury.cheque_leaf (tenant_id, sayad_id) WHERE sayad_id IS NOT NULL;

-- چک. وضعیت حسابداری (state) فقط از راه درج رویداد در cheque_event عوض می‌شود. وضعیت صیاد (sayad_state)
-- بُعد جداگانه است. مبلغ، شناسه، سررسید و طرفین پس از درج تغییرناپذیرند (تغییر سررسید = تعویض/R8 یا R11+R1).
CREATE TABLE IF NOT EXISTS treasury.cheque (
  tenant_id                 uuid NOT NULL REFERENCES core.tenant(id),
  id                        uuid NOT NULL DEFAULT uuidv7(),
  company_id                uuid NOT NULL,
  branch_id                 uuid,
  direction                 text NOT NULL CHECK (direction IN ('received','issued')),
  purpose                   text NOT NULL DEFAULT 'payment' CHECK (purpose IN ('payment','guarantee')),
  state                     text NOT NULL,
  last_event_seq            integer NOT NULL DEFAULT 0 CHECK (last_event_seq >= 0),
  sayad_unique              boolean NOT NULL DEFAULT true,
  medium                    text NOT NULL CHECK (medium IN ('paper','electronic')),
  instrument                text NOT NULL DEFAULT 'personal' CHECK (instrument IN ('personal','certified','bank_cheque')),
  sayad_id                  text CHECK (sayad_id ~ '^[0-9]{16}$'),
  serial_no                 text CHECK (serial_no ~ '^[0-9A-Za-z/-]{1,30}$'),
  series                    text CHECK (series ~ '^[0-9A-Za-z/-]{1,20}$'),
  is_legacy                 boolean NOT NULL DEFAULT false,
  amount                    core.amount NOT NULL CHECK (amount > 0),
  currency                  char(3) NOT NULL DEFAULT 'IRR' REFERENCES ref.currency(code),
  amount_base               core.amount NOT NULL CHECK (amount_base > 0),
  issue_date                date,
  due_date                  date NOT NULL,
  reason_text               text CHECK (reason_text = core.fa_normalize_text(reason_text) AND char_length(reason_text) <= 300),
  drawer_party_id           uuid,
  drawer_name               text CHECK (drawer_name = core.fa_normalize_text(drawer_name) AND char_length(drawer_name) BETWEEN 1 AND 300),
  drawer_national_id        text CHECK (drawer_national_id ~ '^[0-9]{10,12}$'),
  drawer_bank_code          text REFERENCES ref.bank(code),
  drawer_branch_code        text CHECK (drawer_branch_code ~ '^[0-9]{1,6}$'),
  drawer_account_no         text CHECK (drawer_account_no ~ '^[0-9][0-9./-]{2,30}$'),
  drawer_sheba              text CHECK (drawer_sheba IS NULL OR ref.is_valid_sheba(drawer_sheba)),
  received_from_party_id    uuid,
  bank_account_id           uuid,
  cheque_leaf_id            uuid,
  payee_party_id            uuid,
  payee_name                text CHECK (payee_name = core.fa_normalize_text(payee_name) AND char_length(payee_name) BETWEEN 1 AND 300),
  payee_national_id         text CHECK (payee_national_id ~ '^[0-9]{10,12}$'),
  collected_amount          core.amount NOT NULL DEFAULT 0 CHECK (collected_amount >= 0),
  deposit_bank_account_id   uuid,
  endorsee_party_id         uuid,
  is_long_term              boolean NOT NULL DEFAULT false,
  sayad_state               text NOT NULL,
  sayad_color_code          text REFERENCES ref.sayad_credit_status(code),
  sayad_inquired_at         timestamptz,
  legal_status              text NOT NULL DEFAULT 'none' CHECK (legal_status IN ('none','certificate_issued','execution_filed','settled')),
  converted_from_cheque_id  uuid,
  replaces_cheque_id        uuid,
  origin                    text NOT NULL CHECK (origin IN ('manual','receipt','payment','pos','migration','opening')),
  money_document_id         uuid,
  note                      text,
  created_by                uuid,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  row_version               integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (direction, purpose, state) REFERENCES treasury.cheque_state(direction, purpose, state),
  FOREIGN KEY (tenant_id, drawer_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, received_from_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, payee_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, endorsee_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, deposit_bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, cheque_leaf_id) REFERENCES treasury.cheque_leaf(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, converted_from_cheque_id) REFERENCES treasury.cheque(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, replaces_cheque_id) REFERENCES treasury.cheque(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, money_document_id) REFERENCES treasury.money_document(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT cheque_sayad_or_legacy CHECK (sayad_id IS NOT NULL OR is_legacy),
  CONSTRAINT cheque_collected CHECK (collected_amount <= amount),
  CONSTRAINT cheque_collected_state CHECK (state <> 'collected' OR direction <> 'received' OR collected_amount = amount),
  CONSTRAINT cheque_partial_state CHECK (state <> 'partially_collected' OR (collected_amount > 0 AND collected_amount < amount)),
  CONSTRAINT cheque_deposited_bank CHECK (state <> 'deposited' OR deposit_bank_account_id IS NOT NULL),
  CONSTRAINT cheque_endorsed_party CHECK (state NOT IN ('endorsed','returned_by_third_party') OR endorsee_party_id IS NOT NULL),
  CONSTRAINT cheque_issued_shape CHECK (direction = 'received'
        OR (bank_account_id IS NOT NULL AND drawer_party_id IS NULL AND received_from_party_id IS NULL
            AND deposit_bank_account_id IS NULL AND endorsee_party_id IS NULL AND sayad_color_code IS NULL)),
  CONSTRAINT cheque_received_shape CHECK (direction = 'issued'
        OR (bank_account_id IS NULL AND cheque_leaf_id IS NULL AND payee_party_id IS NULL)),
  -- چک صیادی در وجه حامل ممنوع است: چک صادرهٔ غیرقدیمی باید ذی‌نفع مشخص داشته باشد
  CONSTRAINT cheque_no_bearer CHECK (direction = 'received' OR is_legacy OR payee_party_id IS NOT NULL OR payee_national_id IS NOT NULL),
  CONSTRAINT cheque_received_from CHECK (direction = 'issued' OR received_from_party_id IS NOT NULL OR origin IN ('migration','opening')),
  CONSTRAINT cheque_issued_leaf CHECK (direction = 'received' OR is_legacy OR origin IN ('migration','opening') OR cheque_leaf_id IS NOT NULL),
  CONSTRAINT cheque_sayad_state CHECK (
        (direction = 'received' AND sayad_state IN ('not_inquired','inquired','accepted','transferred','rejected','legacy'))
     OR (direction = 'issued'   AND sayad_state IN ('not_registered','registered','accepted_by_payee','transferred_by_payee','legacy'))),
  CONSTRAINT cheque_sayad_legacy CHECK ((sayad_state = 'legacy') <= is_legacy),
  CONSTRAINT cheque_color_pair CHECK ((sayad_color_code IS NULL) = (sayad_inquired_at IS NULL)),
  CONSTRAINT cheque_dates CHECK (issue_date IS NULL OR due_date >= issue_date),
  CONSTRAINT cheque_conversion CHECK (converted_from_cheque_id IS NULL OR (purpose = 'payment' AND converted_from_cheque_id <> id)),
  CONSTRAINT cheque_replaces CHECK (replaces_cheque_id IS NULL OR (replaces_cheque_id <> id AND direction = 'received')),
  CONSTRAINT cheque_base_currency CHECK (currency <> 'IRR' OR amount_base = amount)
);
SELECT core.enable_tenant_rls('treasury.cheque');
-- یکتایی صیاد فقط روی چک‌های «فعال» هر جهت (چک خرج‌شده ممکن است دوباره از شخص دیگری برگردد)
CREATE UNIQUE INDEX IF NOT EXISTS cheque_sayad_active_uq ON treasury.cheque (tenant_id, direction, sayad_id)
  WHERE sayad_id IS NOT NULL AND sayad_unique;
-- هر برگ دسته‌چک حداکثر یک چک صادرهٔ ابطال‌نشده
CREATE UNIQUE INDEX IF NOT EXISTS cheque_leaf_active_uq ON treasury.cheque (tenant_id, cheque_leaf_id)
  WHERE cheque_leaf_id IS NOT NULL AND state <> 'cancelled';
CREATE INDEX IF NOT EXISTS cheque_due_idx ON treasury.cheque (tenant_id, company_id, direction, due_date) WHERE sayad_unique;
CREATE INDEX IF NOT EXISTS cheque_party_idx ON treasury.cheque (tenant_id, received_from_party_id);
CREATE INDEX IF NOT EXISTS cheque_payee_idx ON treasury.cheque (tenant_id, payee_party_id);

-- رویداد چک (فقط‌افزودنی). seq پیوسته برای هر چک. *_after = وضعیت پس از رویداد. holding_* = حساب، بُعد و مبلغی که
-- ارزش چک پس از رویداد در آن نشسته است (مبنای تابع زیردفتر ledger.check_control_accounts).
CREATE TABLE IF NOT EXISTS treasury.cheque_event (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  cheque_id              uuid NOT NULL,
  seq                    integer NOT NULL CHECK (seq >= 1),
  kind                   text NOT NULL CHECK (kind IN ('transition','undo')),
  transition_code        text REFERENCES treasury.cheque_transition(code),
  undoes_event_id        uuid,
  from_state             text,
  to_state               text NOT NULL,
  event_date             date NOT NULL,
  amount                 core.amount CHECK (amount > 0),
  bank_account_id        uuid,
  cash_box_id            uuid,
  counterparty_party_id  uuid,
  collected_after        core.amount NOT NULL CHECK (collected_after >= 0),
  deposit_bank_after     uuid,
  endorsee_after         uuid,
  long_term_after        boolean NOT NULL,
  holding_account_id     uuid,
  holding_dim_value_id   uuid,
  holding_amount         core.amount CHECK (holding_amount > 0),
  holding_amount_base    core.amount CHECK (holding_amount_base > 0),
  journal_id             uuid,
  money_document_id      uuid,
  statement_line_id      uuid,
  related_cheque_id      uuid,
  reason                 text,
  actor_id               uuid,
  created_at             timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, cheque_id, seq),
  FOREIGN KEY (tenant_id, cheque_id) REFERENCES treasury.cheque(tenant_id, id),
  FOREIGN KEY (tenant_id, undoes_event_id) REFERENCES treasury.cheque_event(tenant_id, id),
  FOREIGN KEY (tenant_id, bank_account_id) REFERENCES treasury.bank_account(tenant_id, id),
  FOREIGN KEY (tenant_id, cash_box_id) REFERENCES treasury.cash_box(tenant_id, id),
  FOREIGN KEY (tenant_id, counterparty_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, deposit_bank_after) REFERENCES treasury.bank_account(tenant_id, id),
  FOREIGN KEY (tenant_id, endorsee_after) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, holding_account_id) REFERENCES ledger.account(tenant_id, id),
  FOREIGN KEY (tenant_id, holding_dim_value_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, journal_id) REFERENCES ledger.journal(tenant_id, id),
  FOREIGN KEY (tenant_id, money_document_id) REFERENCES treasury.money_document(tenant_id, id),
  FOREIGN KEY (tenant_id, related_cheque_id) REFERENCES treasury.cheque(tenant_id, id),
  FOREIGN KEY (tenant_id, actor_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT cheque_event_kind CHECK ((kind = 'transition') = (transition_code IS NOT NULL)
                                      AND (kind = 'undo') = (undoes_event_id IS NOT NULL)),
  CONSTRAINT cheque_event_holding CHECK ((holding_amount IS NULL) = (holding_account_id IS NULL)
                                         AND (holding_amount IS NULL) = (holding_amount_base IS NULL)
                                         AND (holding_dim_value_id IS NULL OR holding_account_id IS NOT NULL)),
  CONSTRAINT cheque_event_fund CHECK (num_nonnulls(bank_account_id, cash_box_id) <= 1)
);
SELECT core.enable_tenant_rls('treasury.cheque_event');
CREATE UNIQUE INDEX IF NOT EXISTS cheque_event_undo_once_uq ON treasury.cheque_event (tenant_id, undoes_event_id)
  WHERE undoes_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS cheque_event_journal_idx ON treasury.cheque_event (tenant_id, journal_id) WHERE journal_id IS NOT NULL;

-- استعلام صیاد (فقط‌افزودنی): رنگ و تاریخ، دستی یا از فین‌تک. آخرین استعلام روی چک نگه داشته می‌شود.
CREATE TABLE IF NOT EXISTS treasury.cheque_sayad_inquiry (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  cheque_id        uuid NOT NULL,
  inquired_at      timestamptz NOT NULL,
  color_code       text NOT NULL REFERENCES ref.sayad_credit_status(code),
  channel          text NOT NULL CHECK (channel IN ('manual','provider')),
  provider         text,
  provider_ref     text CHECK (char_length(provider_ref) <= 64),
  details_matched  boolean,
  note             text,
  actor_id         uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, cheque_id) REFERENCES treasury.cheque(tenant_id, id),
  FOREIGN KEY (tenant_id, actor_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT sayad_inquiry_provider CHECK ((channel = 'provider') = (provider IS NOT NULL))
);
SELECT core.enable_tenant_rls('treasury.cheque_sayad_inquiry');

-- قالب چاپ چک (میلی‌متر از گوشهٔ بالا-راست برگ). layout: [{field, x_mm, y_mm, w_mm, font_pt, align}]
CREATE TABLE IF NOT EXISTS treasury.cheque_print_template (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  code             text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
  name             text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  bank_code        text REFERENCES ref.bank(code),
  medium           text NOT NULL DEFAULT 'paper' CHECK (medium IN ('paper','electronic')),
  page_width_mm    numeric(6,2) NOT NULL CHECK (page_width_mm BETWEEN 50 AND 300),
  page_height_mm   numeric(6,2) NOT NULL CHECK (page_height_mm BETWEEN 30 AND 300),
  layout           jsonb NOT NULL CHECK (jsonb_typeof(layout) = 'array' AND jsonb_array_length(layout) >= 1),
  is_default       boolean NOT NULL DEFAULT false,
  is_active        boolean NOT NULL DEFAULT true,
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  -- هر فیلد قالب از فهرست مجاز و دارای مختصات
  CONSTRAINT cheque_print_layout_fields CHECK (NOT jsonb_path_exists(layout,
    '$[*] ? (!(@.field == "date_digits" || @.field == "date_words" || @.field == "amount_digits" || @.field == "amount_words" || @.field == "payee_name" || @.field == "payee_national_id" || @.field == "reason" || @.field == "sayad_id" || @.field == "drawer_signature_box") || !exists(@.x_mm) || !exists(@.y_mm))'))
);
SELECT core.enable_tenant_rls('treasury.cheque_print_template');
CREATE UNIQUE INDEX IF NOT EXISTS cheque_print_template_default_uq ON treasury.cheque_print_template (tenant_id, bank_code, medium)
  NULLS NOT DISTINCT WHERE is_default AND is_active;

CREATE TABLE IF NOT EXISTS treasury.cheque_print_log (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  cheque_id        uuid NOT NULL,
  template_id      uuid NOT NULL,
  copies           smallint NOT NULL DEFAULT 1 CHECK (copies BETWEEN 1 AND 5),
  rendered_sha256  bytea NOT NULL CHECK (octet_length(rendered_sha256) = 32),
  printed_by       uuid,
  printed_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, cheque_id) REFERENCES treasury.cheque(tenant_id, id),
  FOREIGN KEY (tenant_id, template_id) REFERENCES treasury.cheque_print_template(tenant_id, id),
  FOREIGN KEY (tenant_id, printed_by) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('treasury.cheque_print_log');

-- =====================================================================
-- ۷. کارتخوان: تراکنش، تسویهٔ شاپرک، بستن روز پایانه
-- =====================================================================
-- RRN (ISO 8583 فیلد ۳۷، an 12) و STAN (فیلد ۱۱، n 6) همیشه رشته‌اند.
CREATE TABLE IF NOT EXISTS treasury.card_txn (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  company_id         uuid NOT NULL,
  card_terminal_id   uuid NOT NULL,
  txn_at             timestamptz NOT NULL,
  business_date      date NOT NULL,
  amount             core.amount NOT NULL CHECK (amount > 0),
  status             text NOT NULL DEFAULT 'approved' CHECK (status IN ('approved','reversed','void')),
  rrn                text CHECK (rrn ~ '^[0-9A-Za-z]{1,12}$'),
  stan               text CHECK (stan ~ '^[0-9]{1,6}$'),
  masked_pan         text CHECK (masked_pan IS NULL OR treasury.is_masked_pan(masked_pan)),
  entry_mode         text NOT NULL DEFAULT 'manual' CHECK (entry_mode IN ('integrated','manual','psp_file','statement')),
  source             text NOT NULL CHECK (source IN ('pos','receipt','psp_file','migration')),
  source_ref         uuid,
  money_document_id  uuid,
  settlement_id      uuid,
  settled_at         timestamptz,
  void_reason        text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, card_terminal_id) REFERENCES treasury.card_terminal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, money_document_id) REFERENCES treasury.money_document(tenant_id, company_id, id),
  CONSTRAINT card_txn_settled CHECK ((settlement_id IS NULL) = (settled_at IS NULL)),
  CONSTRAINT card_txn_void CHECK ((status = 'void') = (void_reason IS NOT NULL)),
  CONSTRAINT card_txn_unsettled_void CHECK (status = 'approved' OR settlement_id IS NULL)
);
SELECT core.enable_tenant_rls('treasury.card_txn');
CREATE UNIQUE INDEX IF NOT EXISTS card_txn_rrn_uq ON treasury.card_txn (tenant_id, card_terminal_id, rrn)
  WHERE rrn IS NOT NULL AND status <> 'void';
CREATE UNIQUE INDEX IF NOT EXISTS card_txn_source_uq ON treasury.card_txn (tenant_id, source, source_ref)
  WHERE source_ref IS NOT NULL AND status <> 'void';
CREATE INDEX IF NOT EXISTS card_txn_unsettled_idx ON treasury.card_txn (tenant_id, card_terminal_id, business_date)
  WHERE settlement_id IS NULL AND status = 'approved';

-- تسویهٔ شاپرک: یک واریز تجمیعی پایانه (سطر صورتحساب) در برابر مجموعهٔ تراکنش‌های تسویه‌نشده.
CREATE TABLE IF NOT EXISTS treasury.card_settlement (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  company_id         uuid NOT NULL,
  card_terminal_id   uuid NOT NULL,
  bank_account_id    uuid NOT NULL,
  settlement_date    date NOT NULL,
  gross_amount       core.amount NOT NULL CHECK (gross_amount > 0),
  fee_amount         core.amount NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
  net_amount         core.amount GENERATED ALWAYS AS (gross_amount - fee_amount) STORED,
  matched_by         text NOT NULL CHECK (matched_by IN ('rrn','window','manual')),
  statement_line_id  uuid,
  status             text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','cancelled')),
  journal_id         uuid,
  cancel_journal_id  uuid,
  created_by         uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, card_terminal_id) REFERENCES treasury.card_terminal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, cancel_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT card_settlement_fee CHECK (fee_amount < gross_amount),
  CONSTRAINT card_settlement_posted CHECK ((status IN ('posted','cancelled')) = (journal_id IS NOT NULL)),
  CONSTRAINT card_settlement_cancel CHECK ((status = 'cancelled') = (cancel_journal_id IS NOT NULL))
);
SELECT core.enable_tenant_rls('treasury.card_settlement');
ALTER TABLE treasury.card_txn DROP CONSTRAINT IF EXISTS card_txn_settlement_fk;
ALTER TABLE treasury.card_txn ADD CONSTRAINT card_txn_settlement_fk
  FOREIGN KEY (tenant_id, settlement_id) REFERENCES treasury.card_settlement(tenant_id, id);

-- بستن روز پایانه: جمع گزارش پایان روز دستگاه در برابر جمع دفتری (پژوهش ۰۵ §۲-۵-۲ بند ۲)
CREATE TABLE IF NOT EXISTS treasury.card_day_close (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  card_terminal_id  uuid NOT NULL,
  business_date     date NOT NULL,
  device_total      core.amount NOT NULL CHECK (device_total >= 0),
  device_count      integer NOT NULL CHECK (device_count >= 0),
  book_total        core.amount NOT NULL CHECK (book_total >= 0),
  book_count        integer NOT NULL CHECK (book_count >= 0),
  difference        core.amount GENERATED ALWAYS AS (device_total - book_total) STORED,
  status            text NOT NULL CHECK (status IN ('ok','mismatch','resolved')),
  resolution_note   text,
  closed_by         uuid,
  closed_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, card_terminal_id, business_date),
  FOREIGN KEY (tenant_id, card_terminal_id) REFERENCES treasury.card_terminal(tenant_id, id),
  FOREIGN KEY (tenant_id, closed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT card_day_close_status CHECK ((status = 'ok') = (device_total = book_total AND device_count = book_count)
                                          AND (status <> 'resolved' OR resolution_note IS NOT NULL))
);
SELECT core.enable_tenant_rls('treasury.card_day_close');

-- =====================================================================
-- ۸. درگاه پرداخت مستأجر: پرداخت (لینک فاکتور) و لاگ رخداد
-- =====================================================================
-- ماشین حالت: created → redirected → callback_received → verified | failed | expired | reversed؛ verified → refunded | reversed.
-- کد ۴۸ ملت (و هر پاسخ «reverse شده») = reversed، نه verified؛ فقط ۴۳/۴۵ ملت و ۱۰۱ زرین‌پال «تکراری موفق» است (آداپتر).
CREATE TABLE IF NOT EXISTS treasury.gateway_payment (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  company_id          uuid NOT NULL,
  gateway_account_id  uuid NOT NULL,
  provider_code       text NOT NULL REFERENCES treasury.gateway_provider(code),
  open_item_id        uuid,
  party_id            uuid,
  order_id            text NOT NULL CHECK (order_id ~ '^[A-Za-z0-9_-]{6,64}$'),
  amount              core.amount NOT NULL CHECK (amount > 0 AND amount = trunc(amount)),
  api_amount          numeric(24,0) NOT NULL CHECK (api_amount > 0),
  api_amount_unit     core.amount_unit NOT NULL,
  state               text NOT NULL DEFAULT 'created'
                      CHECK (state IN ('created','redirected','callback_received','verified','failed','expired','reversed','refunded')),
  provider_ref        text CHECK (char_length(provider_ref) BETWEEN 1 AND 100),
  provider_txn_ref    text CHECK (char_length(provider_txn_ref) BETWEEN 1 AND 64),
  card_masked         text CHECK (card_masked IS NULL OR treasury.is_masked_pan(card_masked)),
  card_hash           bytea CHECK (card_hash IS NULL OR octet_length(card_hash) = 32),
  verified_amount     core.amount,
  fee_amount          core.amount CHECK (fee_amount >= 0),
  last_response_code  text CHECK (char_length(last_response_code) <= 32),
  failure_reason      text,
  link_token_hash     bytea UNIQUE CHECK (link_token_hash IS NULL OR octet_length(link_token_hash) = 32),
  expires_at          timestamptz NOT NULL,
  redirected_at       timestamptz,
  callback_at         timestamptz,
  verified_at         timestamptz,
  refunded_at         timestamptz,
  late_verification   boolean NOT NULL DEFAULT false,
  money_document_id   uuid,
  attempts            integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_inquiry_at     timestamptz,
  created_by          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, order_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, gateway_account_id) REFERENCES treasury.gateway_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, open_item_id) REFERENCES treasury.open_item(tenant_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, money_document_id) REFERENCES treasury.money_document(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT gateway_payment_verified CHECK (state NOT IN ('verified','refunded')
        OR (provider_txn_ref IS NOT NULL AND verified_at IS NOT NULL AND verified_amount = amount)),
  CONSTRAINT gateway_payment_no_doc_unless_paid CHECK (money_document_id IS NULL OR state IN ('verified','refunded','reversed')),
  CONSTRAINT gateway_payment_refunded CHECK ((state = 'refunded') = (refunded_at IS NOT NULL)),
  CONSTRAINT gateway_payment_redirect CHECK (state = 'created' OR state IN ('failed','expired') OR provider_ref IS NOT NULL)
);
SELECT core.enable_tenant_rls('treasury.gateway_payment');
-- کلید یکتای ارائه‌دهنده: جلوی اعتبار دوباره با یک تراکنش را می‌گیرد
CREATE UNIQUE INDEX IF NOT EXISTS gateway_payment_provider_ref_uq ON treasury.gateway_payment (tenant_id, provider_code, provider_ref)
  WHERE provider_ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS gateway_payment_provider_txn_uq ON treasury.gateway_payment (tenant_id, provider_code, provider_txn_ref)
  WHERE provider_txn_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS gateway_payment_pending_idx ON treasury.gateway_payment (tenant_id, next_inquiry_at)
  WHERE state IN ('created','redirected','callback_received');

CREATE TABLE IF NOT EXISTS treasury.gateway_event (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  gateway_payment_id  uuid NOT NULL,
  kind                text NOT NULL CHECK (kind IN ('request','redirect','callback','verify','settle','inquiry','reverse','refund')),
  outcome             text NOT NULL CHECK (outcome IN ('success','duplicate_success','failed','reversed','pending','error')),
  provider_code       text NOT NULL REFERENCES treasury.gateway_provider(code),
  response_code       text CHECK (char_length(response_code) <= 32),
  http_status         smallint CHECK (http_status BETWEEN 100 AND 599),
  latency_ms          integer CHECK (latency_ms >= 0),
  request_trace_id    text CHECK (char_length(request_trace_id) <= 64),
  note                text CHECK (char_length(note) <= 1000),
  at                  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, gateway_payment_id) REFERENCES treasury.gateway_payment(tenant_id, id)
);
SELECT core.enable_tenant_rls('treasury.gateway_event');

-- =====================================================================
-- ۹. سطرهای سند دریافت/پرداخت (پس از چک، کارت و درگاه چون به آن‌ها ارجاع دارند)
-- =====================================================================
CREATE TABLE IF NOT EXISTS treasury.money_instrument (
  tenant_id                 uuid NOT NULL REFERENCES core.tenant(id),
  id                        uuid NOT NULL DEFAULT uuidv7(),
  document_id               uuid NOT NULL,
  line_no                   smallint NOT NULL CHECK (line_no BETWEEN 1 AND 500),
  kind                      text NOT NULL CHECK (kind IN ('cash','card_pos','bank_transfer','card_to_card','cheque',
                                                          'cheque_endorse','gateway','petty_cash')),
  amount                    core.amount NOT NULL CHECK (amount > 0),
  cash_box_id               uuid,
  bank_account_id           uuid,
  card_terminal_id          uuid,
  gateway_payment_id        uuid,
  cheque_id                 uuid,
  petty_cash_fund_id        uuid,
  cheque_draft              jsonb CHECK (cheque_draft IS NULL OR jsonb_typeof(cheque_draft) = 'object'),
  transfer_method           text CHECK (transfer_method IN ('internal','paya','satna','pol','card_to_card','unknown')),
  reference_no              text CHECK (char_length(reference_no) BETWEEN 1 AND 40),
  rrn                       text CHECK (rrn ~ '^[0-9A-Za-z]{1,12}$'),
  stan                      text CHECK (stan ~ '^[0-9]{1,6}$'),
  masked_pan                text CHECK (masked_pan IS NULL OR treasury.is_masked_pan(masked_pan)),
  counterparty_sheba        text CHECK (counterparty_sheba IS NULL OR ref.is_valid_sheba(counterparty_sheba)),
  counterparty_card_masked  text CHECK (counterparty_card_masked IS NULL OR treasury.is_masked_pan(counterparty_card_masked)),
  card_txn_id               uuid,
  fee_amount                core.amount NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
  note                      text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, document_id, line_no),
  FOREIGN KEY (tenant_id, document_id) REFERENCES treasury.money_document(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, cash_box_id) REFERENCES treasury.cash_box(tenant_id, id),
  FOREIGN KEY (tenant_id, bank_account_id) REFERENCES treasury.bank_account(tenant_id, id),
  FOREIGN KEY (tenant_id, card_terminal_id) REFERENCES treasury.card_terminal(tenant_id, id),
  FOREIGN KEY (tenant_id, gateway_payment_id) REFERENCES treasury.gateway_payment(tenant_id, id),
  FOREIGN KEY (tenant_id, cheque_id) REFERENCES treasury.cheque(tenant_id, id),
  FOREIGN KEY (tenant_id, petty_cash_fund_id) REFERENCES treasury.petty_cash_fund(tenant_id, id),
  FOREIGN KEY (tenant_id, card_txn_id) REFERENCES treasury.card_txn(tenant_id, id),
  CONSTRAINT instrument_shape CHECK (
       (kind = 'cash'           AND cash_box_id IS NOT NULL
                                AND num_nonnulls(bank_account_id, card_terminal_id, gateway_payment_id, cheque_id, petty_cash_fund_id) = 0)
    OR (kind = 'card_pos'       AND card_terminal_id IS NOT NULL
                                AND num_nonnulls(cash_box_id, bank_account_id, gateway_payment_id, cheque_id, petty_cash_fund_id) = 0)
    OR (kind IN ('bank_transfer','card_to_card') AND bank_account_id IS NOT NULL
                                AND num_nonnulls(cash_box_id, card_terminal_id, gateway_payment_id, cheque_id, petty_cash_fund_id) = 0)
    OR (kind IN ('cheque','cheque_endorse') AND num_nonnulls(cheque_id, cheque_draft) >= 1
                                AND num_nonnulls(cash_box_id, bank_account_id, card_terminal_id, gateway_payment_id, petty_cash_fund_id) = 0)
    OR (kind = 'gateway'        AND gateway_payment_id IS NOT NULL
                                AND num_nonnulls(cash_box_id, bank_account_id, card_terminal_id, cheque_id, petty_cash_fund_id) = 0)
    OR (kind = 'petty_cash'     AND petty_cash_fund_id IS NOT NULL
                                AND num_nonnulls(cash_box_id, bank_account_id, card_terminal_id, gateway_payment_id, cheque_id) = 0)),
  CONSTRAINT instrument_transfer_method CHECK ((transfer_method IS NULL OR kind IN ('bank_transfer','card_to_card'))
                                               AND (kind <> 'card_to_card' OR transfer_method = 'card_to_card')),
  CONSTRAINT instrument_card_refs CHECK ((rrn IS NULL AND stan IS NULL AND masked_pan IS NULL) OR kind IN ('card_pos','gateway','card_to_card')),
  CONSTRAINT instrument_fee CHECK (fee_amount < amount),
  CONSTRAINT instrument_card_txn CHECK (card_txn_id IS NULL OR kind = 'card_pos')
);
SELECT core.enable_tenant_rls('treasury.money_instrument');
CREATE UNIQUE INDEX IF NOT EXISTS money_instrument_gateway_uq ON treasury.money_instrument (tenant_id, gateway_payment_id)
  WHERE gateway_payment_id IS NOT NULL;

-- طرف دیگر سند: شخص (حساب دریافتنی/پرداختنی طبق نقش)، پیش‌دریافت/پیش‌پرداخت، حساب صریح، یا تسویهٔ چک برگشتی.
CREATE TABLE IF NOT EXISTS treasury.money_counter_line (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  document_id           uuid NOT NULL,
  line_no               smallint NOT NULL CHECK (line_no BETWEEN 1 AND 500),
  kind                  text NOT NULL CHECK (kind IN ('party','party_advance','account','bounced_cheque')),
  party_id              uuid,
  party_role            text CHECK (party_role IN ('customer','supplier','employee','other')),
  posting_key           text REFERENCES ledger.posting_key(key),
  account_id            uuid,
  cheque_id             uuid,
  amount                core.amount NOT NULL CHECK (amount > 0),
  cost_center_value_id  uuid,
  project_value_id      uuid,
  description           text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, document_id, line_no),
  FOREIGN KEY (tenant_id, document_id) REFERENCES treasury.money_document(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, account_id) REFERENCES ledger.account(tenant_id, id),
  FOREIGN KEY (tenant_id, cheque_id) REFERENCES treasury.cheque(tenant_id, id),
  FOREIGN KEY (tenant_id, cost_center_value_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, project_value_id) REFERENCES ledger.dimension_value(tenant_id, id),
  CONSTRAINT counter_line_shape CHECK (
       (kind IN ('party','party_advance') AND party_id IS NOT NULL AND party_role IS NOT NULL
                                          AND account_id IS NULL AND posting_key IS NULL AND cheque_id IS NULL)
    OR (kind = 'account'        AND num_nonnulls(posting_key, account_id) = 1 AND cheque_id IS NULL)
    OR (kind = 'bounced_cheque' AND cheque_id IS NOT NULL AND party_id IS NOT NULL
                                AND account_id IS NULL AND posting_key IS NULL))
);
SELECT core.enable_tenant_rls('treasury.money_counter_line');

-- =====================================================================
-- ۱۰. صورتحساب بانک و مغایرت‌گیری
-- =====================================================================
CREATE TABLE IF NOT EXISTS treasury.statement_profile (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  code                 text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
  name                 text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  bank_code            text REFERENCES ref.bank(code),
  base_global_code     text,
  base_global_version  integer,
  config               jsonb NOT NULL CHECK (jsonb_typeof(config) = 'object'),
  is_active            boolean NOT NULL DEFAULT true,
  created_by           uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (base_global_code, base_global_version) REFERENCES treasury.statement_profile_global(code, version),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('treasury.statement_profile');

-- ورود یک فایل صورتحساب: uploaded → parsed → validated → committed؛ هر وضعیت غیرنهایی → rejected.
-- واحد مبلغ فایل صریح است (core.amount_unit). سطرها به ریال تبدیل‌شده ذخیره می‌شوند.
CREATE TABLE IF NOT EXISTS treasury.statement_import (
  tenant_id                    uuid NOT NULL REFERENCES core.tenant(id),
  id                           uuid NOT NULL DEFAULT uuidv7(),
  company_id                   uuid NOT NULL,
  bank_account_id              uuid NOT NULL,
  attachment_id                uuid NOT NULL,
  file_sha256                  bytea NOT NULL CHECK (octet_length(file_sha256) = 32),
  file_kind                    text NOT NULL CHECK (file_kind IN ('xlsx','xls','html_xls','csv','pdf_text','xml','api')),
  profile_id                   uuid,
  global_profile_code          text,
  global_profile_version       integer,
  amount_unit                  core.amount_unit NOT NULL,
  period_from                  date,
  period_to                    date,
  opening_balance              core.amount,
  closing_balance              core.amount,
  row_count                    integer CHECK (row_count >= 0),
  status                       text NOT NULL DEFAULT 'uploaded'
                               CHECK (status IN ('uploaded','parsed','validated','committed','rejected')),
  continuity_ok                boolean,
  continuity_override_reason   text,
  continuity_overridden_by     uuid,
  errors                       jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(errors) = 'array'),
  committed_at                 timestamptz,
  committed_by                 uuid,
  rejected_reason              text,
  created_by                   uuid,
  created_at                   timestamptz NOT NULL DEFAULT now(),
  updated_at                   timestamptz NOT NULL DEFAULT now(),
  row_version                  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, attachment_id) REFERENCES core.attachment(tenant_id, id),
  FOREIGN KEY (tenant_id, profile_id) REFERENCES treasury.statement_profile(tenant_id, id),
  FOREIGN KEY (global_profile_code, global_profile_version) REFERENCES treasury.statement_profile_global(code, version),
  FOREIGN KEY (tenant_id, continuity_overridden_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, committed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT statement_import_period CHECK (period_to IS NULL OR period_from IS NULL OR period_to >= period_from),
  CONSTRAINT statement_import_profile CHECK (num_nonnulls(profile_id, global_profile_code) <= 1
                                             AND (global_profile_code IS NULL) = (global_profile_version IS NULL)),
  CONSTRAINT statement_import_committed CHECK ((status = 'committed') = (committed_at IS NOT NULL)
        AND (status <> 'committed' OR continuity_ok OR char_length(btrim(coalesce(continuity_override_reason, ''))) >= 5)),
  CONSTRAINT statement_import_override CHECK ((continuity_override_reason IS NULL) = (continuity_overridden_by IS NULL)),
  CONSTRAINT statement_import_rejected CHECK ((status = 'rejected') = (rejected_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('treasury.statement_import');
CREATE UNIQUE INDEX IF NOT EXISTS statement_import_file_uq ON treasury.statement_import (tenant_id, bank_account_id, file_sha256)
  WHERE status <> 'rejected';

-- سطر صورتحساب. dedupe_hash = sha256(تاریخ، ساعت، مبلغ علامت‌دار، مرجع، مانده، شمارهٔ تکرار در گروه یکسان)؛
-- یکتا در حساب بین سطرهای جایگزین‌نشده تا ورود هم‌پوشان تکرار نسازد.
CREATE TABLE IF NOT EXISTS treasury.statement_line (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  import_id           uuid NOT NULL,
  bank_account_id     uuid NOT NULL,
  line_no             integer NOT NULL CHECK (line_no >= 1),
  txn_date            date NOT NULL,
  txn_time            time,
  value_date          date,
  description_raw     text NOT NULL CHECK (char_length(description_raw) <= 2000),
  description_norm    text GENERATED ALWAYS AS (core.fa_search_key(description_raw)) STORED,
  debit               core.amount NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit              core.amount NOT NULL DEFAULT 0 CHECK (credit >= 0),
  signed_amount       core.amount GENERATED ALWAYS AS (credit - debit) STORED,
  balance             core.amount,
  reference           text CHECK (char_length(reference) <= 64),
  cheque_no           text CHECK (char_length(cheque_no) <= 30),
  deposit_id          text CHECK (char_length(deposit_id) <= 40),
  counterparty        text CHECK (char_length(counterparty) <= 200),
  branch_code         text CHECK (char_length(branch_code) <= 20),
  terminal_no         text CHECK (terminal_no ~ '^[0-9A-Za-z]{4,16}$'),
  txn_class           text CHECK (txn_class IN ('paya','satna','pol','card_transfer','pos_settlement','ipg_settlement',
                                                'cheque','bank_fee','interest','atm','loan','internal','other')),
  suggested_party_id  uuid,
  dedupe_hash         bytea NOT NULL CHECK (octet_length(dedupe_hash) = 32),
  is_superseded       boolean NOT NULL DEFAULT false,
  match_status        text NOT NULL DEFAULT 'unmatched' CHECK (match_status IN ('unmatched','matched','ignored')),
  ignored_reason      text,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, import_id, line_no),
  FOREIGN KEY (tenant_id, import_id) REFERENCES treasury.statement_import(tenant_id, id),
  FOREIGN KEY (tenant_id, bank_account_id) REFERENCES treasury.bank_account(tenant_id, id),
  FOREIGN KEY (tenant_id, suggested_party_id) REFERENCES parties.party(tenant_id, id),
  CONSTRAINT statement_line_one_side CHECK ((debit > 0) <> (credit > 0)),
  CONSTRAINT statement_line_ignored CHECK ((match_status = 'ignored') = (ignored_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('treasury.statement_line');
CREATE UNIQUE INDEX IF NOT EXISTS statement_line_dedupe_uq ON treasury.statement_line (tenant_id, bank_account_id, dedupe_hash)
  WHERE NOT is_superseded;
CREATE INDEX IF NOT EXISTS statement_line_unmatched_idx ON treasury.statement_line (tenant_id, bank_account_id, txn_date)
  WHERE match_status = 'unmatched' AND NOT is_superseded;
CREATE INDEX IF NOT EXISTS statement_line_desc_trgm ON treasury.statement_line USING gin (description_norm gin_trgm_ops);

ALTER TABLE treasury.cheque_event DROP CONSTRAINT IF EXISTS cheque_event_statement_line_fk;
ALTER TABLE treasury.cheque_event ADD CONSTRAINT cheque_event_statement_line_fk
  FOREIGN KEY (tenant_id, statement_line_id) REFERENCES treasury.statement_line(tenant_id, id);
ALTER TABLE treasury.card_settlement DROP CONSTRAINT IF EXISTS card_settlement_statement_line_fk;
ALTER TABLE treasury.card_settlement ADD CONSTRAINT card_settlement_statement_line_fk
  FOREIGN KEY (tenant_id, statement_line_id) REFERENCES treasury.statement_line(tenant_id, id);

-- قاعدهٔ مستأجر برای تطبیق/ثبت خودکار سطرهای بی‌سند (کارمزد، سود، ...).
CREATE TABLE IF NOT EXISTS treasury.recon_rule (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  bank_account_id  uuid,
  name             text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
  priority         smallint NOT NULL DEFAULT 100,
  direction        text CHECK (direction IN ('in','out')),
  pattern          text NOT NULL CHECK (char_length(pattern) BETWEEN 1 AND 500),
  amount_min       core.amount CHECK (amount_min >= 0),
  amount_max       core.amount,
  action           text NOT NULL CHECK (action IN ('suggest','auto_post')),
  txn_class        text CHECK (txn_class IN ('paya','satna','pol','card_transfer','pos_settlement','ipg_settlement',
                                             'cheque','bank_fee','interest','atm','loan','internal','other')),
  posting_key      text REFERENCES ledger.posting_key(key),
  account_id       uuid,
  party_id         uuid,
  is_active        boolean NOT NULL DEFAULT true,
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, account_id) REFERENCES ledger.account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT recon_rule_amount CHECK (amount_max IS NULL OR amount_min IS NULL OR amount_max >= amount_min),
  CONSTRAINT recon_rule_auto_post CHECK (action <> 'auto_post' OR num_nonnulls(posting_key, account_id) = 1)
);
SELECT core.enable_tenant_rls('treasury.recon_rule');

-- گروه تطبیق: یک یا چند سطر صورتحساب ↔ یک یا چند سطر دفتر کل (سطر حساب بانک با بُعد همین حساب).
CREATE TABLE IF NOT EXISTS treasury.recon_match (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  bank_account_id  uuid NOT NULL,
  method           text NOT NULL CHECK (method IN ('exact','rule','fuzzy','manual','auto_post')),
  confidence       numeric(5,4) CHECK (confidence BETWEEN 0 AND 1),
  rule_id          uuid,
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active','undone')),
  matched_by       uuid,
  matched_at       timestamptz NOT NULL DEFAULT now(),
  undone_by        uuid,
  undone_at        timestamptz,
  undo_reason      text,
  note             text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, rule_id) REFERENCES treasury.recon_rule(tenant_id, id),
  FOREIGN KEY (tenant_id, matched_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, undone_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT recon_match_undone CHECK ((status = 'undone') = (undone_at IS NOT NULL AND undo_reason IS NOT NULL)),
  CONSTRAINT recon_match_rule CHECK (method <> 'rule' OR rule_id IS NOT NULL),
  CONSTRAINT recon_match_confidence CHECK (method = 'manual' OR confidence IS NOT NULL)
);
SELECT core.enable_tenant_rls('treasury.recon_match');

CREATE TABLE IF NOT EXISTS treasury.recon_match_item (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  match_id           uuid NOT NULL,
  side               text NOT NULL CHECK (side IN ('statement','book')),
  statement_line_id  uuid,
  journal_line_id    uuid,
  amount             core.amount NOT NULL CHECK (amount <> 0),
  is_active          boolean NOT NULL DEFAULT true,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, match_id) REFERENCES treasury.recon_match(tenant_id, id),
  FOREIGN KEY (tenant_id, statement_line_id) REFERENCES treasury.statement_line(tenant_id, id),
  FOREIGN KEY (tenant_id, journal_line_id) REFERENCES ledger.journal_line(tenant_id, id),
  CONSTRAINT recon_item_side CHECK ((side = 'statement') = (statement_line_id IS NOT NULL AND journal_line_id IS NULL)
                                    AND (side = 'book') = (journal_line_id IS NOT NULL AND statement_line_id IS NULL))
);
SELECT core.enable_tenant_rls('treasury.recon_match_item');
CREATE UNIQUE INDEX IF NOT EXISTS recon_item_statement_active_uq ON treasury.recon_match_item (tenant_id, statement_line_id)
  WHERE is_active AND statement_line_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS recon_item_book_active_uq ON treasury.recon_match_item (tenant_id, journal_line_id)
  WHERE is_active AND journal_line_id IS NOT NULL;

-- صورت مغایرت بانکی در تاریخ as_of. اتحاد: مانده بانک + اقلام دفتری تطبیق‌نشده = ماندهٔ دفتر + اقلام بانکی تطبیق‌نشده.
CREATE TABLE IF NOT EXISTS treasury.bank_reconciliation (
  tenant_id                   uuid NOT NULL REFERENCES core.tenant(id),
  id                          uuid NOT NULL DEFAULT uuidv7(),
  company_id                  uuid NOT NULL,
  bank_account_id             uuid NOT NULL,
  as_of                       date NOT NULL,
  statement_balance           core.amount NOT NULL,
  book_balance                core.amount NOT NULL,
  unmatched_statement_signed  core.amount NOT NULL,
  unmatched_book_signed       core.amount NOT NULL,
  outstanding                 jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(outstanding) = 'object'),
  status                      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','finalized')),
  finalized_by                uuid,
  finalized_at                timestamptz,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  row_version                 integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, bank_account_id, as_of),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, bank_account_id) REFERENCES treasury.bank_account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, finalized_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT bank_recon_finalized CHECK ((status = 'finalized') = (finalized_at IS NOT NULL AND finalized_by IS NOT NULL)),
  CONSTRAINT bank_recon_identity CHECK (status <> 'finalized'
        OR statement_balance + unmatched_book_signed = book_balance + unmatched_statement_signed)
);
SELECT core.enable_tenant_rls('treasury.bank_reconciliation');

-- =====================================================================
-- ۱۱. تریگرهای treasury
-- =====================================================================
-- ---------- touch_row روی جدول‌های تغییرپذیر ----------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bank_account','cash_box','petty_cash_fund','card_terminal','gateway_account','money_document',
                           'open_item','fund_transfer','cash_count','petty_cash_claim','cheque_book','cheque_leaf','cheque',
                           'cheque_print_template','card_txn','card_settlement','gateway_payment','statement_profile',
                           'statement_import','recon_rule','bank_reconciliation'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_touch ON treasury.%I', t);
    EXECUTE format('CREATE TRIGGER trg_touch BEFORE UPDATE ON treasury.%I FOR EACH ROW EXECUTE FUNCTION core.touch_row()', t);
  END LOOP;
END $$;

-- ---------- جدول‌های فقط‌افزودنی ----------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['cheque_event','cheque_sayad_inquiry','cheque_print_log','gateway_event','card_day_close'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_append_only ON treasury.%I', t);
    EXECUTE format('CREATE TRIGGER trg_append_only BEFORE UPDATE OR DELETE ON treasury.%I FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation()', t);
  END LOOP;
  -- حذف ممنوع (به‌روزرسانی با محافظ جدا)
  FOREACH t IN ARRAY ARRAY['open_item','allocation','cheque','cheque_leaf','cheque_book','card_txn','recon_match','recon_match_item',
                           'bank_reconciliation','gateway_payment'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_no_delete ON treasury.%I', t);
    EXECUTE format('CREATE TRIGGER trg_no_delete BEFORE DELETE ON treasury.%I FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation()', t);
  END LOOP;
END $$;

-- ---------- شخص ادغام‌شده (درخواست CR-06 بخش ۰۴) ----------
-- اسناد ثبت‌شده به شخص بازنده اشاره می‌مانند؛ پس روی جدول‌های دارای وضعیت قطعی فقط هنگام درج سنجیده می‌شود.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('money_document','party_id','INSERT'), ('open_item','party_id','INSERT'),
      ('cheque','received_from_party_id','INSERT'), ('cheque','drawer_party_id','INSERT'), ('cheque','payee_party_id','INSERT'),
      ('money_counter_line','party_id','INSERT OR UPDATE'), ('petty_cash_fund','custodian_party_id','INSERT OR UPDATE'),
      ('gateway_payment','party_id','INSERT'), ('petty_cash_claim_line','vendor_party_id','INSERT OR UPDATE'),
      ('recon_rule','party_id','INSERT OR UPDATE')) AS v(tbl, col, ev) LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON treasury.%I', 'trg_party_guard_' || r.col, r.tbl);
    EXECUTE format('CREATE TRIGGER %I BEFORE %s ON treasury.%I FOR EACH ROW EXECUTE FUNCTION parties.child_party_guard(%L)',
                   'trg_party_guard_' || r.col, r.ev, r.tbl, r.col);
  END LOOP;
END $$;

-- ---------- منابع وجه ----------
CREATE OR REPLACE FUNCTION treasury.bank_account_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_sheba_bank text; v_merged text;
BEGIN
  IF NEW.sheba IS NOT NULL THEN
    SELECT s.bank_code, b.merged_into_code INTO v_sheba_bank, v_merged
      FROM ref.bank_sheba_code s JOIN ref.bank b ON b.code = s.bank_code
     WHERE s.sheba_code = ref.sheba_bank_code(NEW.sheba);
    -- کد بانکِ ناشناخته فقط هشدار سرویس است؛ کد شناخته‌شده باید با بانک حساب (یا جانشین ادغامش) بخواند
    IF v_sheba_bank IS NOT NULL AND v_sheba_bank <> NEW.bank_code AND v_merged IS DISTINCT FROM NEW.bank_code THEN
      PERFORM core.raise_hk('HK_TRS_SHEBA_BANK_MISMATCH',
        format('SHEBA bank code %s belongs to %s, not %s', ref.sheba_bank_code(NEW.sheba), v_sheba_bank, NEW.bank_code));
    END IF;
  END IF;
  PERFORM treasury.assert_fund_dimension(NEW.tenant_id, NEW.dimension_value_id, 'bank_account', NEW.id);
  IF TG_OP = 'UPDATE' AND (NEW.company_id, NEW.currency) IS DISTINCT FROM (OLD.company_id, OLD.currency) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'bank_account company and currency cannot change');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.bank_account;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON treasury.bank_account FOR EACH ROW EXECUTE FUNCTION treasury.bank_account_guard();

CREATE OR REPLACE FUNCTION treasury.fund_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM treasury.assert_fund_dimension(NEW.tenant_id, NEW.dimension_value_id, TG_ARGV[0], NEW.id);
  IF TG_OP = 'UPDATE' AND NEW.company_id IS DISTINCT FROM OLD.company_id THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', format('%s company cannot change', TG_TABLE_NAME));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.cash_box;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON treasury.cash_box FOR EACH ROW EXECUTE FUNCTION treasury.fund_guard('cash_box');
DROP TRIGGER IF EXISTS trg_guard ON treasury.petty_cash_fund;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON treasury.petty_cash_fund FOR EACH ROW EXECUTE FUNCTION treasury.fund_guard('petty_cash');
DROP TRIGGER IF EXISTS trg_guard ON treasury.card_terminal;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON treasury.card_terminal FOR EACH ROW EXECUTE FUNCTION treasury.fund_guard('pos_terminal');

CREATE OR REPLACE FUNCTION treasury.gateway_account_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status FROM treasury.gateway_provider WHERE code = NEW.provider_code;
  IF NEW.is_active AND v_status = 'blocked' THEN
    PERFORM core.raise_hk('HK_GW_PROVIDER_BLOCKED', format('gateway provider %s is blocked', NEW.provider_code));
  END IF;
  PERFORM treasury.assert_fund_dimension(NEW.tenant_id, NEW.dimension_value_id, 'payment_gateway', NEW.id);
  IF TG_OP = 'UPDATE' AND (NEW.company_id, NEW.provider_code) IS DISTINCT FROM (OLD.company_id, OLD.provider_code) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'gateway_account company and provider cannot change');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.gateway_account;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON treasury.gateway_account FOR EACH ROW EXECUTE FUNCTION treasury.gateway_account_guard();

-- ---------- سند دریافت/پرداخت ----------
CREATE OR REPLACE FUNCTION treasury.money_document_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_old jsonb; v_new jsonb;
  k_mut CONSTANT text[] := ARRAY['status','cancel_journal_id','cancelled_at','cancel_reason','updated_at','row_version'];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', 'only draft documents can be deleted; cancel a posted document');
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status = 'draft' THEN
    IF NEW.status = 'cancelled' THEN
      PERFORM core.raise_hk('HK_TRS_DOC_TRANSITION', 'a draft is discarded (deleted), not cancelled');
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'cancelled' OR NEW.status = 'draft' THEN
    PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', format('document in status %s cannot change to %s', OLD.status, NEW.status));
  END IF;
  v_old := to_jsonb(OLD) - k_mut; v_new := to_jsonb(NEW) - k_mut;
  IF v_old IS DISTINCT FROM v_new THEN
    PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', 'a posted document is immutable; only cancellation is allowed');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.money_document;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON treasury.money_document FOR EACH ROW EXECUTE FUNCTION treasury.money_document_guard();

-- در commit: سند ثبت‌شده دست‌کم یک ابزار و یک طرف دارد و جمع هر دو برابر مبلغ سند است
CREATE OR REPLACE FUNCTION treasury.money_document_check() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE d treasury.money_document; v_inst numeric; v_n_inst int; v_ctr numeric; v_n_ctr int; v_draft_cheques int;
BEGIN
  SELECT * INTO d FROM treasury.money_document WHERE tenant_id = NEW.tenant_id AND id = NEW.id;
  IF NOT FOUND OR d.status = 'draft' THEN RETURN NULL; END IF;
  SELECT coalesce(sum(amount), 0), count(*), count(*) FILTER (WHERE kind IN ('cheque','cheque_endorse') AND cheque_id IS NULL)
    INTO v_inst, v_n_inst, v_draft_cheques
    FROM treasury.money_instrument WHERE tenant_id = d.tenant_id AND document_id = d.id;
  SELECT coalesce(sum(amount), 0), count(*) INTO v_ctr, v_n_ctr
    FROM treasury.money_counter_line WHERE tenant_id = d.tenant_id AND document_id = d.id;
  IF v_n_inst = 0 OR v_n_ctr = 0 OR v_inst <> d.total_amount OR v_ctr <> d.total_amount THEN
    PERFORM core.raise_hk('HK_TRS_DOC_UNBALANCED',
      format('document %s: instruments %s (%s lines), counter lines %s (%s lines), total %s', d.id, v_inst, v_n_inst, v_ctr, v_n_ctr, d.total_amount));
  END IF;
  IF v_draft_cheques > 0 THEN
    PERFORM core.raise_hk('HK_TRS_DOC_CHEQUE_MISSING', 'every cheque instrument of a posted document must reference its cheque record');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_check ON treasury.money_document;
CREATE CONSTRAINT TRIGGER trg_check AFTER INSERT OR UPDATE ON treasury.money_document
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION treasury.money_document_check();

-- سطرها فقط در پیش‌نویس؛ نوع ابزار باید با جهت سند بخواند؛ درگاه فقط با پرداخت verify‌شده
CREATE OR REPLACE FUNCTION treasury.money_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r record; d treasury.money_document; g treasury.gateway_payment; c treasury.cheque;
BEGIN
  IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
  SELECT * INTO d FROM treasury.money_document WHERE tenant_id = r.tenant_id AND id = r.document_id;
  IF NOT FOUND THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;          -- حذف آبشاری پیش‌نویس
    PERFORM core.raise_hk('HK_TRS_DOC_NOT_FOUND', 'money document not found');
  END IF;
  IF d.status <> 'draft' THEN
    PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', format('lines of a %s document cannot change', d.status));
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF TG_OP = 'UPDATE' AND NEW.document_id <> OLD.document_id THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'line cannot move to another document');
  END IF;
  IF TG_TABLE_NAME = 'money_instrument' THEN
    IF (d.direction = 'receipt' AND NEW.kind NOT IN ('cash','card_pos','bank_transfer','card_to_card','cheque','gateway'))
       OR (d.direction = 'payment' AND NEW.kind NOT IN ('cash','bank_transfer','card_to_card','cheque','cheque_endorse','petty_cash')) THEN
      PERFORM core.raise_hk('HK_TRS_INSTRUMENT_DIRECTION', format('instrument %s is not allowed in a %s', NEW.kind, d.direction));
    END IF;
    IF NEW.kind = 'gateway' THEN
      SELECT * INTO g FROM treasury.gateway_payment WHERE tenant_id = NEW.tenant_id AND id = NEW.gateway_payment_id;
      IF g.state IS DISTINCT FROM 'verified' OR g.amount <> NEW.amount OR g.company_id <> d.company_id THEN
        PERFORM core.raise_hk('HK_GW_NOT_VERIFIED', 'gateway instrument needs a verified gateway payment of the same company and amount');
      END IF;
    END IF;
    IF NEW.cheque_id IS NOT NULL THEN
      SELECT * INTO c FROM treasury.cheque WHERE tenant_id = NEW.tenant_id AND id = NEW.cheque_id;
      IF c.company_id <> d.company_id OR c.amount <> NEW.amount
         OR (NEW.kind = 'cheque' AND c.direction <> CASE d.direction WHEN 'receipt' THEN 'received' ELSE 'issued' END)
         OR (NEW.kind = 'cheque_endorse' AND (c.direction <> 'received' OR c.purpose <> 'payment'))
         OR c.purpose <> 'payment' THEN
        PERFORM core.raise_hk('HK_TRS_INSTRUMENT_CHEQUE', 'cheque instrument must reference a payment cheque of the same company, amount and direction');
      END IF;
    END IF;
  ELSE
    IF NEW.kind = 'bounced_cheque' THEN
      SELECT * INTO c FROM treasury.cheque WHERE tenant_id = NEW.tenant_id AND id = NEW.cheque_id;
      IF c.direction <> 'received' OR c.state NOT IN ('bounced','partially_collected','returned_by_third_party') OR d.direction <> 'receipt' THEN
        PERFORM core.raise_hk('HK_TRS_COUNTER_CHEQUE', 'bounced-cheque settlement line needs a bounced received cheque in a receipt');
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.money_instrument;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON treasury.money_instrument FOR EACH ROW EXECUTE FUNCTION treasury.money_line_guard();
DROP TRIGGER IF EXISTS trg_guard ON treasury.money_counter_line;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON treasury.money_counter_line FOR EACH ROW EXECUTE FUNCTION treasury.money_line_guard();

-- ---------- اقلام باز و تسویه ----------
CREATE OR REPLACE FUNCTION treasury.open_item_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (to_jsonb(NEW) - ARRAY['allocated_amount','status','cancelled_at','cancel_reason','updated_at','row_version'])
     IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['allocated_amount','status','cancelled_at','cancel_reason','updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'open item identity, amount and dates cannot change');
  END IF;
  IF OLD.status = 'cancelled' THEN
    PERFORM core.raise_hk('HK_TRS_OPEN_ITEM_CANCELLED', 'a cancelled open item cannot change');
  END IF;
  IF NEW.status = 'cancelled' THEN
    IF NEW.allocated_amount <> 0 THEN
      PERFORM core.raise_hk('HK_TRS_OPEN_ITEM_ALLOCATED', 'reverse its allocations before cancelling an open item');
    END IF;
  ELSE
    NEW.status := CASE WHEN NEW.allocated_amount = NEW.amount THEN 'closed' ELSE 'open' END;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.open_item;
CREATE TRIGGER trg_guard BEFORE UPDATE ON treasury.open_item FOR EACH ROW EXECUTE FUNCTION treasury.open_item_guard();

-- در commit: مبلغ تخصیص‌یافتهٔ هر قلم = جمع تخصیص‌های فعالِ آن (هیچ مسیری جز allocation آن را عوض نمی‌کند)
CREATE OR REPLACE FUNCTION treasury.open_item_check() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_alloc numeric; v_cur numeric;
BEGIN
  SELECT allocated_amount INTO v_cur FROM treasury.open_item WHERE tenant_id = NEW.tenant_id AND id = NEW.id;
  SELECT coalesce(sum(amount), 0) INTO v_alloc FROM treasury.allocation
   WHERE tenant_id = NEW.tenant_id AND status = 'active' AND (debit_item_id = NEW.id OR credit_item_id = NEW.id);
  IF v_cur IS DISTINCT FROM v_alloc THEN
    PERFORM core.raise_hk('HK_TRS_ALLOC_DRIFT', format('open item %s allocated_amount %s <> active allocations %s', NEW.id, v_cur, v_alloc));
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_check ON treasury.open_item;
CREATE CONSTRAINT TRIGGER trg_check AFTER INSERT OR UPDATE ON treasury.open_item
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION treasury.open_item_check();

CREATE OR REPLACE FUNCTION treasury.allocation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE d treasury.open_item; c treasury.open_item;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF OLD.status <> 'active' OR NEW.status <> 'reversed'
       OR (to_jsonb(NEW) - ARRAY['status','reversed_at','reversed_by','reverse_reason'])
          IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','reversed_at','reversed_by','reverse_reason']) THEN
      PERFORM core.raise_hk('HK_TRS_ALLOC_IMMUTABLE', 'an allocation can only be reversed (active -> reversed)');
    END IF;
    RETURN NEW;
  END IF;
  -- قفل هر دو قلم به ترتیب شناسه (جلوگیری از بن‌بست)
  PERFORM 1 FROM treasury.open_item WHERE tenant_id = NEW.tenant_id AND id IN (NEW.debit_item_id, NEW.credit_item_id)
    ORDER BY id FOR UPDATE;
  SELECT * INTO d FROM treasury.open_item WHERE tenant_id = NEW.tenant_id AND id = NEW.debit_item_id;
  SELECT * INTO c FROM treasury.open_item WHERE tenant_id = NEW.tenant_id AND id = NEW.credit_item_id;
  IF NEW.status <> 'active' THEN
    PERFORM core.raise_hk('HK_TRS_ALLOC_IMMUTABLE', 'allocations are created active');
  END IF;
  IF d.direction <> 'debit' OR c.direction <> 'credit' THEN
    PERFORM core.raise_hk('HK_TRS_ALLOC_DIRECTION', 'allocation pairs a debit item with a credit item');
  END IF;
  IF d.status <> 'open' OR c.status <> 'open' THEN
    PERFORM core.raise_hk('HK_TRS_ALLOC_ITEM_STATE', 'both open items must be open');
  END IF;
  IF d.company_id <> NEW.company_id OR c.company_id <> NEW.company_id THEN
    PERFORM core.raise_hk('HK_TRS_ALLOC_COMPANY', 'open items belong to another company');
  END IF;
  IF d.currency <> NEW.currency OR c.currency <> NEW.currency THEN
    PERFORM core.raise_hk('HK_TRS_ALLOC_CURRENCY', 'open items and allocation must share one currency');
  END IF;
  IF treasury.canonical_party(NEW.tenant_id, d.party_id) IS DISTINCT FROM treasury.canonical_party(NEW.tenant_id, c.party_id) THEN
    PERFORM core.raise_hk('HK_TRS_ALLOC_PARTY', 'open items belong to different parties');
  END IF;
  IF (NEW.kind = 'normal' AND d.account_class <> c.account_class) OR (NEW.kind = 'offset' AND d.account_class = c.account_class) THEN
    PERFORM core.raise_hk('HK_TRS_ALLOC_CLASS', 'normal allocation needs one account class; offset needs receivable vs payable');
  END IF;
  IF d.allocated_amount + NEW.amount > d.amount OR c.allocated_amount + NEW.amount > c.amount THEN
    PERFORM core.raise_hk('HK_TRS_ALLOC_EXCEEDS', format('allocation %s exceeds the outstanding amount of an item', NEW.amount));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.allocation;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON treasury.allocation FOR EACH ROW EXECUTE FUNCTION treasury.allocation_guard();

CREATE OR REPLACE FUNCTION treasury.allocation_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_delta numeric;
BEGIN
  v_delta := CASE WHEN TG_OP = 'INSERT' THEN NEW.amount ELSE -NEW.amount END;
  UPDATE treasury.open_item SET allocated_amount = allocated_amount + v_delta
   WHERE tenant_id = NEW.tenant_id AND id IN (NEW.debit_item_id, NEW.credit_item_id);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON treasury.allocation;
CREATE TRIGGER trg_apply AFTER INSERT OR UPDATE OF status ON treasury.allocation FOR EACH ROW EXECUTE FUNCTION treasury.allocation_apply();

-- ---------- انتقال وجه، شمارش نقد، تنخواه ----------
CREATE OR REPLACE FUNCTION treasury.fund_currency(p_tenant uuid, p_cash uuid, p_bank uuid, p_petty uuid) RETURNS char(3)
LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT currency FROM treasury.cash_box WHERE tenant_id = p_tenant AND id = p_cash),
                  (SELECT currency FROM treasury.bank_account WHERE tenant_id = p_tenant AND id = p_bank),
                  (SELECT currency FROM treasury.petty_cash_fund WHERE tenant_id = p_tenant AND id = p_petty))
$$;

CREATE OR REPLACE FUNCTION treasury.fund_transfer_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE k_mut CONSTANT text[] := ARRAY['status','receive_journal_id','received_date','cancel_journal_id','cancel_reason','updated_at','row_version'];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', 'only draft transfers can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF treasury.fund_currency(NEW.tenant_id, NEW.from_cash_box_id, NEW.from_bank_account_id, NEW.from_petty_cash_fund_id) <> NEW.currency
     OR treasury.fund_currency(NEW.tenant_id, NEW.to_cash_box_id, NEW.to_bank_account_id, NEW.to_petty_cash_fund_id) <> NEW.currency THEN
    PERFORM core.raise_hk('HK_TRS_TRANSFER_CURRENCY', 'both funds must have the transfer currency');
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status <> 'draft' THEN
    IF NOT ((OLD.status = 'sent' AND NEW.status IN ('sent','posted','cancelled'))
         OR (OLD.status = 'posted' AND NEW.status IN ('posted','cancelled'))) THEN
      PERFORM core.raise_hk('HK_TRS_DOC_TRANSITION', format('transfer %s -> %s is not allowed', OLD.status, NEW.status));
    END IF;
    IF (to_jsonb(NEW) - k_mut) IS DISTINCT FROM (to_jsonb(OLD) - k_mut) THEN
      PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', 'a sent/posted transfer is immutable; only completion or cancellation is allowed');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.fund_transfer;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON treasury.fund_transfer FOR EACH ROW EXECUTE FUNCTION treasury.fund_transfer_guard();

CREATE OR REPLACE FUNCTION treasury.denominations_total(p jsonb) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(sum((e->>'value')::numeric * (e->>'qty')::numeric), 0) FROM jsonb_array_elements(p) e
$$;

CREATE OR REPLACE FUNCTION treasury.cash_count_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', 'a posted cash count cannot be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'posted' THEN
    PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', 'a posted cash count is immutable');
  END IF;
  IF jsonb_array_length(NEW.denominations) > 0 THEN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(NEW.denominations) e
                WHERE jsonb_typeof(e->'value') <> 'string' OR (e->>'value') !~ '^[0-9]{1,20}(\.[0-9]{1,4})?$'
                   OR jsonb_typeof(e->'qty') <> 'number' OR (e->>'qty')::numeric < 0 OR (e->>'qty')::numeric <> trunc((e->>'qty')::numeric)) THEN
      PERFORM core.raise_hk('HK_TRS_CASH_COUNT_DENOMINATION', 'denominations must be [{value: decimal string, qty: non-negative integer}]');
    END IF;
    IF treasury.denominations_total(NEW.denominations) <> NEW.counted_amount THEN
      PERFORM core.raise_hk('HK_TRS_CASH_COUNT_TOTAL',
        format('denominations total %s <> counted amount %s', treasury.denominations_total(NEW.denominations), NEW.counted_amount));
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.cash_count;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON treasury.cash_count FOR EACH ROW EXECUTE FUNCTION treasury.cash_count_guard();

CREATE OR REPLACE FUNCTION treasury.petty_claim_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', 'only draft claims can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'draft'     AND NEW.status IN ('submitted','cancelled'))
    OR (OLD.status = 'submitted' AND NEW.status IN ('approved','rejected','draft'))
    OR (OLD.status = 'approved'  AND NEW.status IN ('posted','rejected'))) THEN
    PERFORM core.raise_hk('HK_TRS_DOC_TRANSITION', format('petty cash claim %s -> %s is not allowed', OLD.status, NEW.status));
  END IF;
  IF OLD.status IN ('posted','rejected','cancelled') AND (to_jsonb(NEW) - ARRAY['replenished_by_transfer_id','updated_at','row_version'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['replenished_by_transfer_id','updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', 'a closed petty cash claim is immutable');
  END IF;
  IF OLD.replenished_by_transfer_id IS NOT NULL AND NEW.replenished_by_transfer_id IS DISTINCT FROM OLD.replenished_by_transfer_id THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'replenishment link is set once');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.petty_cash_claim;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON treasury.petty_cash_claim FOR EACH ROW EXECUTE FUNCTION treasury.petty_claim_guard();

CREATE OR REPLACE FUNCTION treasury.petty_claim_check() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text; v_total numeric; v_sum numeric;
BEGIN
  SELECT status, total_amount INTO v_status, v_total FROM treasury.petty_cash_claim WHERE tenant_id = NEW.tenant_id AND id = NEW.id;
  IF v_status IN ('submitted','approved','posted') THEN
    SELECT coalesce(sum(amount), 0) INTO v_sum FROM treasury.petty_cash_claim_line WHERE tenant_id = NEW.tenant_id AND claim_id = NEW.id;
    IF v_sum <> v_total THEN
      PERFORM core.raise_hk('HK_TRS_DOC_UNBALANCED', format('petty cash claim lines %s <> total %s', v_sum, v_total));
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_check ON treasury.petty_cash_claim;
CREATE CONSTRAINT TRIGGER trg_check AFTER INSERT OR UPDATE ON treasury.petty_cash_claim
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION treasury.petty_claim_check();

CREATE OR REPLACE FUNCTION treasury.petty_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r record; v_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
  SELECT status INTO v_status FROM treasury.petty_cash_claim WHERE tenant_id = r.tenant_id AND id = r.claim_id;
  IF v_status IS NOT NULL AND v_status <> 'draft' THEN
    PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', 'claim lines change only while the claim is draft');
  END IF;
  RETURN r;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.petty_cash_claim_line;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON treasury.petty_cash_claim_line FOR EACH ROW EXECUTE FUNCTION treasury.petty_line_guard();

-- ---------- دسته‌چک و برگ ----------
CREATE OR REPLACE FUNCTION treasury.cheque_leaf_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE b treasury.cheque_book; v_active boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO b FROM treasury.cheque_book WHERE tenant_id = NEW.tenant_id AND id = NEW.cheque_book_id;
    IF NEW.serial_no NOT BETWEEN b.serial_from AND b.serial_to THEN
      PERFORM core.raise_hk('HK_CHQ_LEAF_RANGE', format('serial %s outside cheque book range [%s, %s]', NEW.serial_no, b.serial_from, b.serial_to));
    END IF;
    IF NEW.state <> 'unused' THEN PERFORM core.raise_hk('HK_CHQ_LEAF_TRANSITION', 'a new leaf is unused'); END IF;
    RETURN NEW;
  END IF;
  IF NEW.cheque_book_id <> OLD.cheque_book_id OR NEW.serial_no <> OLD.serial_no
     OR (OLD.sayad_id IS NOT NULL AND NEW.sayad_id IS DISTINCT FROM OLD.sayad_id) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'leaf book, serial and sayad id are immutable');
  END IF;
  IF NEW.state IS DISTINCT FROM OLD.state THEN
    v_active := EXISTS (SELECT 1 FROM treasury.cheque c WHERE c.tenant_id = NEW.tenant_id AND c.cheque_leaf_id = NEW.id AND c.state <> 'cancelled');
    IF NOT ((OLD.state = 'unused' AND NEW.state = 'issued' AND v_active)
         OR (OLD.state = 'unused' AND NEW.state IN ('void','lost'))
         OR (OLD.state = 'issued' AND NEW.state = 'unused' AND NOT v_active)) THEN
      PERFORM core.raise_hk('HK_CHQ_LEAF_TRANSITION', format('leaf %s -> %s is not allowed', OLD.state, NEW.state));
    END IF;
    NEW.state_changed_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.cheque_leaf;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON treasury.cheque_leaf FOR EACH ROW EXECUTE FUNCTION treasury.cheque_leaf_guard();

-- ---------- چک ----------
CREATE OR REPLACE FUNCTION treasury.sayad_rank(p_state text) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_state WHEN 'not_inquired' THEN 0 WHEN 'inquired' THEN 1 WHEN 'accepted' THEN 2 WHEN 'transferred' THEN 3
                      WHEN 'not_registered' THEN 0 WHEN 'registered' THEN 1 WHEN 'accepted_by_payee' THEN 2
                      WHEN 'transferred_by_payee' THEN 3 ELSE NULL END::smallint
$$;

CREATE OR REPLACE FUNCTION treasury.cheque_before_write() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE e treasury.cheque_event;
  k_frozen CONSTANT text[] := ARRAY['tenant_id','company_id','branch_id','direction','purpose','medium','instrument','sayad_id',
    'serial_no','series','is_legacy','amount','currency','amount_base','issue_date','due_date','reason_text','drawer_party_id',
    'drawer_name','drawer_national_id','drawer_bank_code','drawer_branch_code','drawer_account_no','drawer_sheba',
    'received_from_party_id','bank_account_id','cheque_leaf_id','payee_party_id','payee_name','payee_national_id',
    'converted_from_cheque_id','replaces_cheque_id','origin','money_document_id','created_by','created_at'];
  c text;
BEGIN
  NEW.sayad_unique := coalesce((SELECT s.sayad_unique FROM treasury.cheque_state s
                                 WHERE s.direction = NEW.direction AND s.purpose = NEW.purpose AND s.state = NEW.state), false);
  IF TG_OP = 'INSERT' THEN
    IF NEW.last_event_seq <> 0 THEN
      PERFORM core.raise_hk('HK_CHQ_EVENT_SEQ', 'a new cheque starts with last_event_seq = 0; its creation event follows');
    END IF;
    RETURN NEW;
  END IF;
  FOREACH c IN ARRAY k_frozen LOOP
    IF (to_jsonb(OLD) -> c) IS DISTINCT FROM (to_jsonb(NEW) -> c) THEN
      PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', format('cheque.%s cannot change after registration', c));
    END IF;
  END LOOP;
  -- وضعیت حسابداری فقط از راه رویداد
  IF (NEW.state, NEW.last_event_seq, NEW.collected_amount, NEW.deposit_bank_account_id, NEW.endorsee_party_id, NEW.is_long_term)
     IS DISTINCT FROM (OLD.state, OLD.last_event_seq, OLD.collected_amount, OLD.deposit_bank_account_id, OLD.endorsee_party_id, OLD.is_long_term) THEN
    SELECT * INTO e FROM treasury.cheque_event WHERE tenant_id = NEW.tenant_id AND cheque_id = NEW.id AND seq = NEW.last_event_seq;
    IF NEW.last_event_seq <> OLD.last_event_seq + 1 OR NOT FOUND OR e.to_state <> NEW.state
       OR NOT ((e.seq = 1 AND e.from_state IS NULL AND OLD.state = NEW.state) OR (e.seq > 1 AND e.from_state = OLD.state))
       OR e.collected_after <> NEW.collected_amount OR e.deposit_bank_after IS DISTINCT FROM NEW.deposit_bank_account_id
       OR e.endorsee_after IS DISTINCT FROM NEW.endorsee_party_id OR e.long_term_after <> NEW.is_long_term THEN
      PERFORM core.raise_hk('HK_CHQ_STATE_VIA_EVENT', 'cheque state changes only by inserting a cheque_event');
    END IF;
  END IF;
  -- بُعد صیاد: فقط رو به جلو؛ رد فقط پیش از تأیید؛ legacy ثابت
  IF NEW.sayad_state IS DISTINCT FROM OLD.sayad_state THEN
    IF OLD.sayad_state IN ('legacy','rejected')
       OR (NEW.sayad_state = 'rejected' AND OLD.sayad_state NOT IN ('not_inquired','inquired'))
       OR (NEW.sayad_state <> 'rejected' AND (treasury.sayad_rank(NEW.sayad_state) IS NULL
                                              OR treasury.sayad_rank(NEW.sayad_state) < treasury.sayad_rank(OLD.sayad_state))) THEN
      PERFORM core.raise_hk('HK_CHQ_SAYAD_TRANSITION', format('sayad state %s -> %s is not allowed', OLD.sayad_state, NEW.sayad_state));
    END IF;
  END IF;
  IF NEW.legal_status IS DISTINCT FROM OLD.legal_status
     AND array_position(ARRAY['none','certificate_issued','execution_filed','settled'], NEW.legal_status)
       < array_position(ARRAY['none','certificate_issued','execution_filed','settled'], OLD.legal_status) THEN
    PERFORM core.raise_hk('HK_CHQ_LEGAL_TRANSITION', format('legal status %s -> %s is not allowed', OLD.legal_status, NEW.legal_status));
  END IF;
  -- رنگ صیاد فقط از راه استعلام ثبت‌شده و فقط تازه‌تر
  IF (NEW.sayad_color_code, NEW.sayad_inquired_at) IS DISTINCT FROM (OLD.sayad_color_code, OLD.sayad_inquired_at) THEN
    IF NEW.sayad_inquired_at IS NULL OR (OLD.sayad_inquired_at IS NOT NULL AND NEW.sayad_inquired_at <= OLD.sayad_inquired_at)
       OR NOT EXISTS (SELECT 1 FROM treasury.cheque_sayad_inquiry i WHERE i.tenant_id = NEW.tenant_id AND i.cheque_id = NEW.id
                         AND i.inquired_at = NEW.sayad_inquired_at AND i.color_code = NEW.sayad_color_code) THEN
      PERFORM core.raise_hk('HK_CHQ_SAYAD_COLOR', 'sayad colour is set only from a recorded, newer inquiry');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.cheque;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON treasury.cheque FOR EACH ROW EXECUTE FUNCTION treasury.cheque_before_write();

-- در commit: هر چک رویداد ایجاد (seq = 1) دارد
CREATE OR REPLACE FUNCTION treasury.cheque_check_created() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT last_event_seq FROM treasury.cheque WHERE tenant_id = NEW.tenant_id AND id = NEW.id) = 0 THEN
    PERFORM core.raise_hk('HK_CHQ_NO_CREATION_EVENT', format('cheque %s has no creation event', NEW.id));
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_check_created ON treasury.cheque;
CREATE CONSTRAINT TRIGGER trg_check_created AFTER INSERT ON treasury.cheque
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION treasury.cheque_check_created();

-- برگ دسته‌چک: صدور → issued؛ ابطال ثبت چک → unused
CREATE OR REPLACE FUNCTION treasury.cheque_leaf_sync() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE l treasury.cheque_leaf; b treasury.cheque_book;
BEGIN
  IF NEW.cheque_leaf_id IS NULL THEN RETURN NULL; END IF;
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO l FROM treasury.cheque_leaf WHERE tenant_id = NEW.tenant_id AND id = NEW.cheque_leaf_id FOR UPDATE;
    SELECT * INTO b FROM treasury.cheque_book WHERE tenant_id = NEW.tenant_id AND id = l.cheque_book_id;
    IF l.state <> 'unused' OR b.bank_account_id <> NEW.bank_account_id OR b.medium <> NEW.medium OR b.status <> 'active'
       OR (l.sayad_id IS NOT NULL AND NEW.sayad_id IS NOT NULL AND l.sayad_id <> NEW.sayad_id) THEN
      PERFORM core.raise_hk('HK_CHQ_LEAF_MISMATCH', 'issued cheque needs an unused leaf of an active book of the same bank account, medium and sayad id');
    END IF;
    UPDATE treasury.cheque_leaf SET state = 'issued', sayad_id = coalesce(sayad_id, NEW.sayad_id)
     WHERE tenant_id = NEW.tenant_id AND id = NEW.cheque_leaf_id;
  ELSIF NEW.state = 'cancelled' AND OLD.state <> 'cancelled' THEN
    UPDATE treasury.cheque_leaf SET state = 'unused' WHERE tenant_id = NEW.tenant_id AND id = NEW.cheque_leaf_id AND state = 'issued';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_leaf_sync ON treasury.cheque;
CREATE TRIGGER trg_leaf_sync AFTER INSERT OR UPDATE OF state ON treasury.cheque FOR EACH ROW EXECUTE FUNCTION treasury.cheque_leaf_sync();

-- رویداد چک: اعتبارسنجی گذار و مقادیر «پس از» (قبل از درج)، سپس اعمال روی چک (پس از درج)
CREATE OR REPLACE FUNCTION treasury.cheque_event_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c treasury.cheque; t treasury.cheque_transition; u treasury.cheque_event; p treasury.cheque_event;
        v_hold boolean; v_last_date date; v_outstanding numeric;
BEGIN
  SELECT * INTO c FROM treasury.cheque WHERE tenant_id = NEW.tenant_id AND id = NEW.cheque_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_CHQ_NOT_FOUND', 'cheque not found'); END IF;
  IF NEW.seq <> c.last_event_seq + 1 THEN
    PERFORM core.raise_hk('HK_CHQ_EVENT_SEQ', format('next event seq for cheque %s must be %s, got %s', c.id, c.last_event_seq + 1, NEW.seq));
  END IF;
  SELECT max(event_date) INTO v_last_date FROM treasury.cheque_event WHERE tenant_id = NEW.tenant_id AND cheque_id = NEW.cheque_id;
  IF v_last_date IS NOT NULL AND NEW.event_date < v_last_date THEN
    PERFORM core.raise_hk('HK_CHQ_EVENT_DATE', format('event date %s precedes the previous event date %s', NEW.event_date, v_last_date));
  END IF;
  SELECT is_holding INTO v_hold FROM treasury.cheque_state WHERE direction = c.direction AND purpose = c.purpose AND state = NEW.to_state;
  IF NEW.kind = 'transition' THEN
    SELECT * INTO t FROM treasury.cheque_transition WHERE code = NEW.transition_code;
    IF t.direction <> c.direction OR t.purpose <> c.purpose THEN
      PERFORM core.raise_hk('HK_CHQ_TRANSITION_KIND', format('transition %s is for %s/%s cheques', t.code, t.direction, t.purpose));
    END IF;
    -- ۱) اعتبار گذار نسبت به وضعیت جاری
    IF NEW.seq = 1 THEN
      IF t.from_state IS NOT NULL OR NEW.from_state IS NOT NULL OR NEW.to_state <> t.to_state OR c.state <> t.to_state THEN
        PERFORM core.raise_hk('HK_CHQ_TRANSITION', format('first event must be a creation transition into state %s', c.state));
      END IF;
      IF (t.op = 'import') <> (c.origin IN ('migration','opening')) THEN
        PERFORM core.raise_hk('HK_CHQ_IMPORT_ORIGIN', 'migrated/opening cheques are created by import transitions, others by normal ones');
      END IF;
    ELSIF t.from_state IS NULL OR t.from_state <> c.state OR NEW.from_state IS DISTINCT FROM c.state OR NEW.to_state <> t.to_state THEN
      PERFORM core.raise_hk('HK_CHQ_TRANSITION', format('transition %s is not allowed from state %s', t.code, c.state));
    END IF;
    -- ۲) سند، منبع وجه، طرف و مبلغ
    IF t.requires_journal AND NEW.journal_id IS NULL THEN
      PERFORM core.raise_hk('HK_CHQ_JOURNAL_REQUIRED', format('transition %s must reference its journal', t.code));
    END IF;
    IF NOT t.requires_journal AND NEW.journal_id IS NOT NULL THEN
      PERFORM core.raise_hk('HK_CHQ_JOURNAL_UNEXPECTED', format('transition %s has no journal', t.code));
    END IF;
    IF t.requires_fund AND num_nonnulls(NEW.bank_account_id, NEW.cash_box_id) = 0 THEN
      PERFORM core.raise_hk('HK_CHQ_FUND_REQUIRED', format('transition %s needs a bank account or cash box', t.code));
    END IF;
    IF t.op = 'deposit' AND NEW.bank_account_id IS NULL THEN
      PERFORM core.raise_hk('HK_CHQ_FUND_REQUIRED', 'deposit needs a bank account');
    END IF;
    IF t.requires_counterparty AND NEW.counterparty_party_id IS NULL THEN
      PERFORM core.raise_hk('HK_CHQ_COUNTERPARTY_REQUIRED', format('transition %s needs a counterparty', t.code));
    END IF;
    v_outstanding := c.amount - c.collected_amount;
    IF (t.amount_rule = 'partial' AND (NEW.amount IS NULL OR NEW.amount >= c.amount))
       OR (t.amount_rule = 'explicit' AND NEW.amount IS NULL)
       OR (t.amount_rule = 'face' AND NEW.amount IS NOT NULL AND NEW.amount <> c.amount)
       OR (t.amount_rule = 'outstanding' AND NEW.amount IS NOT NULL AND NEW.amount <> v_outstanding)
       OR (t.amount_rule = 'installment' AND (NEW.amount IS NULL OR NEW.amount <= 0 OR NEW.amount >= v_outstanding))
       OR (t.amount_rule = 'none' AND NEW.amount IS NOT NULL) THEN
      PERFORM core.raise_hk('HK_CHQ_AMOUNT', format('amount %s is invalid for rule %s', NEW.amount, t.amount_rule));
    END IF;
    -- ۳) مقادیر «پس از» (ایجاد: همان چک ثبت‌شده؛ بعد: طبق نوع عملیات)
    IF NEW.seq = 1 THEN
      IF NEW.collected_after <> c.collected_amount OR NEW.deposit_bank_after IS DISTINCT FROM c.deposit_bank_account_id
         OR NEW.endorsee_after IS DISTINCT FROM c.endorsee_party_id OR NEW.long_term_after <> c.is_long_term THEN
        PERFORM core.raise_hk('HK_CHQ_AFTER_VALUES', 'creation event must describe the registered cheque');
      END IF;
    ELSE
      IF NEW.long_term_after IS DISTINCT FROM (CASE WHEN t.op = 'reclassify_current' THEN false ELSE c.is_long_term END)
         OR (t.op = 'reclassify_current' AND NOT c.is_long_term) THEN
        PERFORM core.raise_hk('HK_CHQ_AFTER_VALUES', 'only reclassify_current changes the long-term flag (true -> false)');
      END IF;
      IF NEW.collected_after IS DISTINCT FROM (CASE t.op WHEN 'collect' THEN c.amount WHEN 'collect_direct' THEN c.amount
                                                         WHEN 'collect_partial' THEN NEW.amount
                                                         WHEN 'settle_partial' THEN c.collected_amount + NEW.amount
                                                         ELSE c.collected_amount END) THEN
        PERFORM core.raise_hk('HK_CHQ_AFTER_VALUES', format('collected amount after %s is inconsistent', t.op));
      END IF;
      IF NEW.deposit_bank_after IS DISTINCT FROM (CASE t.op WHEN 'deposit' THEN NEW.bank_account_id WHEN 'withdraw_deposit' THEN NULL
                                                            ELSE c.deposit_bank_account_id END) THEN
        PERFORM core.raise_hk('HK_CHQ_AFTER_VALUES', format('deposit bank after %s is inconsistent', t.op));
      END IF;
      IF NEW.endorsee_after IS DISTINCT FROM (CASE t.op WHEN 'endorse' THEN NEW.counterparty_party_id ELSE c.endorsee_party_id END) THEN
        PERFORM core.raise_hk('HK_CHQ_AFTER_VALUES', format('endorsee after %s is inconsistent', t.op));
      END IF;
    END IF;
    -- محل نگهداری ارزش چک: فقط در وضعیت‌های «نزد ما» و برابر مانده
    IF v_hold <> (NEW.holding_account_id IS NOT NULL)
       OR (NEW.holding_amount IS NOT NULL AND NEW.holding_amount <> c.amount - NEW.collected_after) THEN
      PERFORM core.raise_hk('HK_CHQ_HOLDING', 'holding account/amount must be set exactly for holding states and equal the outstanding amount');
    END IF;
  ELSE
    SELECT * INTO u FROM treasury.cheque_event WHERE tenant_id = NEW.tenant_id AND id = NEW.undoes_event_id;
    IF NOT FOUND OR u.cheque_id <> NEW.cheque_id OR u.seq = 1 OR u.kind <> 'transition' THEN
      PERFORM core.raise_hk('HK_CHQ_UNDO_TARGET', 'only a later transition of the same cheque can be undone (use cancel for the creation)');
    END IF;
    IF EXISTS (SELECT 1 FROM treasury.cheque_event x
                WHERE x.tenant_id = NEW.tenant_id AND x.cheque_id = NEW.cheque_id AND x.kind = 'transition' AND x.seq > u.seq
                  AND NOT EXISTS (SELECT 1 FROM treasury.cheque_event y WHERE y.tenant_id = x.tenant_id AND y.undoes_event_id = x.id)) THEN
      PERFORM core.raise_hk('HK_CHQ_UNDO_NOT_LAST', 'only the latest effective transition can be undone');
    END IF;
    SELECT * INTO p FROM treasury.cheque_event x
     WHERE x.tenant_id = NEW.tenant_id AND x.cheque_id = NEW.cheque_id AND x.kind = 'transition' AND x.seq < u.seq
       AND NOT EXISTS (SELECT 1 FROM treasury.cheque_event y WHERE y.tenant_id = x.tenant_id AND y.undoes_event_id = x.id)
     ORDER BY x.seq DESC LIMIT 1;
    IF NEW.from_state IS DISTINCT FROM c.state OR NEW.to_state IS DISTINCT FROM p.to_state
       OR NEW.collected_after <> p.collected_after OR NEW.deposit_bank_after IS DISTINCT FROM p.deposit_bank_after
       OR NEW.endorsee_after IS DISTINCT FROM p.endorsee_after OR NEW.long_term_after <> p.long_term_after
       OR NEW.holding_account_id IS DISTINCT FROM p.holding_account_id OR NEW.holding_dim_value_id IS DISTINCT FROM p.holding_dim_value_id
       OR NEW.holding_amount IS DISTINCT FROM p.holding_amount OR NEW.holding_amount_base IS DISTINCT FROM p.holding_amount_base THEN
      PERFORM core.raise_hk('HK_CHQ_UNDO_VALUES', 'undo must restore exactly the state after the previous effective transition');
    END IF;
    IF (u.journal_id IS NOT NULL) <> (NEW.journal_id IS NOT NULL) OR NEW.journal_id = u.journal_id THEN
      PERFORM core.raise_hk('HK_CHQ_JOURNAL_REQUIRED', 'undo references the reversal journal exactly when the undone event had a journal');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.cheque_event;
CREATE TRIGGER trg_guard BEFORE INSERT ON treasury.cheque_event FOR EACH ROW EXECUTE FUNCTION treasury.cheque_event_guard();

CREATE OR REPLACE FUNCTION treasury.cheque_event_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE treasury.cheque
     SET state = NEW.to_state, last_event_seq = NEW.seq, collected_amount = NEW.collected_after,
         deposit_bank_account_id = NEW.deposit_bank_after, endorsee_party_id = NEW.endorsee_after, is_long_term = NEW.long_term_after
   WHERE tenant_id = NEW.tenant_id AND id = NEW.cheque_id;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON treasury.cheque_event;
CREATE TRIGGER trg_apply AFTER INSERT ON treasury.cheque_event FOR EACH ROW EXECUTE FUNCTION treasury.cheque_event_apply();

CREATE OR REPLACE FUNCTION treasury.sayad_inquiry_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c treasury.cheque;
BEGIN
  SELECT * INTO c FROM treasury.cheque WHERE tenant_id = NEW.tenant_id AND id = NEW.cheque_id FOR UPDATE;
  IF c.direction <> 'received' THEN
    PERFORM core.raise_hk('HK_CHQ_SAYAD_INQUIRY', 'sayad credit inquiry applies to received cheques only');
  END IF;
  IF c.sayad_inquired_at IS NULL OR NEW.inquired_at > c.sayad_inquired_at THEN
    UPDATE treasury.cheque
       SET sayad_color_code = NEW.color_code, sayad_inquired_at = NEW.inquired_at,
           sayad_state = CASE WHEN sayad_state = 'not_inquired' THEN 'inquired' ELSE sayad_state END
     WHERE tenant_id = NEW.tenant_id AND id = NEW.cheque_id;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON treasury.cheque_sayad_inquiry;
CREATE TRIGGER trg_apply AFTER INSERT ON treasury.cheque_sayad_inquiry FOR EACH ROW EXECUTE FUNCTION treasury.sayad_inquiry_apply();

-- ---------- کارتخوان ----------
CREATE OR REPLACE FUNCTION treasury.card_txn_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_set_status text;
  k_frozen CONSTANT text[] := ARRAY['tenant_id','company_id','card_terminal_id','txn_at','business_date','amount','entry_mode',
                                    'source','source_ref','created_at'];
  c text;
BEGIN
  FOREACH c IN ARRAY k_frozen LOOP
    IF (to_jsonb(OLD) -> c) IS DISTINCT FROM (to_jsonb(NEW) -> c) THEN
      PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', format('card_txn.%s cannot change', c));
    END IF;
  END LOOP;
  IF (OLD.rrn IS NOT NULL AND NEW.rrn IS DISTINCT FROM OLD.rrn) OR (OLD.stan IS NOT NULL AND NEW.stan IS DISTINCT FROM OLD.stan)
     OR (OLD.masked_pan IS NOT NULL AND NEW.masked_pan IS DISTINCT FROM OLD.masked_pan) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'rrn, stan and masked pan are set once');
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (OLD.status = 'approved' AND NEW.status IN ('reversed','void')) THEN
    PERFORM core.raise_hk('HK_CRD_TRANSITION', format('card txn %s -> %s is not allowed', OLD.status, NEW.status));
  END IF;
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id THEN
    IF OLD.settlement_id IS NOT NULL THEN
      SELECT status INTO v_set_status FROM treasury.card_settlement WHERE tenant_id = OLD.tenant_id AND id = OLD.settlement_id;
      IF NEW.settlement_id IS NOT NULL OR v_set_status NOT IN ('cancelled','draft') THEN
        PERFORM core.raise_hk('HK_CRD_SETTLED_ONCE', 'a card transaction is settled once; release only through settlement cancellation');
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.card_txn;
CREATE TRIGGER trg_guard BEFORE UPDATE ON treasury.card_txn FOR EACH ROW EXECUTE FUNCTION treasury.card_txn_guard();

CREATE OR REPLACE FUNCTION treasury.card_settlement_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', 'only draft settlements can be deleted'); END IF;
    UPDATE treasury.card_txn SET settlement_id = NULL, settled_at = NULL WHERE tenant_id = OLD.tenant_id AND settlement_id = OLD.id;
    RETURN OLD;
  END IF;
  IF OLD.status <> 'draft' THEN
    IF NOT (OLD.status = 'posted' AND NEW.status = 'cancelled')
       OR (to_jsonb(NEW) - ARRAY['status','cancel_journal_id','updated_at','row_version','net_amount'])
          IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','cancel_journal_id','updated_at','row_version','net_amount']) THEN
      PERFORM core.raise_hk('HK_TRS_DOC_IMMUTABLE', 'a posted settlement can only be cancelled');
    END IF;
  ELSIF NEW.status = 'cancelled' THEN
    PERFORM core.raise_hk('HK_TRS_DOC_TRANSITION', 'a draft settlement is deleted, not cancelled');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.card_settlement;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON treasury.card_settlement FOR EACH ROW EXECUTE FUNCTION treasury.card_settlement_guard();

CREATE OR REPLACE FUNCTION treasury.card_settlement_release() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'cancelled' AND OLD.status <> 'cancelled' THEN
    UPDATE treasury.card_txn SET settlement_id = NULL, settled_at = NULL WHERE tenant_id = NEW.tenant_id AND settlement_id = NEW.id;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_release ON treasury.card_settlement;
CREATE TRIGGER trg_release AFTER UPDATE OF status ON treasury.card_settlement FOR EACH ROW EXECUTE FUNCTION treasury.card_settlement_release();

-- در commit: تسویهٔ ثبت‌شده = جمع تراکنش‌های تأییدشدهٔ متصل (همان پایانه)
CREATE OR REPLACE FUNCTION treasury.card_settlement_check() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s treasury.card_settlement; v_sum numeric; v_other int;
BEGIN
  SELECT * INTO s FROM treasury.card_settlement WHERE tenant_id = NEW.tenant_id AND id = NEW.id;
  IF NOT FOUND OR s.status <> 'posted' THEN RETURN NULL; END IF;
  SELECT coalesce(sum(amount) FILTER (WHERE status = 'approved'), 0), count(*) FILTER (WHERE card_terminal_id <> s.card_terminal_id OR status <> 'approved')
    INTO v_sum, v_other FROM treasury.card_txn WHERE tenant_id = s.tenant_id AND settlement_id = s.id;
  IF v_sum <> s.gross_amount OR v_other > 0 THEN
    PERFORM core.raise_hk('HK_CRD_SETTLEMENT_TOTAL',
      format('settlement %s gross %s <> approved transactions %s of its terminal (foreign/void rows: %s)', s.id, s.gross_amount, v_sum, v_other));
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_check ON treasury.card_settlement;
CREATE CONSTRAINT TRIGGER trg_check AFTER INSERT OR UPDATE ON treasury.card_settlement
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION treasury.card_settlement_check();

-- ---------- درگاه ----------
CREATE OR REPLACE FUNCTION treasury.gateway_payment_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE a treasury.gateway_account; pv treasury.gateway_provider; v_doc_status text;
  k_frozen CONSTANT text[] := ARRAY['tenant_id','company_id','gateway_account_id','provider_code','open_item_id','party_id','order_id',
                                    'amount','api_amount','api_amount_unit','created_by','created_at'];
  c text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO a FROM treasury.gateway_account WHERE tenant_id = NEW.tenant_id AND id = NEW.gateway_account_id;
    SELECT * INTO pv FROM treasury.gateway_provider WHERE code = a.provider_code;
    IF NEW.provider_code <> a.provider_code OR NOT a.is_active OR pv.status = 'blocked' THEN
      PERFORM core.raise_hk('HK_GW_ACCOUNT', 'payment needs an active gateway account of a non-blocked provider (provider_code copied from it)');
    END IF;
    IF NEW.api_amount_unit <> pv.api_amount_unit
       OR NEW.api_amount <> (CASE pv.api_amount_unit WHEN 'IRT' THEN NEW.amount / 10 ELSE NEW.amount END)
       OR (pv.api_amount_unit = 'IRT' AND NEW.amount % 10 <> 0) THEN
      PERFORM core.raise_hk('HK_GW_AMOUNT_UNIT', format('api amount %s %s does not match %s IRR for provider %s',
                                                         NEW.api_amount, NEW.api_amount_unit, NEW.amount, pv.code));
    END IF;
    IF NEW.state <> 'created' THEN PERFORM core.raise_hk('HK_GW_TRANSITION', 'a payment starts in state created'); END IF;
    RETURN NEW;
  END IF;
  FOREACH c IN ARRAY k_frozen LOOP
    IF (to_jsonb(OLD) -> c) IS DISTINCT FROM (to_jsonb(NEW) -> c) THEN
      PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', format('gateway_payment.%s cannot change', c));
    END IF;
  END LOOP;
  IF (OLD.provider_ref IS NOT NULL AND NEW.provider_ref IS DISTINCT FROM OLD.provider_ref)
     OR (OLD.provider_txn_ref IS NOT NULL AND NEW.provider_txn_ref IS DISTINCT FROM OLD.provider_txn_ref)
     OR (OLD.money_document_id IS NOT NULL AND NEW.money_document_id IS DISTINCT FROM OLD.money_document_id) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'provider refs and receipt link are set once');
  END IF;
  IF NEW.state IS DISTINCT FROM OLD.state AND NOT (
       (OLD.state = 'created'           AND NEW.state IN ('redirected','failed','expired'))
    OR (OLD.state = 'redirected'        AND NEW.state IN ('callback_received','verified','failed','expired'))
    OR (OLD.state = 'callback_received' AND NEW.state IN ('verified','failed','expired','reversed'))
    OR (OLD.state = 'expired'           AND NEW.state = 'verified' AND NEW.late_verification)
    OR (OLD.state = 'verified'          AND NEW.state IN ('refunded','reversed'))) THEN
    PERFORM core.raise_hk('HK_GW_TRANSITION', format('gateway payment %s -> %s is not allowed', OLD.state, NEW.state));
  END IF;
  IF NEW.state = 'reversed' AND OLD.state = 'verified' AND NEW.money_document_id IS NOT NULL THEN
    SELECT status INTO v_doc_status FROM treasury.money_document WHERE tenant_id = NEW.tenant_id AND id = NEW.money_document_id;
    IF v_doc_status <> 'cancelled' THEN
      PERFORM core.raise_hk('HK_GW_REVERSE_WITH_RECEIPT', 'cancel the receipt of a verified payment before marking it reversed');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.gateway_payment;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON treasury.gateway_payment FOR EACH ROW EXECUTE FUNCTION treasury.gateway_payment_guard();

-- ---------- صورتحساب و مغایرت ----------
CREATE OR REPLACE FUNCTION treasury.statement_continuity_breaks(p_import_id uuid)
RETURNS TABLE (line_no integer, expected_balance numeric, actual_balance numeric)
LANGUAGE sql STABLE AS $$
  WITH imp AS (SELECT * FROM treasury.statement_import WHERE id = p_import_id),
  l AS (SELECT s.line_no, s.signed_amount, s.balance,
               lag(s.balance) OVER (ORDER BY s.line_no) AS prev_balance,
               row_number() OVER (ORDER BY s.line_no) AS rn,
               row_number() OVER (ORDER BY s.line_no DESC) AS rn_desc
          FROM treasury.statement_line s WHERE s.import_id = p_import_id)
  SELECT l.line_no, l.prev_balance + l.signed_amount, l.balance FROM l
   WHERE l.balance IS NOT NULL AND l.prev_balance IS NOT NULL AND l.balance <> l.prev_balance + l.signed_amount
  UNION ALL
  SELECT l.line_no, imp.opening_balance + l.signed_amount, l.balance FROM l, imp
   WHERE l.rn = 1 AND imp.opening_balance IS NOT NULL AND l.balance IS NOT NULL AND l.balance <> imp.opening_balance + l.signed_amount
  UNION ALL
  SELECT l.line_no, imp.closing_balance, l.balance FROM l, imp
   WHERE l.rn_desc = 1 AND imp.closing_balance IS NOT NULL AND l.balance IS NOT NULL AND l.balance <> imp.closing_balance
  ORDER BY 1
$$;

CREATE OR REPLACE FUNCTION treasury.statement_import_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.company_id, NEW.bank_account_id, NEW.attachment_id, NEW.file_sha256, NEW.amount_unit)
     IS DISTINCT FROM (OLD.company_id, OLD.bank_account_id, OLD.attachment_id, OLD.file_sha256, OLD.amount_unit) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'statement import file, account and unit are immutable');
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'uploaded'  AND NEW.status IN ('parsed','rejected'))
    OR (OLD.status = 'parsed'    AND NEW.status IN ('validated','rejected'))
    OR (OLD.status = 'validated' AND NEW.status IN ('committed','parsed','rejected'))
    OR (OLD.status = 'committed' AND NEW.status = 'rejected')) THEN
    PERFORM core.raise_hk('HK_BNK_IMPORT_TRANSITION', format('statement import %s -> %s is not allowed', OLD.status, NEW.status));
  END IF;
  IF OLD.status = 'committed' AND NEW.status = 'rejected' AND EXISTS (
       SELECT 1 FROM treasury.recon_match_item i JOIN treasury.statement_line s ON s.tenant_id = i.tenant_id AND s.id = i.statement_line_id
        WHERE s.import_id = OLD.id AND i.is_active) THEN
    PERFORM core.raise_hk('HK_BNK_IMPORT_MATCHED', 'undo the matches of this import before rejecting it');
  END IF;
  IF NEW.status = 'committed' AND OLD.status <> 'committed' THEN
    NEW.continuity_ok := NOT EXISTS (SELECT 1 FROM treasury.statement_continuity_breaks(NEW.id));
    IF NOT NEW.continuity_ok AND char_length(btrim(coalesce(NEW.continuity_override_reason, ''))) < 5 THEN
      PERFORM core.raise_hk('HK_BNK_CONTINUITY', 'running balance breaks; fix the file or record an override reason');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.statement_import;
CREATE TRIGGER trg_guard BEFORE UPDATE ON treasury.statement_import FOR EACH ROW EXECUTE FUNCTION treasury.statement_import_guard();

CREATE OR REPLACE FUNCTION treasury.statement_import_after() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'rejected' AND OLD.status <> 'rejected' THEN
    UPDATE treasury.statement_line SET is_superseded = true WHERE tenant_id = NEW.tenant_id AND import_id = NEW.id;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_after ON treasury.statement_import;
CREATE TRIGGER trg_after AFTER UPDATE OF status ON treasury.statement_import FOR EACH ROW EXECUTE FUNCTION treasury.statement_import_after();
DROP TRIGGER IF EXISTS trg_no_delete ON treasury.statement_import;
CREATE TRIGGER trg_no_delete BEFORE DELETE ON treasury.statement_import FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

CREATE OR REPLACE FUNCTION treasury.statement_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE i treasury.statement_import; r record; v_active boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
  SELECT * INTO i FROM treasury.statement_import WHERE tenant_id = r.tenant_id AND id = r.import_id;
  IF TG_OP = 'INSERT' THEN
    IF i.status NOT IN ('uploaded','parsed','validated') OR NEW.bank_account_id <> i.bank_account_id OR NEW.is_superseded
       OR NEW.match_status <> 'unmatched' THEN
      PERFORM core.raise_hk('HK_BNK_LINE_STATE', 'lines are added unmatched to a non-committed import of the same bank account');
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE' THEN
    IF i.status IN ('committed','rejected') THEN
      PERFORM core.raise_hk('HK_BNK_LINE_STATE', 'lines of a committed or rejected import cannot be deleted');
    END IF;
    RETURN OLD;
  END IF;
  IF NEW.import_id <> OLD.import_id OR NEW.bank_account_id <> OLD.bank_account_id OR (OLD.is_superseded AND NOT NEW.is_superseded) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'statement line import/account are fixed and supersession is one-way');
  END IF;
  IF i.status IN ('committed','rejected')
     AND (to_jsonb(NEW) - ARRAY['match_status','ignored_reason','txn_class','suggested_party_id','is_superseded','updated_at',
                                'description_norm','signed_amount'])
         IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['match_status','ignored_reason','txn_class','suggested_party_id','is_superseded','updated_at',
                                'description_norm','signed_amount']) THEN
    PERFORM core.raise_hk('HK_BNK_LINE_STATE', 'data of a committed statement line is immutable');
  END IF;
  v_active := EXISTS (SELECT 1 FROM treasury.recon_match_item m WHERE m.tenant_id = NEW.tenant_id AND m.statement_line_id = NEW.id AND m.is_active);
  IF (NEW.match_status = 'matched') <> v_active THEN
    PERFORM core.raise_hk('HK_BNK_MATCH_STATUS', 'match_status is matched exactly when the line is in an active match');
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.statement_line;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON treasury.statement_line FOR EACH ROW EXECUTE FUNCTION treasury.statement_line_guard();

CREATE OR REPLACE FUNCTION treasury.recon_rule_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    PERFORM '' ~ NEW.pattern;
  EXCEPTION WHEN invalid_regular_expression THEN
    PERFORM core.raise_hk('HK_BNK_RULE_PATTERN', format('invalid regular expression: %s', NEW.pattern));
  END;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.recon_rule;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON treasury.recon_rule FOR EACH ROW EXECUTE FUNCTION treasury.recon_rule_guard();

-- قلم تطبیق: سطر صورتحساب کامل (مبلغ علامت‌دار) از ورود قطعی؛ سطر دفتری روی حساب دارایی غیرزیردفتری با بُعد مؤثر همین حساب بانکی
CREATE OR REPLACE FUNCTION treasury.recon_item_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE m treasury.recon_match; s treasury.statement_line; v_imp_status text; ba treasury.bank_account;
        jl record; v_ok boolean;
BEGIN
  SELECT * INTO m FROM treasury.recon_match WHERE tenant_id = NEW.tenant_id AND id = NEW.match_id;
  IF TG_OP = 'UPDATE' THEN
    IF (to_jsonb(NEW) - 'is_active') IS DISTINCT FROM (to_jsonb(OLD) - 'is_active') OR NOT (OLD.is_active AND NOT NEW.is_active)
       OR m.status <> 'undone' THEN
      PERFORM core.raise_hk('HK_BNK_MATCH_IMMUTABLE', 'match items are deactivated only by undoing their match');
    END IF;
    RETURN NEW;
  END IF;
  IF m.status <> 'active' OR NOT NEW.is_active THEN
    PERFORM core.raise_hk('HK_BNK_MATCH_STATE', 'items are added active to an active match');
  END IF;
  SELECT * INTO ba FROM treasury.bank_account WHERE tenant_id = NEW.tenant_id AND id = m.bank_account_id;
  IF NEW.side = 'statement' THEN
    SELECT * INTO s FROM treasury.statement_line WHERE tenant_id = NEW.tenant_id AND id = NEW.statement_line_id;
    SELECT status INTO v_imp_status FROM treasury.statement_import WHERE tenant_id = s.tenant_id AND id = s.import_id;
    IF s.bank_account_id <> m.bank_account_id OR s.is_superseded OR v_imp_status <> 'committed' OR s.match_status = 'ignored'
       OR NEW.amount <> s.signed_amount THEN
      PERFORM core.raise_hk('HK_BNK_MATCH_LINE', 'statement item must be a whole committed, non-ignored line of the match bank account');
    END IF;
  ELSE
    SELECT l.company_id, l.currency, l.debit_txn, l.credit_txn, l.debit_base, l.credit_base, l.dim1_id,
           j.status AS journal_status, a.account_type, a.subledger_kind,
           coalesce(dv.merged_into_id, dv.id) AS eff_dim
      INTO jl
      FROM ledger.journal_line l
      JOIN ledger.journal j ON j.tenant_id = l.tenant_id AND j.id = l.journal_id
      JOIN ledger.account a ON a.tenant_id = l.tenant_id AND a.id = l.account_id
      LEFT JOIN ledger.dimension_value dv ON dv.tenant_id = l.tenant_id AND dv.id = l.dim1_id
     WHERE l.tenant_id = NEW.tenant_id AND l.id = NEW.journal_line_id;
    v_ok := jl.company_id = m.company_id AND jl.journal_status <> 'voided' AND jl.account_type = 'asset'
            AND jl.subledger_kind IS NULL AND ba.dimension_value_id IS NOT NULL
            AND jl.eff_dim = (SELECT coalesce(d2.merged_into_id, d2.id) FROM ledger.dimension_value d2
                               WHERE d2.tenant_id = NEW.tenant_id AND d2.id = ba.dimension_value_id)
            AND jl.currency = ba.currency AND NEW.amount = jl.debit_txn - jl.credit_txn;
    IF v_ok IS NOT TRUE THEN
      PERFORM core.raise_hk('HK_BNK_MATCH_BOOK', 'book item must be a non-voided GL line on this bank account (asset, its dimension, its currency, full amount)');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.recon_match_item;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON treasury.recon_match_item FOR EACH ROW EXECUTE FUNCTION treasury.recon_item_guard();

CREATE OR REPLACE FUNCTION treasury.recon_item_after() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.statement_line_id IS NOT NULL THEN
    UPDATE treasury.statement_line SET match_status = CASE WHEN NEW.is_active THEN 'matched' ELSE 'unmatched' END
     WHERE tenant_id = NEW.tenant_id AND id = NEW.statement_line_id;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_after ON treasury.recon_match_item;
CREATE TRIGGER trg_after AFTER INSERT OR UPDATE OF is_active ON treasury.recon_match_item FOR EACH ROW EXECUTE FUNCTION treasury.recon_item_after();

CREATE OR REPLACE FUNCTION treasury.recon_match_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_final date;
BEGIN
  IF NOT (OLD.status = 'active' AND NEW.status = 'undone')
     OR (to_jsonb(NEW) - ARRAY['status','undone_by','undone_at','undo_reason'])
        IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','undone_by','undone_at','undo_reason']) THEN
    PERFORM core.raise_hk('HK_BNK_MATCH_IMMUTABLE', 'a match can only be undone');
  END IF;
  SELECT max(as_of) INTO v_final FROM treasury.bank_reconciliation
   WHERE tenant_id = OLD.tenant_id AND bank_account_id = OLD.bank_account_id AND status = 'finalized';
  IF v_final IS NOT NULL AND EXISTS (
       SELECT 1 FROM treasury.recon_match_item i JOIN treasury.statement_line s ON s.tenant_id = i.tenant_id AND s.id = i.statement_line_id
        WHERE i.tenant_id = OLD.tenant_id AND i.match_id = OLD.id AND s.txn_date <= v_final) THEN
    PERFORM core.raise_hk('HK_BNK_RECON_FINALIZED', format('match covers lines on or before the finalized reconciliation of %s', v_final));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.recon_match;
CREATE TRIGGER trg_guard BEFORE UPDATE ON treasury.recon_match FOR EACH ROW EXECUTE FUNCTION treasury.recon_match_guard();

CREATE OR REPLACE FUNCTION treasury.recon_match_after() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'undone' AND OLD.status = 'active' THEN
    UPDATE treasury.recon_match_item SET is_active = false WHERE tenant_id = NEW.tenant_id AND match_id = NEW.id AND is_active;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_after ON treasury.recon_match;
CREATE TRIGGER trg_after AFTER UPDATE OF status ON treasury.recon_match FOR EACH ROW EXECUTE FUNCTION treasury.recon_match_after();

-- در commit: هر گروه تطبیق فعال دو طرف دارد و جمع علامت‌دار دو طرف برابر است
CREATE OR REPLACE FUNCTION treasury.recon_match_check() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_match uuid; v_status text; v_s numeric; v_b numeric; v_ns int; v_nb int;
BEGIN
  v_match := CASE TG_TABLE_NAME WHEN 'recon_match' THEN NEW.id ELSE (to_jsonb(NEW) ->> 'match_id')::uuid END;
  SELECT status INTO v_status FROM treasury.recon_match WHERE tenant_id = NEW.tenant_id AND id = v_match;
  IF v_status <> 'active' THEN RETURN NULL; END IF;
  SELECT coalesce(sum(amount) FILTER (WHERE side = 'statement'), 0), coalesce(sum(amount) FILTER (WHERE side = 'book'), 0),
         count(*) FILTER (WHERE side = 'statement'), count(*) FILTER (WHERE side = 'book')
    INTO v_s, v_b, v_ns, v_nb
    FROM treasury.recon_match_item WHERE tenant_id = NEW.tenant_id AND match_id = v_match AND is_active;
  IF v_ns = 0 OR v_nb = 0 OR v_s <> v_b THEN
    PERFORM core.raise_hk('HK_BNK_MATCH_UNBALANCED', format('match %s: statement %s (%s lines) <> book %s (%s lines)', v_match, v_s, v_ns, v_b, v_nb));
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_check ON treasury.recon_match;
CREATE CONSTRAINT TRIGGER trg_check AFTER INSERT ON treasury.recon_match
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION treasury.recon_match_check();
DROP TRIGGER IF EXISTS trg_check ON treasury.recon_match_item;
CREATE CONSTRAINT TRIGGER trg_check AFTER INSERT ON treasury.recon_match_item
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION treasury.recon_match_check();

CREATE OR REPLACE FUNCTION treasury.bank_reconciliation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'finalized' THEN
    PERFORM core.raise_hk('HK_BNK_RECON_FINALIZED', 'a finalized bank reconciliation is immutable');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON treasury.bank_reconciliation;
CREATE TRIGGER trg_guard BEFORE UPDATE ON treasury.bank_reconciliation FOR EACH ROW EXECUTE FUNCTION treasury.bank_reconciliation_guard();

-- =====================================================================
-- ۱۲. ویوها و توابع منتشرشدهٔ treasury
-- =====================================================================
CREATE OR REPLACE VIEW treasury.v_open_item WITH (security_invoker = true) AS
  SELECT o.tenant_id, o.id, o.company_id, o.party_id, treasury.canonical_party(o.tenant_id, o.party_id) AS canonical_party_id,
         o.party_role, o.account_class, o.direction, o.source_module, o.source_doc_type, o.source_doc_id, o.source_doc_no,
         o.doc_date, o.due_date, o.currency, o.amount, o.allocated_amount, o.amount - o.allocated_amount AS outstanding, o.status
    FROM treasury.open_item o;

-- سررسید چک‌ها (دریافتی و پرداختی) برای گزارش، پیش‌بینی جریان نقد و یادآور
CREATE OR REPLACE VIEW treasury.v_cheque_due WITH (security_invoker = true) AS
  SELECT c.tenant_id, c.id AS cheque_id, c.company_id, c.direction, c.purpose, c.state, c.due_date, c.amount,
         c.amount - c.collected_amount AS outstanding, c.currency, c.sayad_id, c.serial_no,
         coalesce(c.received_from_party_id, c.payee_party_id) AS party_id, c.bank_account_id, c.deposit_bank_account_id,
         c.sayad_state, c.sayad_color_code
    FROM treasury.cheque c
    JOIN treasury.cheque_state s ON s.direction = c.direction AND s.purpose = c.purpose AND s.state = c.state
   WHERE s.is_holding;

-- مصرف اعتبار شخص از چک‌ها (برای کنترل اعتبار sales): وصول‌نشده و برگشتی، به شخص مؤثر
CREATE OR REPLACE VIEW treasury.v_party_cheque_exposure WITH (security_invoker = true) AS
  SELECT c.tenant_id, c.company_id, treasury.canonical_party(c.tenant_id, c.received_from_party_id) AS party_id, c.currency,
         sum(c.amount - c.collected_amount) FILTER (WHERE c.state IN ('in_hand','deposited')) AS uncleared_amount,
         sum(c.amount - c.collected_amount) FILTER (WHERE c.state IN ('bounced','partially_collected','returned_by_third_party')) AS bounced_amount,
         count(*) FILTER (WHERE c.state IN ('bounced','partially_collected','returned_by_third_party')) AS bounced_count
    FROM treasury.cheque c
   WHERE c.direction = 'received' AND c.purpose = 'payment' AND c.received_from_party_id IS NOT NULL
   GROUP BY 1, 2, 3, 4;

-- گزارش سنی حساب واسط کارتخوان (تراکنش تأییدشدهٔ تسویه‌نشده)
CREATE OR REPLACE VIEW treasury.v_card_clearing_aging WITH (security_invoker = true) AS
  SELECT t.tenant_id, t.company_id, t.card_terminal_id, t.business_date, count(*) AS txn_count, sum(t.amount) AS amount
    FROM treasury.card_txn t
   WHERE t.status = 'approved' AND t.settlement_id IS NULL
   GROUP BY 1, 2, 3, 4;

-- زیردفتر چک برای ledger.check_control_accounts: وضعیت هر چک در تاریخ = آخرین رویداد تا آن تاریخ (تاریخ رویدادها یکنواخت است)
CREATE OR REPLACE FUNCTION treasury.cheque_holdings(p_kind text, p_company_id uuid, p_as_of date)
RETURNS TABLE (account_id uuid, dim_value_id uuid, currency char(3), balance_base numeric, balance_txn numeric)
LANGUAGE sql STABLE AS $$
  WITH last_ev AS (
    SELECT DISTINCT ON (e.cheque_id) e.cheque_id, e.holding_account_id, e.holding_dim_value_id, e.holding_amount,
           e.holding_amount_base, c.currency
      FROM treasury.cheque_event e
      JOIN treasury.cheque c ON c.tenant_id = e.tenant_id AND c.id = e.cheque_id
     WHERE c.company_id = p_company_id AND e.event_date <= p_as_of
       AND ((p_kind = 'cheque_receivable'  AND c.direction = 'received' AND c.purpose = 'payment')
         OR (p_kind = 'cheque_payable'     AND c.direction = 'issued'   AND c.purpose = 'payment')
         OR (p_kind = 'guarantee_received' AND c.direction = 'received' AND c.purpose = 'guarantee')
         OR (p_kind = 'guarantee_given'    AND c.direction = 'issued'   AND c.purpose = 'guarantee'))
     ORDER BY e.cheque_id, e.seq DESC)
  SELECT l.holding_account_id, coalesce(dv.merged_into_id, dv.id), l.currency,
         sum(l.holding_amount_base), sum(l.holding_amount)
    FROM last_ev l
    JOIN ledger.account a ON a.id = l.holding_account_id AND a.subledger_kind = p_kind
    LEFT JOIN ledger.dimension_value dv ON dv.id = l.holding_dim_value_id
   WHERE l.holding_account_id IS NOT NULL
   GROUP BY 1, 2, 3
$$;
CREATE OR REPLACE FUNCTION treasury.subledger_cheque_receivable(p_company_id uuid, p_as_of date)
RETURNS TABLE (account_id uuid, dim_value_id uuid, currency char(3), balance_base numeric, balance_txn numeric)
LANGUAGE sql STABLE AS $$ SELECT * FROM treasury.cheque_holdings('cheque_receivable', p_company_id, p_as_of) $$;
CREATE OR REPLACE FUNCTION treasury.subledger_cheque_payable(p_company_id uuid, p_as_of date)
RETURNS TABLE (account_id uuid, dim_value_id uuid, currency char(3), balance_base numeric, balance_txn numeric)
LANGUAGE sql STABLE AS $$ SELECT * FROM treasury.cheque_holdings('cheque_payable', p_company_id, p_as_of) $$;
CREATE OR REPLACE FUNCTION treasury.subledger_guarantee_received(p_company_id uuid, p_as_of date)
RETURNS TABLE (account_id uuid, dim_value_id uuid, currency char(3), balance_base numeric, balance_txn numeric)
LANGUAGE sql STABLE AS $$ SELECT * FROM treasury.cheque_holdings('guarantee_received', p_company_id, p_as_of) $$;
CREATE OR REPLACE FUNCTION treasury.subledger_guarantee_given(p_company_id uuid, p_as_of date)
RETURNS TABLE (account_id uuid, dim_value_id uuid, currency char(3), balance_base numeric, balance_txn numeric)
LANGUAGE sql STABLE AS $$ SELECT * FROM treasury.cheque_holdings('guarantee_given', p_company_id, p_as_of) $$;

-- =====================================================================
-- ۱۳. صندوق فروشگاهی (pos) — کاتالوگ نوع فرمان
-- =====================================================================
CREATE TABLE IF NOT EXISTS pos.command_type (
  type             text NOT NULL CHECK (type ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,2}$'),
  schema_version   smallint NOT NULL CHECK (schema_version >= 1),
  money_moving     boolean NOT NULL,
  requires_shift   boolean NOT NULL,
  allowed_offline  boolean NOT NULL,
  edge_only        boolean NOT NULL DEFAULT false,
  description      text NOT NULL,
  introduced_in    text NOT NULL,
  deprecated_at    timestamptz,
  PRIMARY KEY (type, schema_version)
);
INSERT INTO pos.command_type (type, schema_version, money_moving, requires_shift, allowed_offline, edge_only, description, introduced_in) VALUES
  ('business_day.opened',     1, false, false, true,  false, 'open business day of the branch (idempotent per branch+date)', '1.0'),
  ('business_day.closed',     1, false, false, true,  false, 'close business day', '1.0'),
  ('shift.opened',            1, true,  false, true,  false, 'open shift with opening float and cash count', '1.0'),
  ('shift.closed',            1, true,  true,  true,  false, 'close shift with counted cash, card terminal totals', '1.0'),
  ('cash.moved',              1, true,  true,  true,  false, 'pay-in, pay-out, drop or pickup of drawer cash', '1.0'),
  ('sale.completed',          1, true,  true,  true,  false, 'completed sale ticket with lines and payments', '1.0'),
  ('return.completed',        1, true,  true,  true,  false, 'return ticket referencing original lines', '1.0'),
  ('exchange.completed',      1, true,  true,  true,  false, 'exchange ticket (return + sale lines, net payment)', '1.0'),
  ('order.upserted',          1, false, false, true,  false, 'open order (table/hold) full state with version', '1.0'),
  ('order.voided',            1, false, false, true,  false, 'void open order (reason; kitchen-sent lines become waste)', '1.0'),
  ('kitchen.sent',            1, false, false, true,  false, 'lines/course fired to preparation stations', '1.0'),
  ('card.payment_started',    1, false, true,  true,  false, 'card payment intent before calling PSP (for unknown-result recovery)', '1.0'),
  ('card.payment_resolved',   1, false, true,  true,  false, 'resolution of an unknown card result via lastTransaction or manual match', '1.0'),
  ('customer.created',        1, false, false, true,  false, 'customer created offline with client UUID', '1.0'),
  ('offline.session_started', 1, false, false, true,  false, 'device went offline (limits start)', '1.0'),
  ('offline.session_ended',   1, false, false, true,  false, 'device back online with offline totals', '1.0'),
  ('receipt.number_voided',   1, false, false, true,  false, 'device receipt number voided (printer jam, crash)', '1.0'),
  ('tax.serial_voided',       1, false, false, true,  false, 'offline tax serial burned without invoice', '1.0'),
  ('device.clock_report',     1, false, false, true,  false, 'device clock vs NTP/server report', '1.0'),
  ('table.transferred',       1, false, false, true,  true,  'move/merge table orders (edge or online)', '1.0')
ON CONFLICT DO NOTHING;

-- =====================================================================
-- ۱۴. pos — پایانه، لبه، روز کاری، شیفت، نقد
-- =====================================================================
-- سرور لبهٔ فروشگاه (v2؛ اسکیمای v1). کلید عمومی خودش را دارد و پاکت دستهٔ پایانه‌ها را امضا می‌کند.
CREATE TABLE IF NOT EXISTS pos.edge_node (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  company_id            uuid NOT NULL,
  branch_id             uuid NOT NULL,
  name                  text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 100),
  key_alg               text NOT NULL DEFAULT 'ed25519' CHECK (key_alg IN ('ed25519','ecdsa_p256')),
  public_key            bytea UNIQUE,
  status                text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','active','revoked')),
  enrollment_code_hash  bytea CHECK (enrollment_code_hash IS NULL OR octet_length(enrollment_code_hash) = 32),
  last_seen_at          timestamptz,
  app_version           text,
  revoked_at            timestamptz,
  revoke_reason         text,
  created_by            uuid,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT edge_key CHECK (public_key IS NULL OR (key_alg = 'ed25519' AND octet_length(public_key) = 32)
                             OR (key_alg = 'ecdsa_p256' AND octet_length(public_key) = 65 AND get_byte(public_key, 0) = 4)),
  CONSTRAINT edge_active CHECK (status <> 'active' OR public_key IS NOT NULL),
  CONSTRAINT edge_revoked CHECK ((status = 'revoked') = (revoked_at IS NOT NULL AND revoke_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('pos.edge_node');

-- ایستگاه صندوق. دستگاه (core.device) هویت و کلید را دارد؛ این جدول پیکربندی فروش را.
CREATE TABLE IF NOT EXISTS pos.terminal (
  tenant_id                 uuid NOT NULL REFERENCES core.tenant(id),
  id                        uuid NOT NULL DEFAULT uuidv7(),
  company_id                uuid NOT NULL,
  branch_id                 uuid NOT NULL,
  code                      text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,15}$'),
  name                      text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 100),
  device_id                 uuid,
  status                    text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled','retired')),
  cash_box_id               uuid NOT NULL,
  default_card_terminal_id  uuid,
  receipt_series_id         uuid NOT NULL,
  warehouse_id              uuid,                       -- inventory.warehouse (FK در 99_cross_fk)
  price_list_id             uuid,
  walk_in_party_id          uuid NOT NULL,              -- «مشتری عمومی/نقدی» (parties.party.is_anonymous)
  service_modes             text[] NOT NULL DEFAULT '{retail}'
                            CHECK (cardinality(service_modes) >= 1 AND service_modes <@ ARRAY['retail','dine_in','takeaway','delivery']::text[]),
  tax_mode                  text NOT NULL DEFAULT 'none' CHECK (tax_mode IN ('none','online','device_memory','reserved_range')),
  tax_memory_ref            uuid,                       -- tax.memory (FK در 99_cross_fk)
  tax_serial_series_id      uuid,
  offline_policy            jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(offline_policy) = 'object'),
  edge_node_id              uuid,
  config_version            integer NOT NULL DEFAULT 1 CHECK (config_version >= 1),
  created_by                uuid,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  row_version               integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, cash_box_id) REFERENCES treasury.cash_box(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, default_card_terminal_id) REFERENCES treasury.card_terminal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, receipt_series_id) REFERENCES core.number_series(tenant_id, id),
  FOREIGN KEY (tenant_id, price_list_id) REFERENCES catalog.price_list(tenant_id, id),
  FOREIGN KEY (tenant_id, walk_in_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, tax_serial_series_id) REFERENCES core.number_series(tenant_id, id),
  FOREIGN KEY (tenant_id, edge_node_id) REFERENCES pos.edge_node(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT terminal_active_device CHECK (status <> 'active' OR device_id IS NOT NULL),
  CONSTRAINT terminal_tax_memory CHECK (tax_mode IN ('none','online') OR tax_memory_ref IS NOT NULL),
  CONSTRAINT terminal_tax_range CHECK (tax_mode <> 'reserved_range' OR tax_serial_series_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('pos.terminal');
CREATE UNIQUE INDEX IF NOT EXISTS terminal_device_active_uq ON pos.terminal (tenant_id, device_id) WHERE status = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS terminal_cash_box_active_uq ON pos.terminal (tenant_id, cash_box_id) WHERE status = 'active';

-- روز کاری شعبه (ممکن است از نیمه‌شب بگذرد). تاریخ ثبت فروش = business_date.
CREATE TABLE IF NOT EXISTS pos.business_day (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  company_id          uuid NOT NULL,
  branch_id           uuid NOT NULL,
  business_date       date NOT NULL,
  status              text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  opened_at           timestamptz NOT NULL,
  opened_by           uuid,
  opened_on_device_id uuid,
  closed_at           timestamptz,
  closed_by           uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, branch_id, business_date),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, opened_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, closed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, opened_on_device_id) REFERENCES core.device(tenant_id, id),
  CONSTRAINT business_day_closed CHECK ((status = 'closed') = (closed_at IS NOT NULL) AND (closed_at IS NULL OR closed_at >= opened_at))
);
SELECT core.enable_tenant_rls('pos.business_day');
CREATE UNIQUE INDEX IF NOT EXISTS business_day_one_open_uq ON pos.business_day (tenant_id, branch_id) WHERE status = 'open';

CREATE TABLE IF NOT EXISTS pos.shift (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL,                       -- UUIDv7 ساخت دستگاه (idempotent)
  company_id           uuid NOT NULL,
  branch_id            uuid NOT NULL,
  terminal_id          uuid NOT NULL,
  business_day_id      uuid NOT NULL,
  cash_box_id          uuid NOT NULL,
  opened_by            uuid NOT NULL,
  opened_at            timestamptz NOT NULL,
  opened_received_at   timestamptz NOT NULL DEFAULT now(),
  opening_float        core.amount NOT NULL CHECK (opening_float >= 0),
  status               text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  closed_by            uuid,
  closed_at            timestamptz,
  expected_cash        core.amount,
  counted_cash         core.amount CHECK (counted_cash >= 0),
  over_short           core.amount,
  cash_count_id        uuid,
  opened_offline       boolean NOT NULL DEFAULT false,
  open_cmd_id          uuid NOT NULL,
  close_cmd_id         uuid,
  ticket_count         integer CHECK (ticket_count >= 0),
  net_sales            core.amount,
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, terminal_id) REFERENCES pos.terminal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, business_day_id) REFERENCES pos.business_day(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, cash_box_id) REFERENCES treasury.cash_box(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, opened_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, closed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, company_id, cash_count_id) REFERENCES treasury.cash_count(tenant_id, company_id, id),
  CONSTRAINT shift_closed CHECK ((status = 'closed') = (closed_at IS NOT NULL AND counted_cash IS NOT NULL
                                                       AND expected_cash IS NOT NULL AND close_cmd_id IS NOT NULL AND closed_by IS NOT NULL)),
  CONSTRAINT shift_over_short CHECK (over_short IS NULL OR over_short = counted_cash - expected_cash),
  CONSTRAINT shift_time CHECK (closed_at IS NULL OR closed_at >= opened_at)
);
SELECT core.enable_tenant_rls('pos.shift');
CREATE UNIQUE INDEX IF NOT EXISTS shift_one_open_uq ON pos.shift (tenant_id, terminal_id) WHERE status = 'open';

-- شمارش اسکناس (باز، بستن، تخلیه) — فقط‌افزودنی
CREATE TABLE IF NOT EXISTS pos.shift_count (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  shift_id      uuid NOT NULL,
  kind          text NOT NULL CHECK (kind IN ('open','close','drop','pickup')),
  denomination  core.amount NOT NULL CHECK (denomination > 0),
  qty           integer NOT NULL CHECK (qty >= 0),
  currency      char(3) NOT NULL DEFAULT 'IRR' REFERENCES ref.currency(code),
  cmd_id        uuid NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, shift_id, kind, cmd_id, denomination, currency),
  FOREIGN KEY (tenant_id, shift_id) REFERENCES pos.shift(tenant_id, id)
);
SELECT core.enable_tenant_rls('pos.shift_count');

-- ورود/خروج نقد کشو در شیفت. سند خزانه (پرداخت متفرقه یا انتقال به گاوصندوق) پس از دریافت ساخته می‌شود.
CREATE TABLE IF NOT EXISTS pos.cash_movement (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL,
  shift_id           uuid NOT NULL,
  kind               text NOT NULL CHECK (kind IN ('pay_in','pay_out','drop','pickup')),
  amount             core.amount NOT NULL CHECK (amount > 0),
  reason             text NOT NULL CHECK (char_length(reason) BETWEEN 3 AND 300),
  occurred_at        timestamptz NOT NULL,
  posting_key        text REFERENCES ledger.posting_key(key),
  target_cash_box_id uuid,
  money_document_id  uuid,
  fund_transfer_id   uuid,
  cmd_id             uuid NOT NULL,
  actor_id           uuid,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, cmd_id),
  FOREIGN KEY (tenant_id, shift_id) REFERENCES pos.shift(tenant_id, id),
  FOREIGN KEY (tenant_id, target_cash_box_id) REFERENCES treasury.cash_box(tenant_id, id),
  FOREIGN KEY (tenant_id, money_document_id) REFERENCES treasury.money_document(tenant_id, id),
  FOREIGN KEY (tenant_id, fund_transfer_id) REFERENCES treasury.fund_transfer(tenant_id, id),
  FOREIGN KEY (tenant_id, actor_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT cash_movement_target CHECK ((kind IN ('drop','pickup')) = (target_cash_box_id IS NOT NULL)),
  CONSTRAINT cash_movement_counter CHECK (kind IN ('drop','pickup') OR posting_key IS NOT NULL),
  CONSTRAINT cash_movement_doc CHECK (num_nonnulls(money_document_id, fund_transfer_id) <= 1)
);
SELECT core.enable_tenant_rls('pos.cash_movement');

-- =====================================================================
-- ۱۵. pos — رستوران و چیدمان: سالن، میز، ایستگاه، چاپگر، modifier
-- =====================================================================
CREATE TABLE IF NOT EXISTS pos.floor (
  tenant_id   uuid NOT NULL REFERENCES core.tenant(id),
  id          uuid NOT NULL DEFAULT uuidv7(),
  company_id  uuid NOT NULL,
  branch_id   uuid NOT NULL,
  code        text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,15}$'),
  name        text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 100),
  sort_order  smallint NOT NULL DEFAULT 0,
  is_active   boolean NOT NULL DEFAULT true,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  row_version integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, branch_id, code),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id)
);
SELECT core.enable_tenant_rls('pos.floor');

CREATE TABLE IF NOT EXISTS pos.dining_table (
  tenant_id   uuid NOT NULL REFERENCES core.tenant(id),
  id          uuid NOT NULL DEFAULT uuidv7(),
  floor_id    uuid NOT NULL,
  code        text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,15}$'),
  seats       smallint NOT NULL DEFAULT 2 CHECK (seats BETWEEN 1 AND 100),
  layout      jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(layout) = 'object'),
  is_active   boolean NOT NULL DEFAULT true,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  row_version integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, floor_id, code),
  FOREIGN KEY (tenant_id, floor_id) REFERENCES pos.floor(tenant_id, id)
);
SELECT core.enable_tenant_rls('pos.dining_table');

CREATE TABLE IF NOT EXISTS pos.station (
  tenant_id   uuid NOT NULL REFERENCES core.tenant(id),
  id          uuid NOT NULL DEFAULT uuidv7(),
  company_id  uuid NOT NULL,
  branch_id   uuid NOT NULL,
  code        text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,15}$'),
  name        text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 100),
  kind        text NOT NULL DEFAULT 'kitchen' CHECK (kind IN ('kitchen','bar','pastry','grill','other')),
  is_active   boolean NOT NULL DEFAULT true,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  row_version integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, branch_id, code),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id)
);
SELECT core.enable_tenant_rls('pos.station');

-- مسیر ایستگاه: کالا یا دسته → ایستگاه آماده‌سازی (قوی‌تر: کالا بر دسته؛ سپس priority)
CREATE TABLE IF NOT EXISTS pos.station_route (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  station_id   uuid NOT NULL,
  item_id      uuid,
  category_id  uuid,
  priority     smallint NOT NULL DEFAULT 100,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, station_id, item_id, category_id),
  FOREIGN KEY (tenant_id, station_id) REFERENCES pos.station(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id),
  FOREIGN KEY (tenant_id, category_id) REFERENCES catalog.item_category(tenant_id, id),
  CONSTRAINT station_route_target CHECK (num_nonnulls(item_id, category_id) = 1)
);
SELECT core.enable_tenant_rls('pos.station_route');

CREATE TABLE IF NOT EXISTS pos.printer (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  company_id     uuid NOT NULL,
  branch_id      uuid NOT NULL,
  name           text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
  purpose        text NOT NULL CHECK (purpose IN ('receipt','station','label')),
  terminal_id    uuid,
  edge_node_id   uuid,
  station_id     uuid,
  transport      text NOT NULL CHECK (transport IN ('usb','tcp','serial','bt','builtin','bridge')),
  address        text CHECK (char_length(address) <= 200),
  dots_per_line  smallint NOT NULL DEFAULT 576 CHECK (dots_per_line BETWEEN 200 AND 2400),
  has_cutter     boolean NOT NULL DEFAULT true,
  has_drawer     boolean NOT NULL DEFAULT false,
  is_active      boolean NOT NULL DEFAULT true,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, terminal_id) REFERENCES pos.terminal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, edge_node_id) REFERENCES pos.edge_node(tenant_id, id),
  FOREIGN KEY (tenant_id, station_id) REFERENCES pos.station(tenant_id, id),
  CONSTRAINT printer_host CHECK (num_nonnulls(terminal_id, edge_node_id) = 1),
  CONSTRAINT printer_station CHECK ((purpose = 'station') = (station_id IS NOT NULL))
);
SELECT core.enable_tenant_rls('pos.printer');

-- modifier: گزینه = SKU (کالای non_stock با دستور پخت خودش؛ قیمت از فهرست قیمت)
CREATE TABLE IF NOT EXISTS pos.modifier_group (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  code         text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$'),
  name         text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 100),
  min_select   smallint NOT NULL DEFAULT 0 CHECK (min_select >= 0),
  max_select   smallint NOT NULL DEFAULT 1 CHECK (max_select >= 1),
  is_active    boolean NOT NULL DEFAULT true,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  CONSTRAINT modifier_group_range CHECK (min_select <= max_select)
);
SELECT core.enable_tenant_rls('pos.modifier_group');

CREATE TABLE IF NOT EXISTS pos.modifier_option (
  tenant_id   uuid NOT NULL REFERENCES core.tenant(id),
  id          uuid NOT NULL DEFAULT uuidv7(),
  group_id    uuid NOT NULL,
  item_id     uuid NOT NULL,
  variant_id  uuid NOT NULL,
  sort_order  smallint NOT NULL DEFAULT 0,
  is_default  boolean NOT NULL DEFAULT false,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, group_id, variant_id),
  FOREIGN KEY (tenant_id, group_id) REFERENCES pos.modifier_group(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id)
);
SELECT core.enable_tenant_rls('pos.modifier_option');

CREATE TABLE IF NOT EXISTS pos.item_modifier_group (
  tenant_id   uuid NOT NULL REFERENCES core.tenant(id),
  id          uuid NOT NULL DEFAULT uuidv7(),
  item_id     uuid NOT NULL,
  group_id    uuid NOT NULL,
  sort_order  smallint NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, item_id, group_id),
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, group_id) REFERENCES pos.modifier_group(tenant_id, id) ON DELETE CASCADE
);
SELECT core.enable_tenant_rls('pos.item_modifier_group');

-- =====================================================================
-- ۱۶. pos — همگام‌سازی آفلاین: وضعیت دستگاه، دسته، فرمان امضاشده، نتیجه، کسری، نام مستعار، جریان‌ها
-- =====================================================================
-- hash آغاز زنجیرهٔ هر دستگاه (prev_hash فرمان ۱): وابسته به شناسهٔ دستگاه تا زنجیرهٔ دستگاه دیگر بازپخش نشود
CREATE OR REPLACE FUNCTION pos.genesis_hash(p_device_id uuid) RETURNS bytea
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT sha256(convert_to('hk-pos-genesis:v1:' || p_device_id::text, 'UTF8'))
$$;

CREATE TABLE IF NOT EXISTS pos.device_sync_state (
  tenant_id                uuid NOT NULL REFERENCES core.tenant(id),
  id                       uuid NOT NULL DEFAULT uuidv7(),
  device_id                uuid NOT NULL,
  terminal_id              uuid,
  last_seq                 bigint NOT NULL DEFAULT 0 CHECK (last_seq >= 0),
  last_hash                bytea NOT NULL CHECK (octet_length(last_hash) = 32),
  last_cmd_received_at     timestamptz,
  last_push_at             timestamptz,
  last_clock_offset_ms     integer,
  max_abs_clock_offset_ms  integer CHECK (max_abs_clock_offset_ms >= 0),
  highest_occurred_at      timestamptz,
  status                   text NOT NULL DEFAULT 'ok' CHECK (status IN ('ok','quarantined','retired')),
  quarantine_reason        text,
  updated_at               timestamptz NOT NULL DEFAULT now(),
  row_version              integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, device_id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, terminal_id) REFERENCES pos.terminal(tenant_id, id),
  CONSTRAINT sync_state_quarantine CHECK ((status = 'quarantined') = (quarantine_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('pos.device_sync_state');

-- پاکت دسته (فقط‌افزودنی): درج پیش از فرمان‌ها؛ via_edge_node_id یعنی از سرور لبه رله شده و edge_sig دارد
CREATE TABLE IF NOT EXISTS pos.sync_batch (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  device_id         uuid NOT NULL,
  client_batch_id   uuid NOT NULL,
  via_edge_node_id  uuid,
  edge_sig          bytea CHECK (edge_sig IS NULL OR octet_length(edge_sig) = 64),
  received_at       timestamptz NOT NULL DEFAULT now(),
  device_sent_at    timestamptz NOT NULL,
  clock_offset_ms   integer NOT NULL,
  first_seq         bigint NOT NULL CHECK (first_seq >= 1),
  last_seq          bigint NOT NULL,
  command_count     integer NOT NULL CHECK (command_count BETWEEN 1 AND 1000),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, device_id, client_batch_id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, via_edge_node_id) REFERENCES pos.edge_node(tenant_id, id),
  CONSTRAINT sync_batch_range CHECK (last_seq >= first_seq AND last_seq - first_seq + 1 = command_count),
  CONSTRAINT sync_batch_edge CHECK ((via_edge_node_id IS NULL) = (edge_sig IS NULL))
);
SELECT core.enable_tenant_rls('pos.sync_batch');

-- فرمان دستگاه (فقط‌افزودنی). body = JSON کانونی (RFC 8785) بدون امضا؛ hash = sha256(body)؛ sig = امضای ۶۴ بایتی hash.
-- پیوستگی device_seq و زنجیرهٔ prev_hash در پایگاه داده اجبار می‌شود؛ امضا در سرویس سنجیده می‌شود.
CREATE TABLE IF NOT EXISTS pos.device_command (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  device_id        uuid NOT NULL,
  device_seq       bigint NOT NULL CHECK (device_seq >= 1),
  cmd_id           uuid NOT NULL,
  type             text NOT NULL,
  schema_version   smallint NOT NULL,
  occurred_at      timestamptz NOT NULL,
  received_at      timestamptz NOT NULL DEFAULT now(),
  clock_offset_ms  integer NOT NULL DEFAULT 0,
  body             text NOT NULL CHECK (char_length(body) BETWEEN 2 AND 262144),
  payload          jsonb GENERATED ALWAYS AS ((body::jsonb) -> 'payload') STORED,
  prev_hash        bytea NOT NULL CHECK (octet_length(prev_hash) = 32),
  hash             bytea NOT NULL CHECK (octet_length(hash) = 32),
  sig              bytea NOT NULL CHECK (octet_length(sig) = 64),
  sig_alg          text NOT NULL CHECK (sig_alg IN ('ed25519','ecdsa_p256')),
  batch_id         uuid NOT NULL,
  edge_node_id     uuid,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, cmd_id),
  UNIQUE (tenant_id, device_id, device_seq),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (type, schema_version) REFERENCES pos.command_type(type, schema_version),
  FOREIGN KEY (tenant_id, batch_id) REFERENCES pos.sync_batch(tenant_id, id),
  FOREIGN KEY (tenant_id, edge_node_id) REFERENCES pos.edge_node(tenant_id, id),
  CONSTRAINT device_command_hash CHECK (hash = sha256(convert_to(body, 'UTF8')))
);
SELECT core.enable_tenant_rls('pos.device_command');

-- نتیجهٔ پردازش هر فرمان (یک ردیف، با تریگر هم‌زمان با فرمان ساخته می‌شود)
CREATE TABLE IF NOT EXISTS pos.command_outcome (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  command_id       uuid NOT NULL,
  device_id        uuid NOT NULL,
  device_seq       bigint NOT NULL,
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','deferred','applied','review','rejected')),
  error_code       text CHECK (error_code ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
  error_detail     jsonb,
  produced         jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(produced) = 'object'),
  attempts         integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at  timestamptz,
  processed_at     timestamptz,
  resolved_by      uuid,
  resolved_at      timestamptz,
  resolution_note  text,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, command_id),
  UNIQUE (tenant_id, device_id, device_seq),
  FOREIGN KEY (tenant_id, command_id) REFERENCES pos.device_command(tenant_id, id),
  FOREIGN KEY (tenant_id, resolved_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT outcome_error CHECK ((status IN ('review','rejected','deferred')) <= (error_code IS NOT NULL)),
  CONSTRAINT outcome_processed CHECK (status = 'pending' OR processed_at IS NOT NULL)
);
SELECT core.enable_tenant_rls('pos.command_outcome');
CREATE INDEX IF NOT EXISTS command_outcome_queue_idx ON pos.command_outcome (tenant_id, device_id, device_seq)
  WHERE status IN ('pending','deferred');
CREATE INDEX IF NOT EXISTS command_outcome_review_idx ON pos.command_outcome (tenant_id, status) WHERE status = 'review';

-- بازهٔ device_seq اعلام‌شده به‌عنوان «از دست رفته» (دستگاه از دست رفته یا پاک‌شده؛ فقط برای دستگاه بازنشسته)
CREATE TABLE IF NOT EXISTS pos.device_seq_gap (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  device_id    uuid NOT NULL,
  from_seq     bigint NOT NULL CHECK (from_seq >= 1),
  to_seq       bigint,
  reason       text NOT NULL CHECK (char_length(reason) >= 10),
  declared_by  uuid NOT NULL,
  declared_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, declared_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT seq_gap_range CHECK (to_seq IS NULL OR to_seq >= from_seq)
);
SELECT core.enable_tenant_rls('pos.device_seq_gap');

-- شناسهٔ ساخت کلاینت → شناسهٔ مرجع سرور (مثلاً مشتری آفلاین با کد ملی موجود)
CREATE TABLE IF NOT EXISTS pos.client_id_alias (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  entity_type   text NOT NULL CHECK (entity_type IN ('party','open_order','ticket')),
  client_id     uuid NOT NULL,
  canonical_id  uuid NOT NULL,
  device_id     uuid NOT NULL,
  reason        text NOT NULL CHECK (reason IN ('duplicate_national_id','merged_party','manual')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, entity_type, client_id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  CONSTRAINT alias_not_self CHECK (client_id <> canonical_id)
);
SELECT core.enable_tenant_rls('pos.client_id_alias');

-- نشست آفلاین گزارش‌شدهٔ دستگاه (سقف زمان از شروع نشست، سقف مبلغ و نسیه؛ snapshot سیاست)
CREATE TABLE IF NOT EXISTS pos.offline_session (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL,
  device_id         uuid NOT NULL,
  terminal_id       uuid NOT NULL,
  started_at        timestamptz NOT NULL,
  ended_at          timestamptz,
  max_hours         smallint NOT NULL CHECK (max_hours BETWEEN 1 AND 720),
  amount_cap        core.amount CHECK (amount_cap > 0),
  credit_cap        core.amount CHECK (credit_cap >= 0),
  sales_count       integer NOT NULL DEFAULT 0 CHECK (sales_count >= 0),
  sales_amount      core.amount NOT NULL DEFAULT 0,
  credit_amount     core.amount NOT NULL DEFAULT 0 CHECK (credit_amount >= 0),
  limit_exceeded    boolean NOT NULL DEFAULT false,
  start_cmd_id      uuid NOT NULL,
  end_cmd_id        uuid,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, terminal_id) REFERENCES pos.terminal(tenant_id, id),
  CONSTRAINT offline_session_end CHECK ((ended_at IS NULL) = (end_cmd_id IS NULL) AND (ended_at IS NULL OR ended_at >= started_at))
);
SELECT core.enable_tenant_rls('pos.offline_session');

-- جریان‌های خواندنی (کاتالوگ، قیمت، اشخاص، ...) با نسخهٔ یکنواخت برای هر (جریان، دامنه)
CREATE TABLE IF NOT EXISTS pos.sync_stream_version (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  stream            text NOT NULL CHECK (stream IN ('catalog','prices','parties','tax_profile','settings','layout','tables','staff')),
  scope_key         text NOT NULL CHECK (scope_key ~ '^(tenant|company:[0-9a-f-]{36}|branch:[0-9a-f-]{36})$'),
  version           bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  snapshot_version  bigint CHECK (snapshot_version >= 0),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, stream, scope_key),
  CONSTRAINT stream_snapshot_le CHECK (snapshot_version IS NULL OR snapshot_version <= version)
);
SELECT core.enable_tenant_rls('pos.sync_stream_version');

CREATE TABLE IF NOT EXISTS pos.stream_change (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  stream       text NOT NULL,
  scope_key    text NOT NULL,
  version      bigint NOT NULL CHECK (version >= 1),
  entity_type  text NOT NULL CHECK (entity_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  entity_id    uuid NOT NULL,
  op           text NOT NULL CHECK (op IN ('upsert','delete')),
  payload      jsonb CHECK (payload IS NULL OR jsonb_typeof(payload) = 'object'),
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, stream, scope_key, entity_type, entity_id, version),
  FOREIGN KEY (tenant_id, stream, scope_key) REFERENCES pos.sync_stream_version(tenant_id, stream, scope_key),
  CONSTRAINT stream_change_payload CHECK ((op = 'upsert') = (payload IS NOT NULL))
);
SELECT core.enable_tenant_rls('pos.stream_change');
CREATE INDEX IF NOT EXISTS stream_change_pull_idx ON pos.stream_change (tenant_id, stream, scope_key, version);

CREATE TABLE IF NOT EXISTS pos.stream_snapshot (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  stream         text NOT NULL,
  scope_key      text NOT NULL,
  version        bigint NOT NULL CHECK (version >= 0),
  attachment_id  uuid NOT NULL,
  item_count     integer NOT NULL CHECK (item_count >= 0),
  sha256         bytea NOT NULL CHECK (octet_length(sha256) = 32),
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, stream, scope_key, version),
  FOREIGN KEY (tenant_id, stream, scope_key) REFERENCES pos.sync_stream_version(tenant_id, stream, scope_key),
  FOREIGN KEY (tenant_id, attachment_id) REFERENCES core.attachment(tenant_id, id)
);
SELECT core.enable_tenant_rls('pos.stream_snapshot');

-- =====================================================================
-- ۱۷. pos — سفارش باز (میز/نگه‌داشته) و رسید تغییرناپذیر
-- =====================================================================
CREATE TABLE IF NOT EXISTS pos.open_order (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL,                       -- UUIDv7 ساخت کلاینت
  company_id         uuid NOT NULL,
  branch_id          uuid NOT NULL,
  terminal_id        uuid NOT NULL,
  table_id           uuid,
  order_type         text NOT NULL CHECK (order_type IN ('dine_in','takeaway','delivery','retail_hold')),
  status             text NOT NULL DEFAULT 'open' CHECK (status IN ('open','paid','voided')),
  guest_count        smallint CHECK (guest_count BETWEEN 1 AND 500),
  customer_party_id  uuid,
  waiter_user_id     uuid,
  delivery_info      jsonb CHECK (delivery_info IS NULL OR jsonb_typeof(delivery_info) = 'object'),
  note               text,
  opened_at          timestamptz NOT NULL,
  closed_at          timestamptz,
  version            integer NOT NULL DEFAULT 1 CHECK (version >= 1),
  void_reason        text,
  last_cmd_id        uuid NOT NULL,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, terminal_id) REFERENCES pos.terminal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, table_id) REFERENCES pos.dining_table(tenant_id, id),
  FOREIGN KEY (tenant_id, customer_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, waiter_user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT open_order_table CHECK (order_type <> 'dine_in' OR table_id IS NOT NULL),
  CONSTRAINT open_order_delivery CHECK (order_type <> 'delivery' OR delivery_info IS NOT NULL),
  CONSTRAINT open_order_closed CHECK ((status = 'open') = (closed_at IS NULL)),
  CONSTRAINT open_order_void CHECK ((status = 'voided') = (void_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('pos.open_order');
CREATE INDEX IF NOT EXISTS open_order_table_idx ON pos.open_order (tenant_id, table_id) WHERE status = 'open';

CREATE TABLE IF NOT EXISTS pos.open_order_line (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL,
  order_id           uuid NOT NULL,
  line_no            smallint NOT NULL CHECK (line_no BETWEEN 1 AND 2000),
  item_id            uuid NOT NULL,
  variant_id         uuid NOT NULL,
  uom_id             uuid NOT NULL,
  qty                core.qty NOT NULL CHECK (qty > 0),
  unit_price         core.amount NOT NULL CHECK (unit_price >= 0),
  parent_line_no     smallint,
  course_no          smallint NOT NULL DEFAULT 1 CHECK (course_no BETWEEN 1 AND 9),
  seat_no            smallint CHECK (seat_no BETWEEN 1 AND 500),
  station_id         uuid,
  note               text CHECK (char_length(note) <= 300),
  status             text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','served','voided')),
  sent_at            timestamptz,
  voided_after_send  boolean NOT NULL DEFAULT false,
  void_reason        text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, order_id, line_no),
  FOREIGN KEY (tenant_id, order_id) REFERENCES pos.open_order(tenant_id, id),
  FOREIGN KEY (tenant_id, order_id, parent_line_no) REFERENCES pos.open_order_line(tenant_id, order_id, line_no),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, station_id) REFERENCES pos.station(tenant_id, id),
  CONSTRAINT open_line_parent CHECK (parent_line_no IS NULL OR parent_line_no < line_no),
  CONSTRAINT open_line_sent CHECK (status = 'pending' OR status = 'voided' OR sent_at IS NOT NULL),
  CONSTRAINT open_line_void CHECK ((status = 'voided') = (void_reason IS NOT NULL) AND (NOT voided_after_send OR status = 'voided'))
);
SELECT core.enable_tenant_rls('pos.open_order_line');

-- رسید (فروش، مرجوعی، تعویض). فقط از روی فرمان امضاشدهٔ دستگاه ساخته می‌شود و تغییرناپذیر است؛
-- فقط ستون‌های ثبت (سند فروش، سند دریافت، سند مالیاتی، وضعیت ثبت) یک‌بار پر می‌شوند.
CREATE TABLE IF NOT EXISTS pos.ticket (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL,                  -- UUIDv7 ساخت دستگاه
  company_id              uuid NOT NULL,
  branch_id               uuid NOT NULL,
  terminal_id             uuid NOT NULL,
  shift_id                uuid NOT NULL,
  business_day_id         uuid NOT NULL,
  device_id               uuid NOT NULL,
  cmd_id                  uuid NOT NULL,
  created_xact            xid8 NOT NULL DEFAULT pg_current_xact_id(),
  kind                    text NOT NULL CHECK (kind IN ('sale','return','exchange')),
  order_type              text NOT NULL CHECK (order_type IN ('retail','dine_in','takeaway','delivery')),
  open_order_id           uuid,
  table_id                uuid,
  ticket_no               text NOT NULL CHECK (char_length(ticket_no) BETWEEN 1 AND 100),
  number_issued_id        uuid NOT NULL,
  original_ticket_id      uuid,
  customer_party_id       uuid NOT NULL,
  price_list_id           uuid,
  prices_snapshot_version bigint,
  prices_include_tax      boolean NOT NULL DEFAULT false,
  currency                char(3) NOT NULL DEFAULT 'IRR' REFERENCES ref.currency(code),
  line_rounding           text NOT NULL DEFAULT 'truncate' CHECK (line_rounding = 'truncate'),  -- RC_IITP: prdis = trunc(am × fee)، هم‌خوان با sales.invoice_line_gross؛ حالت‌های دیگر رزرو
  subtotal                core.amount NOT NULL,
  order_discount          core.amount NOT NULL DEFAULT 0,
  service_charge          core.amount NOT NULL DEFAULT 0,
  service_charge_rate     numeric(7,4) CHECK (service_charge_rate BETWEEN 0 AND 100),
  tax_total               core.amount NOT NULL DEFAULT 0,
  rounding_adjustment     core.amount NOT NULL DEFAULT 0,
  tip_amount              core.amount NOT NULL DEFAULT 0 CHECK (tip_amount >= 0),
  total                   core.amount NOT NULL,
  tax_rule_version        text,
  taxid                   text CHECK (taxid ~ '^[0-9A-Z]{22}$'),
  tax_indatim_ms          bigint CHECK (tax_indatim_ms > 0),
  tax_memory_ref          uuid,                           -- tax.memory (FK در 99_cross_fk)
  tax_doc_id              uuid,                           -- tax.invoice (FK در 99_cross_fk)
  occurred_at             timestamptz NOT NULL,
  received_at             timestamptz NOT NULL DEFAULT now(),
  created_offline         boolean NOT NULL DEFAULT false,
  offline_session_id      uuid,
  cashier_user_id         uuid NOT NULL,
  posting_status          text NOT NULL DEFAULT 'pending' CHECK (posting_status IN ('pending','posted','review','not_applicable')),
  sales_doc_id            uuid,                           -- sales.invoice (FK در 99_cross_fk)
  money_document_id       uuid,
  posted_at               timestamptz,
  note                    text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, cmd_id),
  UNIQUE (tenant_id, number_issued_id),
  UNIQUE (tenant_id, terminal_id, ticket_no),
  FOREIGN KEY (tenant_id, company_id, terminal_id) REFERENCES pos.terminal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, shift_id) REFERENCES pos.shift(tenant_id, id),
  FOREIGN KEY (tenant_id, business_day_id) REFERENCES pos.business_day(tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, cmd_id) REFERENCES pos.device_command(tenant_id, cmd_id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, open_order_id) REFERENCES pos.open_order(tenant_id, id),
  FOREIGN KEY (tenant_id, table_id) REFERENCES pos.dining_table(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, original_ticket_id) REFERENCES pos.ticket(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, customer_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, price_list_id) REFERENCES catalog.price_list(tenant_id, id),
  FOREIGN KEY (tenant_id, offline_session_id) REFERENCES pos.offline_session(tenant_id, id),
  FOREIGN KEY (tenant_id, cashier_user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, company_id, money_document_id) REFERENCES treasury.money_document(tenant_id, company_id, id),
  CONSTRAINT ticket_original CHECK ((kind <> 'sale' OR original_ticket_id IS NULL) AND (kind <> 'exchange' OR original_ticket_id IS NOT NULL)),
  CONSTRAINT ticket_sign CHECK ((kind <> 'sale' OR (total >= 0 AND subtotal >= 0 AND order_discount >= 0 AND service_charge >= 0))
                            AND (kind <> 'return' OR (total <= 0 AND subtotal <= 0 AND order_discount <= 0 AND service_charge <= 0))),
  CONSTRAINT ticket_posted CHECK ((posting_status = 'posted') = (posted_at IS NOT NULL)
                                  AND (posting_status <> 'posted' OR sales_doc_id IS NOT NULL)),
  CONSTRAINT ticket_tax_pair CHECK ((taxid IS NULL) = (tax_indatim_ms IS NULL)),
  CONSTRAINT ticket_offline CHECK (NOT created_offline OR offline_session_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('pos.ticket');
CREATE UNIQUE INDEX IF NOT EXISTS ticket_taxid_uq ON pos.ticket (tenant_id, taxid) WHERE taxid IS NOT NULL;
CREATE INDEX IF NOT EXISTS ticket_shift_idx ON pos.ticket (tenant_id, shift_id);
CREATE INDEX IF NOT EXISTS ticket_posting_idx ON pos.ticket (tenant_id, posting_status) WHERE posting_status IN ('pending','review');

CREATE TABLE IF NOT EXISTS pos.ticket_line (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  ticket_id            uuid NOT NULL,
  line_no              smallint NOT NULL CHECK (line_no BETWEEN 1 AND 2000),
  direction            text NOT NULL CHECK (direction IN ('sale','return')),
  item_id              uuid NOT NULL,
  variant_id           uuid NOT NULL,
  uom_id               uuid NOT NULL,
  qty                  core.qty NOT NULL CHECK (qty > 0),
  unit_price           core.amount NOT NULL CHECK (unit_price >= 0),
  price_source         text NOT NULL CHECK (price_source IN ('list','override','open_price','modifier','zero')),
  list_price           core.amount CHECK (list_price >= 0),
  server_list_price    core.amount CHECK (server_list_price >= 0),
  line_gross           core.amount NOT NULL CHECK (line_gross >= 0),
  line_discount        core.amount NOT NULL DEFAULT 0 CHECK (line_discount >= 0),
  line_net             core.amount NOT NULL CHECK (line_net >= 0),
  tax_amount           core.amount NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  tax_category_code    text CHECK (tax_category_code ~ '^[a-z][a-z0-9_.]{1,63}$'),
  parent_line_no       smallint,
  course_no            smallint CHECK (course_no BETWEEN 1 AND 9),
  seat_no              smallint CHECK (seat_no BETWEEN 1 AND 500),
  station_id           uuid,
  open_order_line_id   uuid,
  original_line_id     uuid,
  note                 text CHECK (char_length(note) <= 300),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, ticket_id, line_no),
  FOREIGN KEY (tenant_id, ticket_id) REFERENCES pos.ticket(tenant_id, id),
  FOREIGN KEY (tenant_id, ticket_id, parent_line_no) REFERENCES pos.ticket_line(tenant_id, ticket_id, line_no),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, station_id) REFERENCES pos.station(tenant_id, id),
  FOREIGN KEY (tenant_id, open_order_line_id) REFERENCES pos.open_order_line(tenant_id, id),
  FOREIGN KEY (tenant_id, original_line_id) REFERENCES pos.ticket_line(tenant_id, id),
  CONSTRAINT ticket_line_net CHECK (line_net = line_gross - line_discount),
  CONSTRAINT ticket_line_parent CHECK (parent_line_no IS NULL OR parent_line_no < line_no),
  CONSTRAINT ticket_line_original CHECK (original_line_id IS NULL OR direction = 'return'),
  CONSTRAINT ticket_line_price_source CHECK (price_source <> 'zero' OR unit_price = 0)
);
SELECT core.enable_tenant_rls('pos.ticket_line');

CREATE TABLE IF NOT EXISTS pos.ticket_payment (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  ticket_id          uuid NOT NULL,
  line_no            smallint NOT NULL CHECK (line_no BETWEEN 1 AND 50),
  method             text NOT NULL CHECK (method IN ('cash','card_pos','card_to_card','bank_transfer','on_account')),
  amount             core.amount NOT NULL CHECK (amount <> 0),
  tendered           core.amount CHECK (tendered > 0),
  change_given       core.amount NOT NULL DEFAULT 0 CHECK (change_given >= 0),
  card_terminal_id   uuid,
  rrn                text CHECK (rrn ~ '^[0-9A-Za-z]{1,12}$'),
  stan               text CHECK (stan ~ '^[0-9]{1,6}$'),
  masked_pan         text CHECK (masked_pan IS NULL OR treasury.is_masked_pan(masked_pan)),
  card_result        text CHECK (card_result IN ('approved','resolved_unknown','manual_entry')),
  bank_account_id    uuid,
  reference_no       text CHECK (char_length(reference_no) BETWEEN 1 AND 40),
  party_id           uuid,
  card_txn_id        uuid,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, ticket_id, line_no),
  FOREIGN KEY (tenant_id, ticket_id) REFERENCES pos.ticket(tenant_id, id),
  FOREIGN KEY (tenant_id, card_terminal_id) REFERENCES treasury.card_terminal(tenant_id, id),
  FOREIGN KEY (tenant_id, bank_account_id) REFERENCES treasury.bank_account(tenant_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, card_txn_id) REFERENCES treasury.card_txn(tenant_id, id),
  CONSTRAINT payment_cash CHECK (method <> 'cash' OR amount < 0 OR (tendered IS NOT NULL AND amount = tendered - change_given)),
  CONSTRAINT payment_change CHECK (change_given = 0 OR method = 'cash'),
  CONSTRAINT payment_card CHECK ((method = 'card_pos') = (card_terminal_id IS NOT NULL AND card_result IS NOT NULL)),
  -- استرداد کارتی در صندوق ممنوع است (پژوهش ۰۷ §۲-۶-۲): مبلغ کارتی همیشه دریافت است
  CONSTRAINT payment_card_no_refund CHECK (method <> 'card_pos' OR amount > 0),
  CONSTRAINT payment_account CHECK ((method = 'on_account') = (party_id IS NOT NULL)),
  CONSTRAINT payment_transfer CHECK ((method IN ('card_to_card','bank_transfer')) = (bank_account_id IS NOT NULL)),
  CONSTRAINT payment_card_refs CHECK ((rrn IS NULL AND stan IS NULL AND masked_pan IS NULL) OR method IN ('card_pos','card_to_card'))
);
SELECT core.enable_tenant_rls('pos.ticket_payment');

-- =====================================================================
-- ۱۸. تریگرهای pos
-- =====================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['edge_node','terminal','business_day','shift','floor','dining_table','station','printer',
                           'modifier_group','device_sync_state','command_outcome','offline_session','open_order'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_touch ON pos.%I', t);
    EXECUTE format('CREATE TRIGGER trg_touch BEFORE UPDATE ON pos.%I FOR EACH ROW EXECUTE FUNCTION core.touch_row()', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['shift_count','sync_batch','device_command','device_seq_gap','client_id_alias','stream_snapshot'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_append_only ON pos.%I', t);
    EXECUTE format('CREATE TRIGGER trg_append_only BEFORE UPDATE OR DELETE ON pos.%I FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation()', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['terminal','business_day','shift','ticket','ticket_line','ticket_payment','open_order',
                           'command_outcome','device_sync_state','cash_movement','offline_session','sync_stream_version'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_no_delete ON pos.%I', t);
    EXECUTE format('CREATE TRIGGER trg_no_delete BEFORE DELETE ON pos.%I FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation()', t);
  END LOOP;
END $$;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('terminal','walk_in_party_id','INSERT OR UPDATE'), ('open_order','customer_party_id','INSERT OR UPDATE'),
      ('ticket','customer_party_id','INSERT'), ('ticket_payment','party_id','INSERT')) AS v(tbl, col, ev) LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON pos.%I', 'trg_party_guard_' || r.col, r.tbl);
    EXECUTE format('CREATE TRIGGER %I BEFORE %s ON pos.%I FOR EACH ROW EXECUTE FUNCTION parties.child_party_guard(%L)',
                   'trg_party_guard_' || r.col, r.ev, r.tbl, r.col);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pos.terminal_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE d core.device; s core.number_series; cb treasury.cash_box; v_anon boolean; v_edge_branch uuid;
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.company_id, NEW.branch_id) IS DISTINCT FROM (OLD.company_id, OLD.branch_id) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'terminal company and branch cannot change');
  END IF;
  IF NEW.device_id IS NOT NULL THEN
    SELECT * INTO d FROM core.device WHERE tenant_id = NEW.tenant_id AND id = NEW.device_id;
    IF d.company_id <> NEW.company_id OR d.branch_id IS DISTINCT FROM NEW.branch_id OR d.kind NOT IN ('pos','windows','android','browser') THEN
      PERFORM core.raise_hk('HK_POS_TERMINAL_DEVICE', 'terminal device must be a POS-capable device of the same company and branch');
    END IF;
  END IF;
  SELECT * INTO s FROM core.number_series WHERE tenant_id = NEW.tenant_id AND id = NEW.receipt_series_id;
  IF s.doc_type <> 'pos.ticket' OR s.allocation <> 'device' OR s.company_id <> NEW.company_id
     OR (NEW.device_id IS NOT NULL AND s.device_id IS DISTINCT FROM NEW.device_id) THEN
    PERFORM core.raise_hk('HK_POS_TERMINAL_SERIES', 'receipt series must be a device-allocated pos.ticket series of this terminal device');
  END IF;
  SELECT * INTO cb FROM treasury.cash_box WHERE tenant_id = NEW.tenant_id AND id = NEW.cash_box_id;
  IF cb.kind <> 'pos_drawer' OR cb.branch_id IS DISTINCT FROM NEW.branch_id OR NOT cb.is_active THEN
    PERFORM core.raise_hk('HK_POS_TERMINAL_CASH_BOX', 'terminal cash box must be an active pos_drawer of the same branch');
  END IF;
  SELECT is_anonymous INTO v_anon FROM parties.party WHERE tenant_id = NEW.tenant_id AND id = NEW.walk_in_party_id;
  IF v_anon IS NOT TRUE THEN
    PERFORM core.raise_hk('HK_POS_TERMINAL_WALK_IN', 'walk-in customer must be an anonymous party');
  END IF;
  IF NEW.edge_node_id IS NOT NULL THEN
    SELECT branch_id INTO v_edge_branch FROM pos.edge_node WHERE tenant_id = NEW.tenant_id AND id = NEW.edge_node_id;
    IF v_edge_branch <> NEW.branch_id THEN
      PERFORM core.raise_hk('HK_POS_TERMINAL_EDGE', 'edge node must be in the terminal branch');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.terminal;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON pos.terminal FOR EACH ROW EXECUTE FUNCTION pos.terminal_guard();

CREATE OR REPLACE FUNCTION pos.business_day_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'closed' THEN
    PERFORM core.raise_hk('HK_POS_DAY_CLOSED', 'a closed business day is immutable');
  END IF;
  IF (NEW.company_id, NEW.branch_id, NEW.business_date) IS DISTINCT FROM (OLD.company_id, OLD.branch_id, OLD.business_date) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'business day identity cannot change');
  END IF;
  IF NEW.status = 'closed' AND EXISTS (SELECT 1 FROM pos.shift s WHERE s.tenant_id = NEW.tenant_id AND s.business_day_id = NEW.id
                                                                    AND s.status = 'open') THEN
    PERFORM core.raise_hk('HK_POS_DAY_OPEN_SHIFTS', 'close all shifts of the business day first');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.business_day;
CREATE TRIGGER trg_guard BEFORE UPDATE ON pos.business_day FOR EACH ROW EXECUTE FUNCTION pos.business_day_guard();

CREATE OR REPLACE FUNCTION pos.shift_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE t pos.terminal; b pos.business_day;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO t FROM pos.terminal WHERE tenant_id = NEW.tenant_id AND id = NEW.terminal_id;
    SELECT * INTO b FROM pos.business_day WHERE tenant_id = NEW.tenant_id AND id = NEW.business_day_id;
    IF t.status <> 'active' OR t.cash_box_id <> NEW.cash_box_id OR t.branch_id <> NEW.branch_id
       OR b.branch_id <> NEW.branch_id OR b.company_id <> NEW.company_id OR b.status <> 'open' OR NEW.status <> 'open' THEN
      PERFORM core.raise_hk('HK_POS_SHIFT_CONTEXT', 'a shift opens on an active terminal, its cash box, in an open business day of its branch');
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'closed' THEN
    IF (to_jsonb(NEW) - ARRAY['cash_count_id','ticket_count','net_sales','updated_at','row_version'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['cash_count_id','ticket_count','net_sales','updated_at','row_version'])
       OR (OLD.cash_count_id IS NOT NULL AND NEW.cash_count_id IS DISTINCT FROM OLD.cash_count_id) THEN
      PERFORM core.raise_hk('HK_POS_SHIFT_CLOSED', 'a closed shift is immutable (cash count link and summary are set once)');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.company_id, NEW.branch_id, NEW.terminal_id, NEW.business_day_id, NEW.cash_box_id, NEW.opened_by, NEW.opened_at, NEW.opening_float, NEW.open_cmd_id)
     IS DISTINCT FROM (OLD.company_id, OLD.branch_id, OLD.terminal_id, OLD.business_day_id, OLD.cash_box_id, OLD.opened_by, OLD.opened_at, OLD.opening_float, OLD.open_cmd_id) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'shift opening data cannot change');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.shift;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON pos.shift FOR EACH ROW EXECUTE FUNCTION pos.shift_guard();

CREATE OR REPLACE FUNCTION pos.cash_movement_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT status INTO v_status FROM pos.shift WHERE tenant_id = NEW.tenant_id AND id = NEW.shift_id;
    IF v_status <> 'open' THEN PERFORM core.raise_hk('HK_POS_SHIFT_CLOSED', 'cash movements need an open shift'); END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - ARRAY['money_document_id','fund_transfer_id']) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['money_document_id','fund_transfer_id'])
     OR (OLD.money_document_id IS NOT NULL AND NEW.money_document_id IS DISTINCT FROM OLD.money_document_id)
     OR (OLD.fund_transfer_id IS NOT NULL AND NEW.fund_transfer_id IS DISTINCT FROM OLD.fund_transfer_id) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'cash movement is immutable; treasury document links are set once');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.cash_movement;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON pos.cash_movement FOR EACH ROW EXECUTE FUNCTION pos.cash_movement_guard();

-- سفارش باز: پس از بسته شدن تغییرناپذیر؛ هر تغییر نسخه را دقیقاً یک واحد بالا می‌برد (هم‌روندی بین صندوق‌ها)
CREATE OR REPLACE FUNCTION pos.open_order_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status <> 'open' THEN
    PERFORM core.raise_hk('HK_POS_ORDER_CLOSED', format('order is %s and immutable', OLD.status));
  END IF;
  IF (NEW.company_id, NEW.branch_id, NEW.terminal_id, NEW.opened_at) IS DISTINCT FROM (OLD.company_id, OLD.branch_id, OLD.terminal_id, OLD.opened_at) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'order identity cannot change');
  END IF;
  IF NEW.version <> OLD.version + 1 THEN
    PERFORM core.raise_hk('HK_POS_ORDER_VERSION', format('order version must advance from %s to %s (got %s)', OLD.version, OLD.version + 1, NEW.version));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.open_order;
CREATE TRIGGER trg_guard BEFORE UPDATE ON pos.open_order FOR EACH ROW EXECUTE FUNCTION pos.open_order_guard();

CREATE OR REPLACE FUNCTION pos.open_order_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r record; v_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
  SELECT status INTO v_status FROM pos.open_order WHERE tenant_id = r.tenant_id AND id = r.order_id;
  IF v_status <> 'open' THEN
    PERFORM core.raise_hk('HK_POS_ORDER_CLOSED', 'lines of a closed order are immutable');
  END IF;
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'pending' THEN
      PERFORM core.raise_hk('HK_POS_ORDER_LINE_SENT', 'a line sent to a station is voided with a reason, never deleted');
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending' OR NEW.voided_after_send THEN
      PERFORM core.raise_hk('HK_POS_ORDER_LINE_STATE', 'new order lines are pending');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.order_id, NEW.line_no, NEW.item_id, NEW.variant_id, NEW.uom_id, NEW.parent_line_no)
     IS DISTINCT FROM (OLD.order_id, OLD.line_no, OLD.item_id, OLD.variant_id, OLD.uom_id, OLD.parent_line_no) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'order line identity cannot change');
  END IF;
  IF OLD.status <> 'pending' AND (NEW.qty, NEW.unit_price) IS DISTINCT FROM (OLD.qty, OLD.unit_price) THEN
    PERFORM core.raise_hk('HK_POS_ORDER_LINE_SENT', 'quantity and price of a sent line cannot change; void and re-add');
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT ((OLD.status = 'pending' AND NEW.status IN ('sent','voided'))
         OR (OLD.status = 'sent'    AND NEW.status IN ('served','voided'))
         OR (OLD.status = 'served'  AND NEW.status = 'voided')) THEN
      PERFORM core.raise_hk('HK_POS_ORDER_LINE_STATE', format('order line %s -> %s is not allowed', OLD.status, NEW.status));
    END IF;
    IF NEW.status = 'voided' THEN NEW.voided_after_send := (OLD.status <> 'pending'); END IF;
  ELSIF NEW.voided_after_send IS DISTINCT FROM OLD.voided_after_send THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'voided_after_send is derived');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.open_order_line;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON pos.open_order_line FOR EACH ROW EXECUTE FUNCTION pos.open_order_line_guard();

-- رسید: منشأ = فرمان امضاشدهٔ همان دستگاه؛ پس از درج فقط ستون‌های ثبت (یک‌بار) تغییر می‌کنند
CREATE OR REPLACE FUNCTION pos.ticket_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c pos.device_command; t pos.terminal; s pos.shift;
  k_mut CONSTANT text[] := ARRAY['posting_status','sales_doc_id','money_document_id','tax_doc_id','posted_at'];
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_xact := pg_current_xact_id();
    SELECT * INTO c FROM pos.device_command WHERE tenant_id = NEW.tenant_id AND cmd_id = NEW.cmd_id;
    SELECT * INTO t FROM pos.terminal WHERE tenant_id = NEW.tenant_id AND id = NEW.terminal_id;
    SELECT * INTO s FROM pos.shift WHERE tenant_id = NEW.tenant_id AND id = NEW.shift_id;
    IF c.device_id IS DISTINCT FROM NEW.device_id
       OR c.type IS DISTINCT FROM (NEW.kind || '.completed') THEN
      PERFORM core.raise_hk('HK_POS_TICKET_SOURCE', 'ticket must come from a matching signed command of its device');
    END IF;
    IF t.device_id IS DISTINCT FROM NEW.device_id OR t.branch_id <> NEW.branch_id
       OR s.terminal_id IS DISTINCT FROM NEW.terminal_id OR s.business_day_id IS DISTINCT FROM NEW.business_day_id THEN
      PERFORM core.raise_hk('HK_POS_TICKET_CONTEXT', 'ticket terminal, device, shift and business day must agree');
    END IF;
    IF NEW.posting_status <> 'pending' OR num_nonnulls(NEW.sales_doc_id, NEW.money_document_id, NEW.tax_doc_id, NEW.posted_at) > 0 THEN
      PERFORM core.raise_hk('HK_POS_TICKET_POSTING', 'a ticket is stored first and posted afterwards');
    END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - k_mut) IS DISTINCT FROM (to_jsonb(OLD) - k_mut) THEN
    PERFORM core.raise_hk('HK_POS_TICKET_IMMUTABLE', 'a ticket is immutable (corrections are return tickets)');
  END IF;
  IF (OLD.sales_doc_id IS NOT NULL AND NEW.sales_doc_id IS DISTINCT FROM OLD.sales_doc_id)
     OR (OLD.money_document_id IS NOT NULL AND NEW.money_document_id IS DISTINCT FROM OLD.money_document_id)
     OR (OLD.tax_doc_id IS NOT NULL AND NEW.tax_doc_id IS DISTINCT FROM OLD.tax_doc_id) THEN
    PERFORM core.raise_hk('HK_POS_TICKET_IMMUTABLE', 'posting links are set once');
  END IF;
  IF NEW.posting_status IS DISTINCT FROM OLD.posting_status AND NOT (
       (OLD.posting_status = 'pending' AND NEW.posting_status IN ('posted','review','not_applicable'))
    OR (OLD.posting_status = 'review'  AND NEW.posting_status IN ('posted','not_applicable'))) THEN
    PERFORM core.raise_hk('HK_POS_TICKET_POSTING', format('ticket posting %s -> %s is not allowed', OLD.posting_status, NEW.posting_status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.ticket;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON pos.ticket FOR EACH ROW EXECUTE FUNCTION pos.ticket_guard();

-- سطر و پرداخت رسید فقط در همان تراکنشِ درج رسید نوشته می‌شوند؛ پس از آن فقط پیوند تراکنش کارت (یک‌بار)
CREATE OR REPLACE FUNCTION pos.ticket_child_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_xact xid8;
BEGIN
  SELECT created_xact INTO v_xact FROM pos.ticket WHERE tenant_id = NEW.tenant_id AND id = NEW.ticket_id;
  IF v_xact = pg_current_xact_id() THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'ticket_payment' THEN
    IF (to_jsonb(NEW) - 'card_txn_id') = (to_jsonb(OLD) - 'card_txn_id') AND (to_jsonb(OLD) ->> 'card_txn_id') IS NULL THEN
      RETURN NEW;
    END IF;
  END IF;
  PERFORM core.raise_hk('HK_POS_TICKET_IMMUTABLE', format('%s rows are written only with their ticket', TG_TABLE_NAME));
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.ticket_line;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON pos.ticket_line FOR EACH ROW EXECUTE FUNCTION pos.ticket_child_guard();
DROP TRIGGER IF EXISTS trg_guard ON pos.ticket_payment;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON pos.ticket_payment FOR EACH ROW EXECUTE FUNCTION pos.ticket_child_guard();

-- در commit: جمع‌ها، علامت‌ها، پرداخت‌ها، سقف مرجوعی و سقف تقسیم صورتحساب
CREATE OR REPLACE FUNCTION pos.ticket_check() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE t pos.ticket; v_minor smallint; v_n int; v_bad int; v_sub numeric; v_tax numeric; v_pay numeric; r record;
BEGIN
  SELECT * INTO t FROM pos.ticket WHERE tenant_id = NEW.tenant_id AND id = NEW.id;
  SELECT minor_unit INTO v_minor FROM ref.currency WHERE code = t.currency;
  SELECT count(*),
         count(*) FILTER (WHERE line_gross <> trunc(qty * unit_price, v_minor)
                            OR (t.kind = 'sale' AND direction <> 'sale') OR (t.kind = 'return' AND direction <> 'return')),
         coalesce(sum(CASE direction WHEN 'sale' THEN line_net ELSE -line_net END), 0),
         coalesce(sum(CASE direction WHEN 'sale' THEN tax_amount ELSE -tax_amount END), 0)
    INTO v_n, v_bad, v_sub, v_tax
    FROM pos.ticket_line WHERE tenant_id = t.tenant_id AND ticket_id = t.id;
  IF v_n = 0 OR v_bad > 0 THEN
    PERFORM core.raise_hk('HK_POS_TICKET_LINES', format('ticket %s: %s lines, %s inconsistent (gross rounding or direction)', t.id, v_n, v_bad));
  END IF;
  IF t.subtotal <> v_sub OR t.tax_total <> v_tax
     OR t.total <> t.subtotal - t.order_discount + t.service_charge
                   + (CASE WHEN t.prices_include_tax THEN 0 ELSE t.tax_total END) + t.rounding_adjustment THEN
    PERFORM core.raise_hk('HK_POS_TICKET_TOTALS', format('ticket %s totals do not add up (subtotal %s/%s, tax %s/%s, total %s)',
                                                      t.id, t.subtotal, v_sub, t.tax_total, v_tax, t.total));
  END IF;
  SELECT coalesce(sum(amount), 0) INTO v_pay FROM pos.ticket_payment WHERE tenant_id = t.tenant_id AND ticket_id = t.id;
  IF v_pay <> t.total + t.tip_amount THEN
    PERFORM core.raise_hk('HK_POS_TICKET_PAYMENTS', format('ticket %s payments %s <> total %s + tip %s', t.id, v_pay, t.total, t.tip_amount));
  END IF;
  -- مرجوعی: سطر اصلی فروش از رسید اصلی، همان SKU و واحد، و جمع برگشتی‌ها ≤ مقدار فروخته‌شده
  FOR r IN SELECT l.original_line_id, l.variant_id, l.uom_id FROM pos.ticket_line l
            WHERE l.tenant_id = t.tenant_id AND l.ticket_id = t.id AND l.original_line_id IS NOT NULL LOOP
    IF NOT EXISTS (SELECT 1 FROM pos.ticket_line o
                    WHERE o.tenant_id = t.tenant_id AND o.id = r.original_line_id AND o.direction = 'sale'
                      AND o.variant_id = r.variant_id AND o.uom_id = r.uom_id
                      AND (t.original_ticket_id IS NULL OR o.ticket_id = t.original_ticket_id))
       OR (SELECT sum(x.qty) FROM pos.ticket_line x WHERE x.tenant_id = t.tenant_id AND x.original_line_id = r.original_line_id)
          > (SELECT o.qty FROM pos.ticket_line o WHERE o.tenant_id = t.tenant_id AND o.id = r.original_line_id) THEN
      PERFORM core.raise_hk('HK_POS_RETURN_EXCEEDS', format('return of line %s exceeds or mismatches the original sale', r.original_line_id));
    END IF;
  END LOOP;
  -- تقسیم صورتحساب: جمع فروش هر سطر سفارش باز در همهٔ رسیدها ≤ مقدار آن سطر و سطر باطل نشده
  FOR r IN SELECT l.open_order_line_id FROM pos.ticket_line l
            WHERE l.tenant_id = t.tenant_id AND l.ticket_id = t.id AND l.open_order_line_id IS NOT NULL LOOP
    IF (SELECT sum(x.qty) FROM pos.ticket_line x WHERE x.tenant_id = t.tenant_id AND x.open_order_line_id = r.open_order_line_id AND x.direction = 'sale')
       > (SELECT o.qty FROM pos.open_order_line o WHERE o.tenant_id = t.tenant_id AND o.id = r.open_order_line_id AND o.status <> 'voided') IS NOT FALSE THEN
      PERFORM core.raise_hk('HK_POS_SPLIT_EXCEEDS', format('order line %s is billed beyond its quantity (or voided)', r.open_order_line_id));
    END IF;
  END LOOP;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_check ON pos.ticket;
CREATE CONSTRAINT TRIGGER trg_check AFTER INSERT ON pos.ticket
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pos.ticket_check();

-- ---------- همگام‌سازی ----------
CREATE OR REPLACE FUNCTION pos.sync_state_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.last_seq <> 0 OR NEW.last_hash <> pos.genesis_hash(NEW.device_id) THEN
      PERFORM core.raise_hk('HK_SYNC_STATE_INIT', 'sync state starts at seq 0 with the genesis hash of the device');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.device_id <> OLD.device_id THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'sync state device cannot change');
  END IF;
  IF (NEW.last_seq, NEW.last_hash) IS DISTINCT FROM (OLD.last_seq, OLD.last_hash)
     AND (NEW.last_seq <> OLD.last_seq + 1
          OR NOT EXISTS (SELECT 1 FROM pos.device_command c WHERE c.tenant_id = NEW.tenant_id AND c.device_id = NEW.device_id
                                                             AND c.device_seq = NEW.last_seq AND c.hash = NEW.last_hash)) THEN
    PERFORM core.raise_hk('HK_SYNC_STATE_ADVANCE', 'sync head advances only with a stored command');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.device_sync_state;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON pos.device_sync_state FOR EACH ROW EXECUTE FUNCTION pos.sync_state_guard();

-- درج فرمان: بدنه با ستون‌ها بخواند، دنباله پیوسته، prev_hash = hash فرمان قبلی (یا genesis)، دستگاه مجاز
CREATE OR REPLACE FUNCTION pos.device_command_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s pos.device_sync_state; d core.device; b jsonb; bt pos.sync_batch;
BEGIN
  b := NEW.body::jsonb;
  IF jsonb_typeof(b) <> 'object' OR (b ->> 'v') IS DISTINCT FROM '1' OR jsonb_typeof(b -> 'payload') IS DISTINCT FROM 'object'
     OR (b ->> 'cmd_id')::uuid IS DISTINCT FROM NEW.cmd_id OR (b ->> 'device_id')::uuid IS DISTINCT FROM NEW.device_id
     OR (b ->> 'device_seq')::bigint IS DISTINCT FROM NEW.device_seq OR (b ->> 'type') IS DISTINCT FROM NEW.type
     OR (b ->> 'schema_version')::smallint IS DISTINCT FROM NEW.schema_version
     OR (b ->> 'occurred_at')::timestamptz IS DISTINCT FROM NEW.occurred_at
     OR decode(b ->> 'prev_hash', 'hex') IS DISTINCT FROM NEW.prev_hash THEN
    PERFORM core.raise_hk('HK_SYNC_BODY_MISMATCH', 'command columns must equal the signed canonical body (envelope v1)');
  END IF;
  SELECT * INTO bt FROM pos.sync_batch WHERE tenant_id = NEW.tenant_id AND id = NEW.batch_id;
  IF bt.device_id IS DISTINCT FROM NEW.device_id OR NEW.device_seq NOT BETWEEN bt.first_seq AND bt.last_seq
     OR NEW.edge_node_id IS DISTINCT FROM bt.via_edge_node_id THEN
    PERFORM core.raise_hk('HK_SYNC_BATCH_MISMATCH', 'command must belong to its batch envelope (device, seq range, edge relay)');
  END IF;
  SELECT * INTO s FROM pos.device_sync_state WHERE tenant_id = NEW.tenant_id AND device_id = NEW.device_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_SYNC_NO_STATE', 'device is not provisioned for sync'); END IF;
  IF s.status <> 'ok' THEN
    PERFORM core.raise_hk('HK_SYNC_QUARANTINED', format('device sync is %s', s.status));
  END IF;
  IF NEW.device_seq <> s.last_seq + 1 THEN
    PERFORM core.raise_hk('HK_SYNC_SEQ_GAP', format('expected device_seq %s, got %s', s.last_seq + 1, NEW.device_seq));
  END IF;
  IF NEW.prev_hash <> s.last_hash THEN
    PERFORM core.raise_hk('HK_SYNC_CHAIN_BROKEN', format('prev_hash of seq %s does not match the stored chain head', NEW.device_seq));
  END IF;
  SELECT * INTO d FROM core.device WHERE tenant_id = NEW.tenant_id AND id = NEW.device_id;
  IF NOT (d.status = 'active' OR (d.status IN ('revoked','lost') AND NEW.occurred_at < d.revoked_at)) OR d.key_alg <> NEW.sig_alg THEN
    PERFORM core.raise_hk('HK_SYNC_DEVICE_REVOKED', 'device is not active (or command is dated after revocation) or signature algorithm differs');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.device_command;
CREATE TRIGGER trg_guard BEFORE INSERT ON pos.device_command FOR EACH ROW EXECUTE FUNCTION pos.device_command_guard();

CREATE OR REPLACE FUNCTION pos.device_command_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE pos.device_sync_state
     SET last_seq = NEW.device_seq, last_hash = NEW.hash, last_cmd_received_at = NEW.received_at,
         highest_occurred_at = greatest(highest_occurred_at, NEW.occurred_at),
         last_clock_offset_ms = NEW.clock_offset_ms,
         max_abs_clock_offset_ms = greatest(coalesce(max_abs_clock_offset_ms, 0), abs(NEW.clock_offset_ms))
   WHERE tenant_id = NEW.tenant_id AND device_id = NEW.device_id;
  INSERT INTO pos.command_outcome (tenant_id, command_id, device_id, device_seq, status)
  VALUES (NEW.tenant_id, NEW.id, NEW.device_id, NEW.device_seq, 'pending');
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON pos.device_command;
CREATE TRIGGER trg_apply AFTER INSERT ON pos.device_command FOR EACH ROW EXECUTE FUNCTION pos.device_command_apply();

-- نتیجهٔ فرمان: درج فقط «pending» و هم‌خوان با فرمان؛ گذارها محدود؛ پردازش به ترتیب device_seq
CREATE OR REPLACE FUNCTION pos.command_outcome_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c pos.device_command;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO c FROM pos.device_command WHERE tenant_id = NEW.tenant_id AND id = NEW.command_id;
    IF NEW.status <> 'pending' OR c.device_id <> NEW.device_id OR c.device_seq <> NEW.device_seq THEN
      PERFORM core.raise_hk('HK_SYNC_OUTCOME', 'outcome rows are created pending and mirror their command');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.command_id, NEW.device_id, NEW.device_seq) IS DISTINCT FROM (OLD.command_id, OLD.device_id, OLD.device_seq) THEN
    PERFORM core.raise_hk('HK_TRS_IMMUTABLE_FIELD', 'outcome identity cannot change');
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT ((OLD.status = 'pending'  AND NEW.status IN ('applied','review','rejected','deferred'))
         OR (OLD.status = 'deferred' AND NEW.status IN ('pending','applied','review','rejected','deferred'))
         OR (OLD.status = 'review'   AND NEW.status IN ('applied','rejected'))) THEN
      PERFORM core.raise_hk('HK_SYNC_OUTCOME', format('outcome %s -> %s is not allowed', OLD.status, NEW.status));
    END IF;
    IF OLD.status = 'review' AND (NEW.resolved_by IS NULL OR NEW.resolved_at IS NULL OR char_length(btrim(coalesce(NEW.resolution_note, ''))) < 5) THEN
      PERFORM core.raise_hk('HK_SYNC_REVIEW_RESOLUTION', 'resolving a review needs resolver, time and a note');
    END IF;
    IF OLD.status = 'pending' AND EXISTS (SELECT 1 FROM pos.command_outcome o
                                           WHERE o.tenant_id = NEW.tenant_id AND o.device_id = NEW.device_id
                                             AND o.device_seq < NEW.device_seq AND o.status = 'pending') THEN
      PERFORM core.raise_hk('HK_SYNC_OUT_OF_ORDER', 'commands of a device are processed in device_seq order');
    END IF;
  ELSIF OLD.status IN ('applied','rejected') AND (to_jsonb(NEW) - ARRAY['updated_at','row_version']) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_SYNC_OUTCOME', 'final outcomes are immutable');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.command_outcome;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON pos.command_outcome FOR EACH ROW EXECUTE FUNCTION pos.command_outcome_guard();

CREATE OR REPLACE FUNCTION pos.stream_version_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.stream, NEW.scope_key) IS DISTINCT FROM (OLD.stream, OLD.scope_key) OR NEW.version < OLD.version
     OR coalesce(NEW.snapshot_version, -1) < coalesce(OLD.snapshot_version, -1) THEN
    PERFORM core.raise_hk('HK_SYNC_STREAM_VERSION', 'stream versions only move forward');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.sync_stream_version;
CREATE TRIGGER trg_guard BEFORE UPDATE ON pos.sync_stream_version FOR EACH ROW EXECUTE FUNCTION pos.stream_version_guard();

-- تغییر فقط در نسخهٔ جاری جریان درج می‌شود؛ حذف فقط برای فشرده‌سازی پشت snapshot
CREATE OR REPLACE FUNCTION pos.stream_change_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_version bigint; v_snapshot bigint;
BEGIN
  IF TG_OP = 'UPDATE' THEN PERFORM core.raise_hk('HK_IMMUTABLE', 'stream changes are append-only'); END IF;
  SELECT version, snapshot_version INTO v_version, v_snapshot FROM pos.sync_stream_version
   WHERE tenant_id = coalesce(NEW.tenant_id, OLD.tenant_id) AND stream = coalesce(NEW.stream, OLD.stream)
     AND scope_key = coalesce(NEW.scope_key, OLD.scope_key);
  IF TG_OP = 'INSERT' THEN
    IF NEW.version <> v_version THEN
      PERFORM core.raise_hk('HK_SYNC_STREAM_VERSION', format('change must use the current stream version %s (got %s)', v_version, NEW.version));
    END IF;
    RETURN NEW;
  END IF;
  IF v_snapshot IS NULL OR OLD.version > v_snapshot THEN
    PERFORM core.raise_hk('HK_SYNC_STREAM_COMPACTION', 'only changes covered by a snapshot can be compacted');
  END IF;
  RETURN OLD;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON pos.stream_change;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON pos.stream_change FOR EACH ROW EXECUTE FUNCTION pos.stream_change_guard();

-- گام نسخهٔ جریان (یک بار در هر تراکنش انتشار تغییرات)
CREATE OR REPLACE FUNCTION pos.bump_stream(p_stream text, p_scope text) RETURNS bigint
LANGUAGE sql AS $$
  INSERT INTO pos.sync_stream_version (tenant_id, stream, scope_key, version)
  VALUES (core.current_tenant_id(), p_stream, p_scope, 1)
  ON CONFLICT (tenant_id, stream, scope_key) DO UPDATE SET version = pos.sync_stream_version.version + 1, updated_at = now()
  RETURNING version
$$;

-- راستی‌آزمایی مستقل زنجیرهٔ یک دستگاه (خروجی خالی = سالم)
CREATE OR REPLACE FUNCTION pos.verify_device_chain(p_device_id uuid)
RETURNS TABLE (device_seq bigint, problem text)
LANGUAGE sql STABLE AS $$
  WITH c AS (
    SELECT d.device_seq, d.prev_hash, d.hash, d.body,
           lag(d.hash) OVER (ORDER BY d.device_seq) AS prev_stored_hash,
           lag(d.device_seq) OVER (ORDER BY d.device_seq) AS prev_seq
      FROM pos.device_command d WHERE d.device_id = p_device_id)
  SELECT c.device_seq, 'hash_mismatch' FROM c WHERE c.hash <> sha256(convert_to(c.body, 'UTF8'))
  UNION ALL
  SELECT c.device_seq, 'seq_gap' FROM c WHERE c.prev_seq IS NOT NULL AND c.device_seq <> c.prev_seq + 1
  UNION ALL
  SELECT c.device_seq, 'first_seq_not_1' FROM c WHERE c.prev_seq IS NULL AND c.device_seq <> 1
  UNION ALL
  SELECT c.device_seq, 'chain_broken' FROM c
   WHERE (c.prev_seq IS NULL AND c.prev_hash <> pos.genesis_hash(p_device_id))
      OR (c.prev_seq IS NOT NULL AND c.prev_hash <> c.prev_stored_hash)
  ORDER BY 1, 2
$$;

CREATE OR REPLACE VIEW pos.v_device_sync_health WITH (security_invoker = true) AS
  SELECT s.tenant_id, s.device_id, s.terminal_id, s.last_seq, s.last_cmd_received_at, s.max_abs_clock_offset_ms, s.status,
         (SELECT count(*) FROM pos.command_outcome o WHERE o.tenant_id = s.tenant_id AND o.device_id = s.device_id AND o.status = 'pending') AS pending,
         (SELECT count(*) FROM pos.command_outcome o WHERE o.tenant_id = s.tenant_id AND o.device_id = s.device_id AND o.status = 'review') AS in_review,
         (SELECT count(*) FROM pos.command_outcome o WHERE o.tenant_id = s.tenant_id AND o.device_id = s.device_id AND o.status = 'deferred') AS deferred
    FROM pos.device_sync_state s;

-- =====================================================================
-- ۱۹. ثبت در کاتالوگ‌های ماژول‌های دیگر (ledger و core) — idempotent
-- =====================================================================
INSERT INTO ledger.posting_key (key, owner_module, expected_account_types, is_required, name_fa, introduced_in) VALUES
  ('treasury.cheque_bounced',       'treasury', '{asset}',            false, 'چک‌های برگشتی', '1.0'),
  ('treasury.cheque_receivable_lt', 'treasury', '{asset}',            false, 'اسناد دریافتنی بلندمدت', '1.0'),
  ('treasury.cheque_payable_lt',    'treasury', '{liability}',        false, 'اسناد پرداختنی بلندمدت', '1.0'),
  ('treasury.cheque_protest_cost',  'treasury', '{expense,asset}',    false, 'هزینهٔ گواهی عدم پرداخت / واخواست', '1.0'),
  ('treasury.gateway_clearing',     'treasury', '{asset}',            false, 'واسط درگاه پرداخت اینترنتی', '1.0'),
  ('treasury.cash_in_transit',      'treasury', '{asset}',            false, 'وجوه در راه', '1.0'),
  ('treasury.cash_over_short',      'treasury', '{expense,income}',   false, 'کسری و اضافهٔ صندوق', '1.0'),
  ('treasury.bank_interest_income', 'treasury', '{income}',           false, 'سود سپردهٔ بانکی', '1.0'),
  ('treasury.unidentified_receipt', 'treasury', '{liability}',        false, 'واریزهای نامشخص', '1.0'),
  ('pos.tips_payable',              'pos',      '{liability}',        false, 'انعام پرداختنی به کارکنان', '1.0')
ON CONFLICT (key) DO NOTHING;

INSERT INTO ledger.dimension_type_catalog (code, slot, owner_module, is_hierarchical, name_fa, introduced_in) VALUES
  ('payment_gateway', 1, 'treasury', false, 'درگاه پرداخت', '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ledger.subledger_source (subledger_kind, owner_module, balance_function, dim_slot, compare_txn, introduced_in) VALUES
  ('cheque_receivable',  'treasury', 'treasury.subledger_cheque_receivable',  1, true, '1.0'),
  ('cheque_payable',     'treasury', 'treasury.subledger_cheque_payable',     1, true, '1.0'),
  ('guarantee_received', 'treasury', 'treasury.subledger_guarantee_received', 1, true, '1.0'),
  ('guarantee_given',    'treasury', 'treasury.subledger_guarantee_given',    1, true, '1.0')
ON CONFLICT (subledger_kind) DO NOTHING;

INSERT INTO core.permission (code, module, scope_dimensions, risk, allow_service_account, allow_impersonation_write, description_key, introduced_in) VALUES
  ('treasury.fund.read',              'treasury', '{company,branch,cash_box}', 'normal',    true,  false, 'perm.treasury.fund.read', '1.0'),
  ('treasury.fund.manage',            'treasury', '{company,branch}',          'sensitive', false, false, 'perm.treasury.fund.manage', '1.0'),
  ('treasury.document.read',          'treasury', '{company,branch,cash_box}', 'normal',    true,  false, 'perm.treasury.document.read', '1.0'),
  ('treasury.document.create',        'treasury', '{company,branch,cash_box}', 'normal',    true,  false, 'perm.treasury.document.create', '1.0'),
  ('treasury.document.post',          'treasury', '{company,branch,cash_box}', 'sensitive', true,  false, 'perm.treasury.document.post', '1.0'),
  ('treasury.document.cancel',        'treasury', '{company,branch,cash_box}', 'sensitive', false, false, 'perm.treasury.document.cancel', '1.0'),
  ('treasury.allocation.manage',      'treasury', '{company}',                 'normal',    true,  false, 'perm.treasury.allocation.manage', '1.0'),
  ('treasury.allocation.offset',      'treasury', '{company}',                 'sensitive', false, false, 'perm.treasury.allocation.offset', '1.0'),
  ('treasury.transfer.create',        'treasury', '{company,branch,cash_box}', 'sensitive', true,  false, 'perm.treasury.transfer.create', '1.0'),
  ('treasury.cash_count.post',        'treasury', '{company,branch,cash_box}', 'sensitive', true,  false, 'perm.treasury.cash_count.post', '1.0'),
  ('treasury.petty_cash.claim',       'treasury', '{company,branch}',          'normal',    false, false, 'perm.treasury.petty_cash.claim', '1.0'),
  ('treasury.petty_cash.approve',     'treasury', '{company,branch}',          'sensitive', false, false, 'perm.treasury.petty_cash.approve', '1.0'),
  ('treasury.cheque.read',            'treasury', '{company,branch}',          'normal',    true,  false, 'perm.treasury.cheque.read', '1.0'),
  ('treasury.cheque.manage',          'treasury', '{company,branch}',          'sensitive', true,  false, 'perm.treasury.cheque.manage', '1.0'),
  ('treasury.cheque.cancel',          'treasury', '{company,branch}',          'critical',  false, false, 'perm.treasury.cheque.cancel', '1.0'),
  ('treasury.cheque.print',           'treasury', '{company,branch}',          'sensitive', false, false, 'perm.treasury.cheque.print', '1.0'),
  ('treasury.cheque.override_sayad',  'treasury', '{company,branch}',          'sensitive', false, false, 'perm.treasury.cheque.override_sayad', '1.0'),
  ('treasury.chequebook.manage',      'treasury', '{company}',                 'sensitive', false, false, 'perm.treasury.chequebook.manage', '1.0'),
  ('treasury.statement.import',       'treasury', '{company}',                 'normal',    true,  false, 'perm.treasury.statement.import', '1.0'),
  ('treasury.statement.override',     'treasury', '{company}',                 'sensitive', false, false, 'perm.treasury.statement.override', '1.0'),
  ('treasury.recon.match',            'treasury', '{company}',                 'normal',    true,  false, 'perm.treasury.recon.match', '1.0'),
  ('treasury.recon.finalize',         'treasury', '{company}',                 'sensitive', false, false, 'perm.treasury.recon.finalize', '1.0'),
  ('treasury.recon.rule.manage',      'treasury', '{company}',                 'sensitive', false, false, 'perm.treasury.recon.rule.manage', '1.0'),
  ('treasury.card.read',              'treasury', '{company,branch}',          'normal',    true,  false, 'perm.treasury.card.read', '1.0'),
  ('treasury.card.settle',            'treasury', '{company,branch}',          'sensitive', true,  false, 'perm.treasury.card.settle', '1.0'),
  ('treasury.gateway.manage',         'treasury', '{company}',                 'critical',  false, false, 'perm.treasury.gateway.manage', '1.0'),
  ('treasury.gateway.link.create',    'treasury', '{company}',                 'normal',    true,  false, 'perm.treasury.gateway.link.create', '1.0'),
  ('treasury.gateway.read',           'treasury', '{company}',                 'normal',    true,  false, 'perm.treasury.gateway.read', '1.0'),
  ('treasury.inquiry.sheba',          'treasury', '{company}',                 'sensitive', false, false, 'perm.treasury.inquiry.sheba', '1.0'),
  ('pos.terminal.read',               'pos',      '{company,branch,pos_terminal}', 'normal',    true,  false, 'perm.pos.terminal.read', '1.0'),
  ('pos.terminal.manage',             'pos',      '{company,branch}',          'sensitive', false, false, 'perm.pos.terminal.manage', '1.0'),
  ('pos.session.open',                'pos',      '{pos_terminal}',            'normal',    false, false, 'perm.pos.session.open', '1.0'),
  ('pos.shift.open',                  'pos',      '{pos_terminal}',            'normal',    false, false, 'perm.pos.shift.open', '1.0'),
  ('pos.shift.close',                 'pos',      '{pos_terminal}',            'normal',    false, false, 'perm.pos.shift.close', '1.0'),
  ('pos.shift.force_close',           'pos',      '{company,branch}',          'sensitive', false, false, 'perm.pos.shift.force_close', '1.0'),
  ('pos.sale.create',                 'pos',      '{pos_terminal}',            'normal',    false, false, 'perm.pos.sale.create', '1.0'),
  ('pos.sale.discount',               'pos',      '{pos_terminal}',            'sensitive', false, false, 'perm.pos.sale.discount', '1.0'),
  ('pos.sale.price_override',         'pos',      '{pos_terminal}',            'sensitive', false, false, 'perm.pos.sale.price_override', '1.0'),
  ('pos.sale.on_account',             'pos',      '{pos_terminal}',            'sensitive', false, false, 'perm.pos.sale.on_account', '1.0'),
  ('pos.return.create',               'pos',      '{pos_terminal}',            'sensitive', false, false, 'perm.pos.return.create', '1.0'),
  ('pos.return.without_receipt',      'pos',      '{pos_terminal}',            'critical',  false, false, 'perm.pos.return.without_receipt', '1.0'),
  ('pos.order.void_sent',             'pos',      '{pos_terminal}',            'sensitive', false, false, 'perm.pos.order.void_sent', '1.0'),
  ('pos.cash.movement',               'pos',      '{pos_terminal}',            'sensitive', false, false, 'perm.pos.cash.movement', '1.0'),
  ('pos.sync.review',                 'pos',      '{company,branch}',          'sensitive', false, false, 'perm.pos.sync.review', '1.0'),
  ('pos.menu.manage',                 'pos',      '{company,branch}',          'normal',    false, false, 'perm.pos.menu.manage', '1.0'),
  ('pos.report.read',                 'pos',      '{company,branch,pos_terminal}', 'normal', true, false, 'perm.pos.report.read', '1.0'),
  ('pos.edge.manage',                 'pos',      '{company,branch}',          'critical',  false, false, 'perm.pos.edge.manage', '1.0'),
  ('pos.edge.read',                   'pos',      '{company,branch}',          'normal',    true,  false, 'perm.pos.edge.read', '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.role_template_permission (template_code, permission_code)
SELECT v.t, v.p FROM (VALUES
  ('accountant','treasury.fund.read'), ('accountant','treasury.document.read'), ('accountant','treasury.document.create'),
  ('accountant','treasury.document.post'), ('accountant','treasury.allocation.manage'), ('accountant','treasury.cheque.read'),
  ('accountant','treasury.cheque.manage'), ('accountant','treasury.cheque.print'), ('accountant','treasury.statement.import'),
  ('accountant','treasury.recon.match'), ('accountant','treasury.card.read'), ('accountant','treasury.card.settle'),
  ('accountant','treasury.gateway.read'), ('accountant','treasury.gateway.link.create'), ('accountant','treasury.transfer.create'),
  ('accountant','treasury.cash_count.post'), ('accountant','pos.report.read'), ('accountant','pos.sync.review'),
  ('cashier','pos.session.open'), ('cashier','pos.shift.open'), ('cashier','pos.shift.close'), ('cashier','pos.sale.create'),
  ('cashier','pos.terminal.read'), ('cashier','treasury.petty_cash.claim'),
  ('sales_clerk','treasury.document.read'), ('sales_clerk','treasury.gateway.link.create'),
  ('auditor','treasury.fund.read'), ('auditor','treasury.document.read'), ('auditor','treasury.cheque.read'),
  ('auditor','treasury.card.read'), ('auditor','treasury.gateway.read'), ('auditor','pos.report.read'), ('auditor','pos.terminal.read')
) AS v(t, p)
ON CONFLICT DO NOTHING;

INSERT INTO core.setting_def (key, module, value_type, enum_values, min_value, max_value, allowed_levels, default_value,
                              read_permission, write_permission, description_key, introduced_in) VALUES
  ('treasury.cheque.bounce_target',        'treasury', 'enum', '{bounced_account,party_receivable}', NULL, NULL, '{tenant,company}', '"bounced_account"', NULL, 'core.setting.manage', 'setting.treasury.cheque.bounce_target', '1.0'),
  ('treasury.cheque.protest_cost_target',  'treasury', 'enum', '{expense,party_receivable}', NULL, NULL, '{tenant,company}', '"party_receivable"', NULL, 'core.setting.manage', 'setting.treasury.cheque.protest_cost_target', '1.0'),
  ('treasury.cheque.sayad_accept_required','treasury', 'enum', '{off,warn,block}', NULL, NULL, '{tenant,company}', '"warn"', NULL, 'core.setting.manage', 'setting.treasury.cheque.sayad_accept_required', '1.0'),
  ('treasury.cheque.long_term_months',     'treasury', 'int',  NULL, 1, 60, '{tenant,company}', '12', NULL, 'core.setting.manage', 'setting.treasury.cheque.long_term_months', '1.0'),
  ('treasury.cheque.reminder_days',        'treasury', 'json', NULL, NULL, NULL, '{tenant,company,user}', '[3,1]', NULL, 'core.setting.manage', 'setting.treasury.cheque.reminder_days', '1.0'),
  ('treasury.cheque.sayad_register_reminder_h','treasury', 'int', NULL, 1, 168, '{tenant,company}', '24', NULL, 'core.setting.manage', 'setting.treasury.cheque.sayad_register_reminder_h', '1.0'),
  ('treasury.recon.auto_match_threshold',  'treasury', 'decimal', NULL, 0.5, 1, '{tenant,company}', '"0.95"', NULL, 'core.setting.manage', 'setting.treasury.recon.auto_match_threshold', '1.0'),
  ('treasury.recon.date_window_days',      'treasury', 'int',  NULL, 0, 30, '{tenant,company}', '3', NULL, 'core.setting.manage', 'setting.treasury.recon.date_window_days', '1.0'),
  ('treasury.card.settlement_window_days', 'treasury', 'int',  NULL, 0, 15, '{tenant,company}', '3', NULL, 'core.setting.manage', 'setting.treasury.card.settlement_window_days', '1.0'),
  ('treasury.card.clearing_alert_days',    'treasury', 'int',  NULL, 1, 60, '{tenant,company}', '5', NULL, 'core.setting.manage', 'setting.treasury.card.clearing_alert_days', '1.0'),
  ('treasury.gateway.inquiry_after_min',   'treasury', 'int',  NULL, 1, 1440, '{tenant}', '15', NULL, 'core.setting.manage', 'setting.treasury.gateway.inquiry_after_min', '1.0'),
  ('pos.offline.max_hours',                'pos', 'int',  NULL, 1, 720, '{tenant,company,branch}', '72', NULL, 'core.setting.manage', 'setting.pos.offline.max_hours', '1.0'),
  ('pos.offline.max_amount',               'pos', 'decimal', NULL, 0, NULL, '{tenant,company,branch}', '"0"', NULL, 'core.setting.manage', 'setting.pos.offline.max_amount', '1.0'),
  ('pos.offline.max_credit_amount',        'pos', 'decimal', NULL, 0, NULL, '{tenant,company,branch}', '"0"', NULL, 'core.setting.manage', 'setting.pos.offline.max_credit_amount', '1.0'),
  ('pos.offline.negative_stock',           'pos', 'enum', '{allow_warn,review}', NULL, NULL, '{tenant,company,branch}', '"allow_warn"', NULL, 'core.setting.manage', 'setting.pos.offline.negative_stock', '1.0'),
  ('pos.offline.price_variance_pct',       'pos', 'decimal', NULL, 0, 100, '{tenant,company}', '"0"', NULL, 'core.setting.manage', 'setting.pos.offline.price_variance_pct', '1.0'),
  ('pos.sync.clock_skew_max_s',            'pos', 'int',  NULL, 5, 3600, '{tenant}', '120', NULL, 'core.setting.manage', 'setting.pos.sync.clock_skew_max_s', '1.0'),
  ('pos.gl_posting_mode',                  'pos', 'enum', '{per_ticket,per_shift}', NULL, NULL, '{tenant,company,branch}', '"per_ticket"', NULL, 'core.setting.manage', 'setting.pos.gl_posting_mode', '1.0'),
  ('pos.service_charge.percent',           'pos', 'decimal', NULL, 0, 100, '{tenant,company,branch}', '"0"', NULL, 'core.setting.manage', 'setting.pos.service_charge.percent', '1.0'),
  ('pos.tips.enabled',                     'pos', 'bool', NULL, NULL, NULL, '{tenant,company,branch}', 'false', NULL, 'core.setting.manage', 'setting.pos.tips.enabled', '1.0'),
  ('pos.cash_rounding_increment',          'pos', 'decimal', NULL, 0, NULL, '{tenant,company,branch}', '"0"', NULL, 'core.setting.manage', 'setting.pos.cash_rounding_increment', '1.0'),
  ('pos.tax.warn_before_deadline_h',       'pos', 'int',  NULL, 1, 144, '{tenant}', '24', NULL, 'core.setting.manage', 'setting.pos.tax.warn_before_deadline_h', '1.0')
ON CONFLICT (key) DO NOTHING;

INSERT INTO core.notification_category (code, module, is_mandatory, default_channels, description_key) VALUES
  ('treasury.cheque',   'treasury', false, '{in_app,sms}', 'ntf.treasury.cheque'),
  ('treasury.bank',     'treasury', false, '{in_app}',     'ntf.treasury.bank'),
  ('treasury.gateway',  'treasury', false, '{in_app}',     'ntf.treasury.gateway'),
  ('pos.sync',          'pos',      true,  '{in_app}',     'ntf.pos.sync'),
  ('pos.tax_deadline',  'pos',      true,  '{in_app,sms}', 'ntf.pos.tax_deadline')
ON CONFLICT DO NOTHING;

INSERT INTO core.event_subscriber (subscriber, ordered, max_attempts, requires_webhook_endpoint, introduced_in) VALUES
  ('pos.sync_streams',               true,  25, false, '1.0'),
  ('pos.party_merged',               false, 25, false, '1.0'),
  ('treasury.party_merged',          false, 25, false, '1.0'),
  ('treasury.payee_bank_changed',    false, 10, false, '1.0'),
  ('treasury.open_item_on_cancel',   true,  25, false, '1.0')
ON CONFLICT DO NOTHING;
INSERT INTO core.event_subscription (event_type, subscriber) VALUES
  ('catalog.*',                      'pos.sync_streams'),
  ('parties.party.*',                'pos.sync_streams'),
  ('parties.role.changed',           'pos.sync_streams'),
  ('parties.hold.*',                 'pos.sync_streams'),
  ('pos.terminal.*',                 'pos.sync_streams'),
  ('parties.party.merged',           'pos.party_merged'),
  ('parties.party.merged',           'treasury.party_merged'),
  ('parties.bank_account.changed',   'treasury.payee_bank_changed')
ON CONFLICT DO NOTHING;

-- رجیستری صدور مستأجر (.hkx): همهٔ جدول‌های مستأجری این فایل
INSERT INTO core.export_table_registry (schema_name, table_name, module, mode, export_order, secret_columns, note) VALUES
  ('treasury','bank_account',          'treasury', 'rows', 400, '{}', NULL),
  ('treasury','cash_box',              'treasury', 'rows', 402, '{}', NULL),
  ('treasury','petty_cash_fund',       'treasury', 'rows', 404, '{}', NULL),
  ('treasury','card_terminal',         'treasury', 'rows', 406, '{}', NULL),
  ('treasury','gateway_account',       'treasury', 'hook', 408, '{credentials_sealed}', 'credentials are re-sealed for the target KEK by the treasury export hook'),
  ('treasury','money_document',        'treasury', 'rows', 410, '{}', NULL),
  ('treasury','open_item',             'treasury', 'rows', 412, '{}', NULL),
  ('treasury','allocation',            'treasury', 'rows', 414, '{}', NULL),
  ('treasury','fund_transfer',         'treasury', 'rows', 416, '{}', NULL),
  ('treasury','cash_count',            'treasury', 'rows', 418, '{}', NULL),
  ('treasury','petty_cash_claim',      'treasury', 'rows', 420, '{}', NULL),
  ('treasury','petty_cash_claim_line', 'treasury', 'rows', 422, '{}', NULL),
  ('treasury','cheque_book',           'treasury', 'rows', 424, '{}', NULL),
  ('treasury','cheque_leaf',           'treasury', 'rows', 426, '{}', NULL),
  ('treasury','cheque',                'treasury', 'rows', 428, '{}', 'verbatim with replica role; post-import hook re-checks event chains and subledger'),
  ('treasury','cheque_event',          'treasury', 'rows', 430, '{}', NULL),
  ('treasury','cheque_sayad_inquiry',  'treasury', 'rows', 432, '{}', NULL),
  ('treasury','cheque_print_template', 'treasury', 'rows', 434, '{}', NULL),
  ('treasury','cheque_print_log',      'treasury', 'rows', 436, '{}', NULL),
  ('treasury','card_txn',              'treasury', 'rows', 438, '{}', NULL),
  ('treasury','card_settlement',       'treasury', 'rows', 440, '{}', NULL),
  ('treasury','card_day_close',        'treasury', 'rows', 442, '{}', NULL),
  ('treasury','gateway_payment',       'treasury', 'rows', 444, '{}', NULL),
  ('treasury','gateway_event',         'treasury', 'rows', 446, '{}', NULL),
  ('treasury','money_instrument',      'treasury', 'rows', 448, '{}', NULL),
  ('treasury','money_counter_line',    'treasury', 'rows', 450, '{}', NULL),
  ('treasury','statement_profile',     'treasury', 'rows', 452, '{}', NULL),
  ('treasury','statement_import',      'treasury', 'rows', 454, '{}', NULL),
  ('treasury','statement_line',        'treasury', 'rows', 456, '{}', NULL),
  ('treasury','recon_rule',            'treasury', 'rows', 458, '{}', NULL),
  ('treasury','recon_match',           'treasury', 'rows', 460, '{}', NULL),
  ('treasury','recon_match_item',      'treasury', 'rows', 462, '{}', NULL),
  ('treasury','bank_reconciliation',   'treasury', 'rows', 464, '{}', NULL),
  ('pos','edge_node',                  'pos', 'rows', 600, '{}', NULL),
  ('pos','terminal',                   'pos', 'rows', 602, '{}', NULL),
  ('pos','business_day',               'pos', 'rows', 604, '{}', NULL),
  ('pos','shift',                      'pos', 'rows', 606, '{}', NULL),
  ('pos','shift_count',                'pos', 'rows', 608, '{}', NULL),
  ('pos','cash_movement',              'pos', 'rows', 610, '{}', NULL),
  ('pos','floor',                      'pos', 'rows', 612, '{}', NULL),
  ('pos','dining_table',               'pos', 'rows', 614, '{}', NULL),
  ('pos','station',                    'pos', 'rows', 616, '{}', NULL),
  ('pos','station_route',              'pos', 'rows', 618, '{}', NULL),
  ('pos','printer',                    'pos', 'rows', 620, '{}', NULL),
  ('pos','modifier_group',             'pos', 'rows', 622, '{}', NULL),
  ('pos','modifier_option',            'pos', 'rows', 624, '{}', NULL),
  ('pos','item_modifier_group',        'pos', 'rows', 626, '{}', NULL),
  ('pos','device_sync_state',          'pos', 'rows', 628, '{}', NULL),
  ('pos','sync_batch',                 'pos', 'rows', 630, '{}', NULL),
  ('pos','device_command',             'pos', 'rows', 632, '{}', 'signed evidence; kept verbatim (retention class pos_command)'),
  ('pos','command_outcome',            'pos', 'rows', 634, '{}', NULL),
  ('pos','device_seq_gap',             'pos', 'rows', 636, '{}', NULL),
  ('pos','client_id_alias',            'pos', 'rows', 638, '{}', NULL),
  ('pos','offline_session',            'pos', 'rows', 640, '{}', NULL),
  ('pos','sync_stream_version',        'pos', 'skip', 642, '{}', 'derived; rebuilt by pos import hook (devices re-bootstrap after a tenant move)'),
  ('pos','stream_change',              'pos', 'skip', 644, '{}', 'derived delta log; rebuilt'),
  ('pos','stream_snapshot',            'pos', 'skip', 646, '{}', 'derived; rebuilt'),
  ('pos','open_order',                 'pos', 'rows', 648, '{}', NULL),
  ('pos','open_order_line',            'pos', 'rows', 650, '{}', NULL),
  ('pos','ticket',                     'pos', 'rows', 652, '{}', NULL),
  ('pos','ticket_line',                'pos', 'rows', 654, '{}', NULL),
  ('pos','ticket_payment',             'pos', 'rows', 656, '{}', NULL)
ON CONFLICT DO NOTHING;

-- =====================================================================
-- ۲۰. دسترسی‌ها (کمینه)
-- =====================================================================
GRANT SELECT ON ref.sayad_credit_status, ref.psp TO hk_app, hk_readonly;
GRANT SELECT ON treasury.cheque_state, treasury.cheque_transition, treasury.gateway_provider, treasury.statement_header_synonym,
                treasury.statement_keyword, treasury.statement_profile_global, pos.command_type TO hk_app, hk_readonly;

-- تغییرپذیر با حذف (پیش‌نویس‌ها و پیکربندی؛ تریگرها حذف را به پیش‌نویس محدود می‌کنند)
GRANT SELECT, INSERT, UPDATE, DELETE ON
  treasury.money_document, treasury.money_instrument, treasury.money_counter_line, treasury.fund_transfer, treasury.cash_count,
  treasury.petty_cash_claim, treasury.petty_cash_claim_line, treasury.card_settlement, treasury.statement_line,
  treasury.statement_profile, treasury.recon_rule, treasury.cheque_print_template,
  pos.floor, pos.dining_table, pos.station, pos.station_route, pos.printer, pos.modifier_group, pos.modifier_option,
  pos.item_modifier_group, pos.open_order_line, pos.edge_node
TO hk_app;
-- تغییرپذیر بدون حذف
GRANT SELECT, INSERT, UPDATE ON
  treasury.bank_account, treasury.cash_box, treasury.petty_cash_fund, treasury.card_terminal, treasury.gateway_account,
  treasury.open_item, treasury.allocation, treasury.cheque_book, treasury.cheque_leaf, treasury.cheque, treasury.card_txn,
  treasury.gateway_payment, treasury.statement_import, treasury.recon_match, treasury.recon_match_item, treasury.bank_reconciliation,
  pos.terminal, pos.business_day, pos.shift, pos.cash_movement, pos.device_sync_state, pos.command_outcome, pos.offline_session,
  pos.sync_stream_version, pos.open_order, pos.ticket, pos.ticket_line, pos.ticket_payment
TO hk_app;
GRANT DELETE ON pos.stream_change TO hk_app;   -- فقط فشرده‌سازی پشت snapshot (تریگر)
-- فقط‌افزودنی
GRANT SELECT, INSERT ON
  treasury.cheque_event, treasury.cheque_sayad_inquiry, treasury.cheque_print_log, treasury.gateway_event, treasury.card_day_close,
  pos.shift_count, pos.sync_batch, pos.device_command, pos.device_seq_gap, pos.client_id_alias, pos.stream_change, pos.stream_snapshot
TO hk_app;

-- hk_readonly: همه به‌جز ستون راز اعتبارنامهٔ درگاه
DO $$
DECLARE r record; cols text;
BEGIN
  FOR r IN SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname IN ('treasury','pos') AND c.relkind IN ('r','v') AND c.relname <> 'gateway_account' LOOP
    EXECUTE format('GRANT SELECT ON %I.%I TO hk_readonly', r.nspname, r.relname);
  END LOOP;
  SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO cols FROM pg_attribute
   WHERE attrelid = 'treasury.gateway_account'::regclass AND attnum > 0 AND NOT attisdropped AND attname <> 'credentials_sealed';
  EXECUTE format('GRANT SELECT (%s) ON treasury.gateway_account TO hk_readonly', cols);
END $$;
GRANT SELECT ON treasury.v_open_item, treasury.v_cheque_due, treasury.v_party_cheque_exposure, treasury.v_card_clearing_aging,
                pos.v_device_sync_health TO hk_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA treasury, pos TO hk_app, hk_readonly;
