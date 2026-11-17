-- =====================================================================
-- حساب‌کتاب — 25_masterdata.sql   (سند طراحی: docs/design/04-masterdata.md)
-- دادهٔ پایه: اشخاص (parties) و کالا/خدمت (catalog)، به‌اضافهٔ دادهٔ مرجع سراسری لازم
-- (ref: کشور، استان، شهر، بانک، کد شبا، BIN کارت، واحدهای مؤدیان، snapshot شناسهٔ کالا)
-- و توابع اعتبارسنجی شناسه‌های ایرانی (ref.is_valid_*) با همتای پایتون و بردار آزمون مشترک.
--
-- پیش‌نیاز اعتبارسنجی مستقل: فقط 00_foundation.sql. در پایگاه یکپارچه، 10_core.sql پیش از این
-- فایل اجرا می‌شود؛ توابع نرمال‌سازی core.fa_* مال 10_core است و این فایل فقط اگر نبودند
-- همان متن fa-norm-v1 را می‌سازد (shim محافظت‌شده؛ سند §۱۳ CR-03).
-- قواعد: PK = id uuid DEFAULT uuidv7()؛ هر جدول مستأجری tenant_id NOT NULL، UNIQUE (tenant_id, id)
-- و core.enable_tenant_rls؛ ارجاع بین جدول‌های مستأجری همیشه FK ترکیبی (tenant_id, x_id)؛
-- FK به ref تک‌ستونی. ویوها WITH (security_invoker = true). خطاها: 'HK_<CODE>: پیام' با ERRCODE P0001.
-- FKهای بیرون از وابستگی‌های این فایل (core.tenant_membership، core.attachment، rules) در سند §۱۲ آمده‌اند.
-- =====================================================================

DO $$
BEGIN
  IF current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'HK_ENCODING: data-plane database must be UTF8 (found %)', current_setting('server_encoding');
  END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- EXCLUDE روی بازه‌های اعتبار قیمت و BOM
CREATE EXTENSION IF NOT EXISTS pg_trgm;      -- جست‌وجوی تقریبی نام و نامزدهای تکراری

-- =====================================================================
-- ۰. shim نرمال‌سازی فارسی (fa-norm-v1) — فقط اگر 10_core اجرا نشده باشد. متن عیناً از 10_core.sql.
-- =====================================================================
DO $shim$
BEGIN
  IF to_regprocedure('core.fa_normalize_text(text)') IS NULL THEN
    EXECUTE $f$
CREATE FUNCTION core.fa_normalize_text(p text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $fn$
SELECT btrim(
  regexp_replace(
   regexp_replace(
    regexp_replace(
     regexp_replace(
      regexp_replace(
       translate(
         replace(normalize(p, NFKC), U&'\000D\000A', U&'\000A'),
         U&'\064A\0649\0643\06C1\0660\0661\0662\0663\0664\0665\0666\0667\0668\0669\0009\000B\000C\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\202F\205F\3000\000D\0085\2028\2029\0640\061C\200B\200E\200F\202A\202B\202C\202D\202E\2066\2067\2068\2069\FEFF\00AD',
         U&'\06CC\06CC\06A9\0647\06F0\06F1\06F2\06F3\06F4\06F5\06F6\06F7\06F8\06F9\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\000A\000A\000A\000A'),
       U&'\200C{2,}', U&'\200C', 'g'),
      U&'\200C*([ \000A])\200C*', '\1', 'g'),
     ' {2,}', ' ', 'g'),
    U&' ?\000A ?', U&'\000A', 'g'),
   U&'\000A{3,}', U&'\000A\000A', 'g'),
  U&' \000A\200C')
$fn$ $f$;
  END IF;
  IF to_regprocedure('core.fa_normalize_ident(text)') IS NULL THEN
    EXECUTE $f$
CREATE FUNCTION core.fa_normalize_ident(p text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $fn$
SELECT btrim(
  regexp_replace(
    translate(core.fa_normalize_text(p),
      U&'\06F0\06F1\06F2\06F3\06F4\06F5\06F6\06F7\06F8\06F9\000A\200C',
      '0123456789 '),
    ' {2,}', ' ', 'g'),
  ' ')
$fn$ $f$;
  END IF;
  IF to_regprocedure('core.fa_search_key(text)') IS NULL THEN
    EXECUTE $f$
CREATE FUNCTION core.fa_search_key(p text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $fn$
SELECT btrim(
  regexp_replace(
    translate(core.fa_normalize_ident(p),
      U&'\0622\0623\0625\0671\0624\0626\06C0\0629ABCDEFGHIJKLMNOPQRSTUVWXYZ'
      || U&'\064B\064C\064D\064E\064F\0650\0651\0652\0653\0654\0655\0656\0657\0658\0659\065A\065B\065C\065D\065E\065F\0670'
      || U&'\06D6\06D7\06D8\06D9\06DA\06DB\06DC\06DF\06E0\06E1\06E2\06E3\06E4\06E5\06E6\06E7\06E8\06EA\06EB\06EC\06ED',
      U&'\0627\0627\0627\0627\0648\06CC\0647\0647abcdefghijklmnopqrstuvwxyz'),
    ' {2,}', ' ', 'g'),
  ' ')
$fn$ $f$;
  END IF;
END $shim$;

-- =====================================================================
-- ۱. ref — توابع اعتبارسنجی شناسه‌ها (خالص، IMMUTABLE؛ ورودی NULL ← false، نه NULL،
--    تا در CHECK به‌اشتباه «قبول» نشود). همتای پایتون: hesabketab.kernel.validators.iran
--    بردارهای مشترک: docs/design/sql/tests/iran_id_vectors_v1.json
-- =====================================================================

-- کد ملی ۱۰ رقمی: وزن‌های ۱۰..۲ روی ۹ رقم اول، r = Σ mod 11، رقم کنترل = r اگر r<2 وگرنه 11-r؛ «همه رقم یکسان» رد.
CREATE OR REPLACE FUNCTION ref.is_valid_national_code(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN p IS NULL OR p !~ '^[0-9]{10}$' OR p ~ '^(.)\1*$' THEN false
    ELSE (SELECT substr(p, 10, 1)::int = CASE WHEN s.r < 2 THEN s.r ELSE 11 - s.r END
            FROM (SELECT sum(substr(p, i, 1)::int * (11 - i)) % 11 AS r FROM generate_series(1, 9) AS i) s)
  END
$$;

-- شناسهٔ ملی اشخاص حقوقی ۱۱ رقمی (قاعدهٔ persian-tools؛ ۳۰۸ از ۳۱۱ شناسهٔ واقعی): d = رقم دهم + 2،
-- وزن‌های 29,27,23,19,17 چرخشی، r = Σ (رقم + d)·w mod 11، رقم کنترل = r (۱۰ ← ۰)؛ ارقام ۴ تا ۹ همه صفر ← رد.
CREATE OR REPLACE FUNCTION ref.is_valid_legal_national_id(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN p IS NULL OR p !~ '^[0-9]{11}$' OR substr(p, 4, 6) = '000000' THEN false
    ELSE (SELECT substr(p, 11, 1)::int = CASE WHEN s.r = 10 THEN 0 ELSE s.r END
            FROM (SELECT sum((substr(p, i, 1)::int + substr(p, 10, 1)::int + 2)
                             * (ARRAY[29, 27, 23, 19, 17])[((i - 1) % 5) + 1]) % 11 AS r
                    FROM generate_series(1, 10) AS i) s)
  END
$$;

-- شمارهٔ اقتصادی: فقط قالب (۱۱ رقم حقوقی = شناسهٔ ملی؛ ۱۴ رقم حقیقی). رقم کنترل ۱۴ رقمی شناخته نیست.
CREATE OR REPLACE FUNCTION ref.is_valid_economic_code(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT coalesce(p ~ '^([0-9]{11}|[0-9]{14})$', false)
$$;

-- کد پستی: فقط ۱۰ رقم (رقم کنترل رسمی شناخته نیست).
CREATE OR REPLACE FUNCTION ref.is_valid_postal_code(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT coalesce(p ~ '^[0-9]{10}$', false)
$$;

-- شبا: IR + ۲ رقم کنترل + ۲۲ رقم؛ ISO 7064 mod-97 (I=18، R=27).
CREATE OR REPLACE FUNCTION ref.is_valid_sheba(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN p IS NULL OR p !~ '^IR[0-9]{24}$' THEN false
    ELSE (substr(p, 5) || '1827' || substr(p, 3, 2))::numeric % 97 = 1
  END
$$;

-- کد بانک سه‌رقمی شبا (ارقام ۵ تا ۷)
CREATE OR REPLACE FUNCTION ref.sheba_bank_code(p text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN p ~ '^IR[0-9]{24}$' THEN substr(p, 5, 3) END
$$;

-- کارت ۱۶ رقمی: Luhn؛ «همه رقم یکسان» رد. BIN برای رد کردن استفاده نمی‌شود (فقط نمایش نام بانک).
CREATE OR REPLACE FUNCTION ref.is_valid_card_number(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN p IS NULL OR p !~ '^[0-9]{16}$' OR p ~ '^(.)\1*$' THEN false
    ELSE (SELECT sum(CASE WHEN x.v > 9 THEN x.v - 9 ELSE x.v END) % 10 = 0
            FROM (SELECT substr(p, i, 1)::int * CASE WHEN i % 2 = 1 THEN 2 ELSE 1 END AS v
                    FROM generate_series(1, 16) AS i) x)
  END
$$;

-- رقم کنترل GTIN (EAN-8/UPC-A/EAN-13/GTIN-14) برای «بدنه» بدون رقم کنترل: وزن ۳ برای راست‌ترین رقم بدنه، سپس ۱، ۳، ...
CREATE OR REPLACE FUNCTION ref.gtin_check_digit(p_body text) RETURNS smallint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN p_body IS NULL OR p_body !~ '^([0-9]{7}|[0-9]{11,13})$' THEN NULL
    ELSE ((10 - (SELECT sum(substr(p_body, length(p_body) - j, 1)::int * CASE WHEN j % 2 = 0 THEN 3 ELSE 1 END)
                   FROM generate_series(0, length(p_body) - 1) AS j) % 10) % 10)::smallint
  END
$$;

CREATE OR REPLACE FUNCTION ref.is_valid_gtin(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN p IS NULL OR p !~ '^([0-9]{8}|[0-9]{12,14})$' THEN false
    ELSE ref.gtin_check_digit(left(p, -1)) = right(p, 1)::smallint
  END
$$;

-- =====================================================================
-- ۲. ref — جدول‌های مرجع سراسری (بدون tenant_id؛ hk_app فقط SELECT؛ به‌روزرسانی فقط با migration
--    داده یا بستهٔ امضاشده توسط hk_migrator). هر ردیف نسخهٔ داده دارد.
-- =====================================================================
CREATE TABLE IF NOT EXISTS ref.country (
  code       char(2) PRIMARY KEY CHECK (code ~ '^[A-Z]{2}$'),          -- ISO 3166-1 alpha-2
  name_fa    text NOT NULL,
  name_en    text NOT NULL,
  is_active  boolean NOT NULL DEFAULT true
);
INSERT INTO ref.country (code, name_fa, name_en) VALUES
  ('IR','ایران','Iran'), ('AF','افغانستان','Afghanistan'), ('IQ','عراق','Iraq'), ('TR','ترکیه','Türkiye'),
  ('AE','امارات متحدهٔ عربی','United Arab Emirates'), ('CN','چین','China'), ('RU','روسیه','Russia'),
  ('AM','ارمنستان','Armenia'), ('AZ','جمهوری آذربایجان','Azerbaijan'), ('PK','پاکستان','Pakistan'),
  ('TM','ترکمنستان','Turkmenistan'), ('OM','عمان','Oman'), ('QA','قطر','Qatar'), ('IN','هند','India'),
  ('DE','آلمان','Germany')
ON CONFLICT (code) DO NOTHING;

-- تقسیمات کشوری: کد رسمی و فهرست کامل با بستهٔ دادهٔ مرجع (divisions_version) بارگذاری می‌شود؛ DDL بذر ندارد.
CREATE TABLE IF NOT EXISTS ref.province (
  code               text PRIMARY KEY CHECK (code ~ '^[0-9A-Z_-]{1,12}$'),
  country_code       char(2) NOT NULL DEFAULT 'IR' REFERENCES ref.country(code),
  name_fa            text NOT NULL,
  name_en            text,
  divisions_version  text NOT NULL,
  is_active          boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS ref.city (
  province_code      text NOT NULL REFERENCES ref.province(code),
  code               text NOT NULL CHECK (code ~ '^[0-9A-Z_-]{1,16}$'),
  name_fa            text NOT NULL,
  name_en            text,
  divisions_version  text NOT NULL,
  is_active          boolean NOT NULL DEFAULT true,
  PRIMARY KEY (province_code, code)
);

-- بانک‌ها: داده‌محور، با ادغام (merged_into_code) و غیرفعال‌سازی، نه enum در کد.
CREATE TABLE IF NOT EXISTS ref.bank (
  code              text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  name_fa           text NOT NULL,
  name_en           text NOT NULL,
  kind              text NOT NULL DEFAULT 'bank' CHECK (kind IN ('bank','credit_institution','central_bank')),
  swift_bic         text CHECK (swift_bic ~ '^[A-Z0-9]{8}([A-Z0-9]{3})?$'),
  is_active         boolean NOT NULL DEFAULT true,
  merged_into_code  text REFERENCES ref.bank(code),
  status_note       text,
  source            text NOT NULL,
  confidence        text NOT NULL CHECK (confidence IN ('high','medium','low')),
  data_version      text NOT NULL,
  CHECK (merged_into_code IS NULL OR (merged_into_code <> code AND NOT is_active))
);

CREATE TABLE IF NOT EXISTS ref.bank_sheba_code (
  sheba_code  char(3) PRIMARY KEY CHECK (sheba_code ~ '^[0-9]{3}$'),
  bank_code   text NOT NULL REFERENCES ref.bank(code)
);

CREATE TABLE IF NOT EXISTS ref.bank_card_bin (
  bin         char(6) PRIMARY KEY CHECK (bin ~ '^[0-9]{6}$'),
  bank_code   text NOT NULL REFERENCES ref.bank(code),
  confidence  text NOT NULL CHECK (confidence IN ('high','medium','low'))
);

-- بذر بانک‌ها از پژوهش ۰۵ §۲-۴-۱ (persian-tools، MIT؛ اطمینان متوسط-بالا). نسخهٔ داده: bank-v1.
INSERT INTO ref.bank (code, name_fa, name_en, kind, is_active, merged_into_code, status_note, source, confidence, data_version) VALUES
  ('central','بانک مرکزی','Central Bank of Iran','central_bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('sanat_madan','بانک صنعت و معدن','Bank of Industry and Mine','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('mellat','بانک ملت','Bank Mellat','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('refah','بانک رفاه کارگران','Refah Kargaran Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('maskan','بانک مسکن','Bank Maskan','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('sepah','بانک سپه','Bank Sepah','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('keshavarzi','بانک کشاورزی','Bank Keshavarzi Iran','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('melli','بانک ملی ایران','Bank Melli Iran','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('tejarat','بانک تجارت','Bank Tejarat','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('saderat','بانک صادرات ایران','Bank Saderat Iran','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('tosee_saderat','بانک توسعهٔ صادرات','Export Development Bank of Iran','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('post_bank','پست بانک','Post Bank of Iran','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('tosee_taavon','بانک توسعهٔ تعاون','Tose''e Ta''avon Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('tosee_credit','مؤسسهٔ اعتباری توسعه','Tose''e Credit Institution','credit_institution',true,NULL,NULL,'research-05 §2-4-1','medium','bank-v1'),
  ('karafarin','بانک کارآفرین','Karafarin Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('parsian','بانک پارسیان','Parsian Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('eghtesad_novin','بانک اقتصاد نوین','EN Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('saman','بانک سامان','Saman Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('pasargad','بانک پاسارگاد','Bank Pasargad','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('sarmayeh','بانک سرمایه','Sarmayeh Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('sina','بانک سینا','Sina Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('mehr_iran','بانک قرض‌الحسنهٔ مهر ایران','Gharzolhasaneh Mehr Iran Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('shahr','بانک شهر','Shahr Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('gardeshgari','بانک گردشگری','Tourism Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('dey','بانک دی','Day Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('iran_zamin','بانک ایران زمین','Iran Zamin Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('resalat','بانک قرض‌الحسنهٔ رسالت','Resalat Gharzolhasaneh Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('melal','مؤسسهٔ اعتباری ملل','Melal Credit Institution','credit_institution',true,NULL,NULL,'research-05 §2-4-1','medium','bank-v1'),
  ('khavarmianeh','بانک خاورمیانه','Middle East Bank','bank',true,NULL,NULL,'research-05 §2-4-1','high','bank-v1'),
  ('noor','مؤسسهٔ اعتباری نور','Noor Credit Institution','credit_institution',true,NULL,NULL,'research-05 §2-4-1','medium','bank-v1'),
  ('iran_venezuela','بانک ایران و ونزوئلا','Iran-Venezuela Bi-National Bank','bank',true,NULL,NULL,'research-05 §2-4-1','medium','bank-v1'),
  ('ghavamin','بانک قوامین','Ghavamin Bank','bank',false,'sepah','ادغام در بانک سپه (اطلاعیهٔ ۱۱ اسفند ۱۳۹۷)','research-05 §2-4-1','high','bank-v1'),
  ('ansar','بانک انصار','Ansar Bank','bank',false,'sepah','ادغام در بانک سپه (اطلاعیهٔ ۱۱ اسفند ۱۳۹۷)','research-05 §2-4-1','high','bank-v1'),
  ('hekmat','بانک حکمت ایرانیان','Hekmat Iranian Bank','bank',false,'sepah','ادغام در بانک سپه (اطلاعیهٔ ۱۱ اسفند ۱۳۹۷)','research-05 §2-4-1','high','bank-v1'),
  ('mehr_eghtesad','بانک مهر اقتصاد','Mehr Eghtesad Bank','bank',false,'sepah','ادغام در بانک سپه (اطلاعیهٔ ۱۱ اسفند ۱۳۹۷)','research-05 §2-4-1','high','bank-v1'),
  ('kosar','مؤسسهٔ اعتباری کوثر','Kosar Credit Institution','credit_institution',false,'sepah','ادغام در بانک سپه (اطلاعیهٔ ۱۱ اسفند ۱۳۹۷)','research-05 §2-4-1','high','bank-v1'),
  ('ayandeh','بانک آینده','Ayandeh Bank','bank',false,'melli','لغو مجوز ۱ آبان ۱۴۰۴؛ سپرده‌ها به بانک ملی منتقل شد؛ اثر بر شبای ۰۶۲ نامعلوم','research-05 §2-4-1','medium','bank-v1')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ref.bank_sheba_code (sheba_code, bank_code) VALUES
  ('010','central'),('011','sanat_madan'),('012','mellat'),('013','refah'),('014','maskan'),('015','sepah'),
  ('016','keshavarzi'),('017','melli'),('018','tejarat'),('019','saderat'),('020','tosee_saderat'),('021','post_bank'),
  ('022','tosee_taavon'),('051','tosee_credit'),('052','ghavamin'),('053','karafarin'),('054','parsian'),
  ('055','eghtesad_novin'),('056','saman'),('057','pasargad'),('058','sarmayeh'),('059','sina'),('060','mehr_iran'),
  ('090','mehr_iran'),('061','shahr'),('062','ayandeh'),('063','ansar'),('064','gardeshgari'),('065','hekmat'),
  ('066','dey'),('069','iran_zamin'),('070','resalat'),('073','kosar'),('075','melal'),('078','khavarmianeh'),
  ('079','mehr_eghtesad'),('080','noor'),('095','iran_venezuela')
ON CONFLICT (sheba_code) DO NOTHING;

INSERT INTO ref.bank_card_bin (bin, bank_code, confidence) VALUES
  ('636797','central','medium'),('627961','sanat_madan','medium'),('610433','mellat','medium'),('991975','mellat','low'),
  ('589463','refah','medium'),('628023','maskan','medium'),('589210','sepah','medium'),('603770','keshavarzi','medium'),
  ('639217','keshavarzi','medium'),('603799','melli','medium'),('170019','melli','low'),('627353','tejarat','medium'),
  ('585983','tejarat','medium'),('603769','saderat','medium'),('903769','saderat','low'),('627648','tosee_saderat','medium'),
  ('207177','tosee_saderat','low'),('627760','post_bank','medium'),('502908','tosee_taavon','medium'),
  ('628157','tosee_credit','medium'),('639599','ghavamin','medium'),('627488','karafarin','medium'),
  ('622106','parsian','medium'),('627884','parsian','medium'),('627412','eghtesad_novin','medium'),
  ('621986','saman','medium'),('502229','pasargad','medium'),('639347','pasargad','medium'),('639607','sarmayeh','medium'),
  ('639346','sina','medium'),('606373','mehr_iran','medium'),('502806','shahr','medium'),('504706','shahr','medium'),
  ('636214','ayandeh','medium'),('627381','ansar','medium'),('505416','gardeshgari','medium'),('505426','gardeshgari','medium'),
  ('636949','hekmat','medium'),('502938','dey','medium'),('505785','iran_zamin','medium'),('504172','resalat','medium'),
  ('505801','kosar','medium'),('606256','melal','medium'),('585949','khavarmianeh','medium'),('639370','mehr_eghtesad','medium')
ON CONFLICT (bin) DO NOTHING;

-- واحدهای سنجش سامانهٔ مؤدیان (RC_UMGS.ST). فهرست کامل (۱۰۲ واحد) با بستهٔ دادهٔ مرجع؛ این‌جا فقط
-- ۲۰ کدی که پژوهش ۰۳ §۲-۱۰ با اطمینان بالا آورده است.
CREATE TABLE IF NOT EXISTS ref.moadian_unit (
  code          text PRIMARY KEY CHECK (code ~ '^[0-9]{3,8}$'),
  name_fa       text NOT NULL,
  list_version  text NOT NULL,
  is_active     boolean NOT NULL DEFAULT true
);
INSERT INTO ref.moadian_unit (code, name_fa, list_version) VALUES
  ('1627','عدد','RC_UMGS.ST-1.18'),('1643','جفت','RC_UMGS.ST-1.18'),('164','کیلوگرم','RC_UMGS.ST-1.18'),
  ('1622','گرم','RC_UMGS.ST-1.18'),('165','متر','RC_UMGS.ST-1.18'),('1645','متر مربع','RC_UMGS.ST-1.18'),
  ('1637','لیتر','RC_UMGS.ST-1.18'),('1628','بسته','RC_UMGS.ST-1.18'),('1624','کارتن','RC_UMGS.ST-1.18'),
  ('1631','دستگاه','RC_UMGS.ST-1.18'),('1641','رول','RC_UMGS.ST-1.18'),('16108','لیوان','RC_UMGS.ST-1.18'),
  ('16103','ساعت','RC_UMGS.ST-1.18'),('16104','روز','RC_UMGS.ST-1.18'),('16112','ماه','RC_UMGS.ST-1.18'),
  ('16121','نفر-ساعت','RC_UMGS.ST-1.18'),('16134','نفر-ماه','RC_UMGS.ST-1.18'),('16114','قطعه','RC_UMGS.ST-1.18'),
  ('1653','واحد','RC_UMGS.ST-1.18'),('1619','ست','RC_UMGS.ST-1.18')
ON CONFLICT (code) DO NOTHING;

-- snapshot شناسه‌های کالا/خدمت (stuffid). فقط هویت و عنوان؛ نرخ مالیات این‌جا نیست (موتور قواعد / بخش مالیات).
CREATE TABLE IF NOT EXISTS ref.sstid (
  sstid             char(13) PRIMARY KEY CHECK (sstid ~ '^[0-9]{13}$'),
  kind              text NOT NULL CHECK (kind IN ('general','specific')),
  title             text NOT NULL,
  is_active         boolean NOT NULL DEFAULT true,
  snapshot_version  text NOT NULL,
  synced_at         timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS sstid_title_trgm ON ref.sstid USING gin (title gin_trgm_ops);

-- =====================================================================
-- ۳. parties — توابع کمکی
-- =====================================================================
-- کلید نام برای تشخیص تکراری (dedup-v1): کلید جست‌وجو، نشانه‌گذاری → فاصله، حذف عنوان‌ها و
-- قالب‌های حقوقی رایج. نسخهٔ تازه = تابع تازه (dedup_name_key_v2) + بازتولید ستون.
CREATE OR REPLACE FUNCTION parties.dedup_name_key(p text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT nullif(btrim(regexp_replace(
           regexp_replace(
             ' ' || regexp_replace(
                      translate(core.fa_search_key(p),
                                '-_.,،؛;:!?()[]{}"''«»/\|+*&^%$#@~`',
                                '                                 '),
                      ' +', '  ', 'g') || ' ',
             ' (شرکت|فروشگاه|اقای|اقا|خانم|سرکار|جناب|سهامی|خاص|عام|مسیولیت|محدود|تعاونی|موسسه|بازرگانی|تولیدی|صنایع|گروه|دکتر|مهندس|حاج|حاجی|سید|سیده|شرکا|و|ltd|co|inc|llc|company|group|mr|mrs|ms|dr|the) ',
             ' ', 'g'),
           ' +', ' ', 'g')), '')
$$;

-- پذیرش شناسهٔ ملی بر حسب نوع شخص و وضعیت بررسی (INV-PTY-01..03)
CREATE OR REPLACE FUNCTION parties.national_id_acceptable(p_person_type text, p_value text, p_status text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT coalesce(CASE p_person_type
    WHEN 'natural' THEN p_value ~ '^[0-9]{10}$' AND (
         (p_status = 'valid'    AND ref.is_valid_national_code(p_value))
      OR (p_status = 'override' AND NOT ref.is_valid_national_code(p_value) AND p_value !~ '^(.)\1*$'))
    WHEN 'legal' THEN p_value ~ '^[0-9]{11}$' AND (
         (p_status = 'valid'    AND ref.is_valid_legal_national_id(p_value))
      OR (p_status = 'override' AND NOT ref.is_valid_legal_national_id(p_value) AND p_value !~ '^(.)\1*$'))
    WHEN 'civil_partnership' THEN p_value ~ '^[0-9]{11}$' AND p_status = 'format_only'
    WHEN 'foreign_natural'   THEN p_value ~ '^[0-9]{12}$' AND p_status = 'format_only'
    ELSE false END, false)
$$;

-- «امروز» مستأجر (برای قواعد تاریخ اعتبار قیمت)
CREATE OR REPLACE FUNCTION catalog.tenant_today(p_tenant uuid) RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT (now() AT TIME ZONE coalesce((SELECT t.timezone FROM core.tenant t WHERE t.id = p_tenant), 'Asia/Tehran'))::date
$$;

-- =====================================================================
-- ۴. parties — جدول‌ها
-- =====================================================================
CREATE TABLE IF NOT EXISTS parties.party_group (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  role         text NOT NULL CHECK (role IN ('customer','supplier','employee','shareholder','bank','sales_agent','other')),
  code         text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'),
  name         text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200 AND strpos(name, E'\n') = 0),
  is_default   boolean NOT NULL DEFAULT false,
  is_active    boolean NOT NULL DEFAULT true,
  source_pack  text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, id, role),
  UNIQUE (tenant_id, role, code)
);
SELECT core.enable_tenant_rls('parties.party_group');
CREATE UNIQUE INDEX IF NOT EXISTS party_group_one_default ON parties.party_group (tenant_id, role) WHERE is_default AND is_active;

CREATE TABLE IF NOT EXISTS parties.payment_term (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  code         text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'),
  name         text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code)
);
SELECT core.enable_tenant_rls('parties.payment_term');

CREATE TABLE IF NOT EXISTS parties.payment_term_line (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL DEFAULT uuidv7(),
  payment_term_id         uuid NOT NULL,
  line_no                 smallint NOT NULL CHECK (line_no BETWEEN 1 AND 60),
  portion_percent         numeric(9,6) NOT NULL CHECK (portion_percent > 0 AND portion_percent <= 100),
  due_basis               text NOT NULL CHECK (due_basis IN ('document_date','end_of_jalali_month','end_of_gregorian_month')),
  due_days                integer NOT NULL CHECK (due_days BETWEEN 0 AND 3650),
  early_discount_percent  numeric(9,6) CHECK (early_discount_percent > 0 AND early_discount_percent < 100),
  early_discount_days     integer CHECK (early_discount_days >= 0),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, payment_term_id, line_no),
  FOREIGN KEY (tenant_id, payment_term_id) REFERENCES parties.payment_term(tenant_id, id) ON DELETE CASCADE,
  CHECK ((early_discount_percent IS NULL) = (early_discount_days IS NULL)),
  CHECK (early_discount_days IS NULL OR early_discount_days <= due_days)
);
SELECT core.enable_tenant_rls('parties.payment_term_line');

-- شخص: یک مدل برای همهٔ طرف‌حساب‌ها؛ نقش‌ها در party_role. سطح مستأجر؛ company_id فقط محدودیت دید است.
CREATE TABLE IF NOT EXISTS parties.party (
  tenant_id                    uuid NOT NULL REFERENCES core.tenant(id),
  id                           uuid NOT NULL DEFAULT uuidv7(),
  company_id                   uuid,                       -- NULL = مشترک بین همهٔ شرکت‌های مستأجر
  code                         text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,39}$'),   -- کد تفصیلی نمایشی
  person_type                  text NOT NULL CHECK (person_type IN ('natural','legal','civil_partnership','foreign_natural','foreign_legal')),
  is_anonymous                 boolean NOT NULL DEFAULT false,   -- «مشتری عمومی/نقدی» صندوق
  name                         text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 300 AND strpos(name, E'\n') = 0),
  name_search                  text GENERATED ALWAYS AS (core.fa_search_key(name)) STORED,
  name_key                     text GENERATED ALWAYS AS (parties.dedup_name_key(name)) STORED,
  trade_name                   text CHECK (trade_name = core.fa_normalize_text(trade_name) AND char_length(trade_name) BETWEEN 1 AND 300),
  first_name                   text CHECK (first_name = core.fa_normalize_text(first_name) AND char_length(first_name) BETWEEN 1 AND 100),
  last_name                    text CHECK (last_name = core.fa_normalize_text(last_name) AND char_length(last_name) BETWEEN 1 AND 100),
  father_name                  text CHECK (father_name = core.fa_normalize_text(father_name) AND char_length(father_name) BETWEEN 1 AND 100),
  gender                       text CHECK (gender IN ('male','female')),
  birth_date                   date CHECK (birth_date >= DATE '1900-01-01'),
  birth_cert_no                text CHECK (birth_cert_no ~ '^[0-9]{1,10}$'),
  birth_cert_issue_place       text CHECK (birth_cert_issue_place = core.fa_normalize_text(birth_cert_issue_place) AND char_length(birth_cert_issue_place) BETWEEN 1 AND 100),
  birth_cert_issue_date        date,      -- لیست بیمه (DSW_IDPLC و DSW_IDATE) به این دو نیاز دارد
  nationality                  char(2) REFERENCES ref.country(code),
  national_id                  text,      -- کد ملی (۱۰)، شناسهٔ ملی (۱۱)، شناسهٔ مشارکت مدنی (۱۱)، کد فراگیر اتباع (۱۲)
  national_id_status           text CHECK (national_id_status IN ('valid','format_only','override')),
  national_id_override_reason  text,
  national_id_override_by      uuid,
  national_id_override_at      timestamptz,
  economic_code                text CHECK (economic_code IS NULL OR ref.is_valid_economic_code(economic_code)),
  registration_no              text CHECK (registration_no ~ '^[0-9A-Za-z/-]{1,20}$'),
  registration_date            date,
  passport_no                  text CHECK (passport_no ~ '^[A-Z0-9]{5,20}$'),
  passport_country             char(2) REFERENCES ref.country(code),
  default_currency             char(3) REFERENCES ref.currency(code),
  status                       text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','merged')),
  merged_into_id               uuid,
  merged_at                    timestamptz,
  notes                        text CHECK (notes = core.fa_normalize_text(notes)),
  custom                       jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(custom) = 'object'),
  created_by                   uuid,
  created_at                   timestamptz NOT NULL DEFAULT now(),
  updated_at                   timestamptz NOT NULL DEFAULT now(),
  row_version                  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, merged_into_id) REFERENCES parties.party(tenant_id, id),
  CONSTRAINT party_merge_cols CHECK ((status = 'merged') = (merged_into_id IS NOT NULL) AND (status = 'merged') = (merged_at IS NOT NULL)),
  CONSTRAINT party_merge_self CHECK (merged_into_id IS NULL OR merged_into_id <> id),
  CONSTRAINT party_natural_fields CHECK (person_type IN ('natural','foreign_natural')
        OR num_nonnulls(first_name, last_name, father_name, gender, birth_date, birth_cert_no,
                        birth_cert_issue_place, birth_cert_issue_date) = 0),
  CONSTRAINT party_birth_cert_iranian CHECK (person_type = 'natural'
        OR num_nonnulls(birth_cert_no, birth_cert_issue_place, birth_cert_issue_date) = 0),
  CONSTRAINT party_birth_cert_dates CHECK (birth_cert_issue_date IS NULL OR birth_date IS NULL OR birth_cert_issue_date >= birth_date),
  CONSTRAINT party_legal_fields CHECK (person_type IN ('legal','civil_partnership','foreign_legal')
        OR num_nonnulls(registration_no, registration_date) = 0),
  CONSTRAINT party_anonymous CHECK (NOT is_anonymous
        OR (person_type = 'natural' AND num_nonnulls(national_id, economic_code, passport_no) = 0)),
  CONSTRAINT party_passport_pair CHECK ((passport_no IS NULL) = (passport_country IS NULL)),
  CONSTRAINT party_national_id_presence CHECK ((national_id IS NULL) = (national_id_status IS NULL)),
  CONSTRAINT party_national_id_valid CHECK (national_id IS NULL
        OR parties.national_id_acceptable(person_type, national_id, national_id_status)),
  CONSTRAINT party_national_id_override CHECK (
        (national_id_status = 'override'
           AND char_length(btrim(coalesce(national_id_override_reason, ''))) >= 5
           AND national_id_override_at IS NOT NULL)
     OR (national_id_status IS DISTINCT FROM 'override'
           AND num_nonnulls(national_id_override_reason, national_id_override_by, national_id_override_at) = 0))
);
SELECT core.enable_tenant_rls('parties.party');
CREATE UNIQUE INDEX IF NOT EXISTS party_national_id_uq ON parties.party (tenant_id, national_id)
  WHERE national_id IS NOT NULL AND status <> 'merged';
CREATE INDEX IF NOT EXISTS party_economic_code_idx ON parties.party (tenant_id, economic_code) WHERE economic_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS party_name_search_trgm ON parties.party USING gin (name_search gin_trgm_ops);
CREATE INDEX IF NOT EXISTS party_name_key_trgm ON parties.party USING gin (name_key gin_trgm_ops);
CREATE INDEX IF NOT EXISTS party_merged_into_idx ON parties.party (tenant_id, merged_into_id) WHERE merged_into_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS party_status_idx ON parties.party (tenant_id, status);

CREATE TABLE IF NOT EXISTS parties.party_role (
  tenant_id                          uuid NOT NULL REFERENCES core.tenant(id),
  id                                 uuid NOT NULL DEFAULT uuidv7(),
  party_id                           uuid NOT NULL,
  role                               text NOT NULL CHECK (role IN ('customer','supplier','employee','shareholder','bank','sales_agent','other')),
  company_id                         uuid,          -- NULL = پیش‌فرض همهٔ شرکت‌ها؛ ردیف شرکت‌محور آن را برای همان شرکت بازنویسی می‌کند
  group_id                           uuid,
  is_active                          boolean NOT NULL DEFAULT true,
  credit_limit                       core.amount CHECK (credit_limit >= 0),
  credit_currency                    char(3) REFERENCES ref.currency(code),
  credit_control                     text NOT NULL DEFAULT 'none' CHECK (credit_control IN ('none','warn','block')),
  credit_includes_uncleared_cheques  boolean NOT NULL DEFAULT true,
  payment_term_id                    uuid,
  default_agent_party_id             uuid,
  bank_code                          text REFERENCES ref.bank(code),
  created_at                         timestamptz NOT NULL DEFAULT now(),
  updated_at                         timestamptz NOT NULL DEFAULT now(),
  row_version                        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, party_id, role, company_id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, group_id, role) REFERENCES parties.party_group(tenant_id, id, role),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, payment_term_id) REFERENCES parties.payment_term(tenant_id, id),
  FOREIGN KEY (tenant_id, default_agent_party_id) REFERENCES parties.party(tenant_id, id),
  CONSTRAINT party_role_credit_pair CHECK ((credit_limit IS NULL) = (credit_currency IS NULL)),
  CONSTRAINT party_role_credit_control CHECK (credit_control = 'none' OR credit_limit IS NOT NULL),
  CONSTRAINT party_role_credit_roles CHECK (credit_limit IS NULL OR role IN ('customer','supplier')),
  CONSTRAINT party_role_bank_code CHECK (bank_code IS NULL OR role = 'bank'),
  CONSTRAINT party_role_agent CHECK (default_agent_party_id IS NULL OR (role = 'customer' AND default_agent_party_id <> party_id))
);
SELECT core.enable_tenant_rls('parties.party_role');
CREATE INDEX IF NOT EXISTS party_role_lookup ON parties.party_role (tenant_id, role, group_id);

CREATE TABLE IF NOT EXISTS parties.party_contact (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  party_id      uuid NOT NULL,
  kind          text NOT NULL CHECK (kind IN ('mobile','phone','fax','email','website','other')),
  value         text NOT NULL CHECK (char_length(value) BETWEEN 1 AND 254),
  label         text CHECK (label = core.fa_normalize_text(label)),
  person_name   text CHECK (person_name = core.fa_normalize_text(person_name)),
  job_title     text CHECK (job_title = core.fa_normalize_text(job_title)),
  is_primary    boolean NOT NULL DEFAULT false,
  sms_opt_in    boolean NOT NULL DEFAULT false,      -- رضایت پیامک تبلیغاتی (پیامک تراکنشی به آن وابسته نیست)
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, party_id, kind, value),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT contact_mobile_format CHECK (kind <> 'mobile' OR value ~ '^09[0-9]{9}$' OR (value ~ '^\+[1-9][0-9]{6,14}$' AND value !~ '^\+98')),
  CONSTRAINT contact_phone_format CHECK (kind NOT IN ('phone','fax') OR value ~ '^(0[1-8][0-9]{9}|\+[1-9][0-9]{6,14})(x[0-9]{1,6})?$'),
  CONSTRAINT contact_email_format CHECK (kind <> 'email' OR (value ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' AND value = lower(value))),
  CONSTRAINT contact_website_format CHECK (kind <> 'website' OR value ~ '^https?://[^[:space:]]+$')
);
SELECT core.enable_tenant_rls('parties.party_contact');
CREATE UNIQUE INDEX IF NOT EXISTS party_contact_one_primary ON parties.party_contact (tenant_id, party_id, kind) WHERE is_primary AND is_active;
CREATE INDEX IF NOT EXISTS party_contact_value_idx ON parties.party_contact (tenant_id, kind, value);

CREATE TABLE IF NOT EXISTS parties.party_address (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  party_id             uuid NOT NULL,
  label                text CHECK (label = core.fa_normalize_text(label)),
  is_billing           boolean NOT NULL DEFAULT false,
  is_shipping          boolean NOT NULL DEFAULT false,
  is_registered        boolean NOT NULL DEFAULT false,       -- نشانی ثبتی/قانونی
  is_primary           boolean NOT NULL DEFAULT false,
  country_code         char(2) NOT NULL DEFAULT 'IR' REFERENCES ref.country(code),
  province_code        text REFERENCES ref.province(code),
  city_code            text,
  city_name            text CHECK (city_name = core.fa_normalize_text(city_name)),
  district             text CHECK (district = core.fa_normalize_text(district)),
  address_line         text NOT NULL CHECK (address_line = core.fa_normalize_text(address_line) AND char_length(address_line) BETWEEN 3 AND 500),
  plate                text CHECK (char_length(plate) <= 20),
  unit                 text CHECK (char_length(unit) <= 20),
  floor                text CHECK (char_length(floor) <= 10),
  postal_code          text,
  moadian_branch_code  text CHECK (moadian_branch_code ~ '^[0-9]{4}$'),   -- bbc شعبهٔ خریدار
  latitude             numeric(9,6) CHECK (latitude BETWEEN -90 AND 90),
  longitude            numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
  phone                text CHECK (phone ~ '^(0[1-8][0-9]{9}|\+[1-9][0-9]{6,14})(x[0-9]{1,6})?$'),
  is_active            boolean NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (province_code, city_code) REFERENCES ref.city(province_code, code),
  CONSTRAINT address_geo_pair CHECK ((latitude IS NULL) = (longitude IS NULL)),
  CONSTRAINT address_iran_divisions CHECK (country_code = 'IR' OR num_nonnulls(province_code, city_code) = 0),
  CONSTRAINT address_city_needs_province CHECK (city_code IS NULL OR province_code IS NOT NULL),
  CONSTRAINT address_postal_iran CHECK (country_code <> 'IR' OR postal_code IS NULL OR ref.is_valid_postal_code(postal_code)),
  CONSTRAINT address_postal_other CHECK (country_code = 'IR' OR postal_code IS NULL OR postal_code ~ '^[A-Z0-9 -]{2,12}$')
);
SELECT core.enable_tenant_rls('parties.party_address');
CREATE UNIQUE INDEX IF NOT EXISTS party_address_one_primary ON parties.party_address (tenant_id, party_id) WHERE is_primary AND is_active;
CREATE UNIQUE INDEX IF NOT EXISTS party_address_branch_code ON parties.party_address (tenant_id, party_id, moadian_branch_code)
  WHERE moadian_branch_code IS NOT NULL AND is_active;

CREATE TABLE IF NOT EXISTS parties.party_bank_account (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  party_id               uuid NOT NULL,
  bank_code              text REFERENCES ref.bank(code),
  sheba                  text CHECK (sheba IS NULL OR ref.is_valid_sheba(sheba)),
  card_number            text CHECK (card_number IS NULL OR ref.is_valid_card_number(card_number)),
  account_number         text CHECK (account_number ~ '^[0-9][0-9./-]{2,30}$'),
  branch_name            text CHECK (branch_name = core.fa_normalize_text(branch_name)),
  branch_code            text CHECK (branch_code ~ '^[0-9]{1,6}$'),
  holder_name            text CHECK (holder_name = core.fa_normalize_text(holder_name)),
  currency               char(3) NOT NULL DEFAULT 'IRR' REFERENCES ref.currency(code),
  is_primary             boolean NOT NULL DEFAULT false,
  is_active              boolean NOT NULL DEFAULT true,
  verified_holder_name   text,
  verified_at            timestamptz,
  verification_provider  text,
  verification_ref       text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, party_id, sheba),
  UNIQUE (tenant_id, party_id, card_number),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT bank_account_identifier CHECK (num_nonnulls(sheba, card_number, account_number) >= 1),
  CONSTRAINT bank_account_verification CHECK ((verified_at IS NULL) = (verified_holder_name IS NULL)
                                              AND (verified_at IS NULL) = (verification_provider IS NULL))
);
SELECT core.enable_tenant_rls('parties.party_bank_account');
CREATE UNIQUE INDEX IF NOT EXISTS party_bank_account_one_primary ON parties.party_bank_account (tenant_id, party_id) WHERE is_primary AND is_active;
CREATE INDEX IF NOT EXISTS party_bank_account_sheba_idx ON parties.party_bank_account (tenant_id, sheba) WHERE sheba IS NOT NULL;

CREATE TABLE IF NOT EXISTS parties.party_relation (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  party_id          uuid NOT NULL,
  related_party_id  uuid NOT NULL,
  relation          text NOT NULL CHECK (relation IN ('contact_person','director','shareholder','guarantor','parent_company','family','other')),
  share_percent     numeric(9,6) CHECK (share_percent > 0 AND share_percent <= 100),
  valid_from        date,
  valid_to          date,
  note              text CHECK (note = core.fa_normalize_text(note)),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, party_id, related_party_id, relation),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, related_party_id) REFERENCES parties.party(tenant_id, id) ON DELETE CASCADE,
  CHECK (party_id <> related_party_id),
  CHECK (share_percent IS NULL OR relation = 'shareholder'),
  CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from)
);
SELECT core.enable_tenant_rls('parties.party_relation');

-- توقیف تجاری (فروش/خرید/پرداخت). آزادسازی با ثبت؛ حذف ممنوع (grant).
CREATE TABLE IF NOT EXISTS parties.party_hold (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  party_id      uuid NOT NULL,
  scope         text NOT NULL CHECK (scope IN ('sales','purchase','payment','all')),
  source        text NOT NULL CHECK (source IN ('manual','credit_control','legal','compliance')),
  reason        text NOT NULL CHECK (reason = core.fa_normalize_text(reason) AND char_length(reason) BETWEEN 3 AND 500),
  placed_by     uuid,
  placed_at     timestamptz NOT NULL DEFAULT now(),
  released_by   uuid,
  released_at   timestamptz,
  release_note  text CHECK (release_note = core.fa_normalize_text(release_note)),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  CHECK (released_at IS NULL OR (released_at >= placed_at AND char_length(coalesce(release_note, '')) >= 3)),
  CHECK (released_by IS NULL OR released_at IS NOT NULL)
);
SELECT core.enable_tenant_rls('parties.party_hold');
CREATE UNIQUE INDEX IF NOT EXISTS party_hold_one_active ON parties.party_hold (tenant_id, party_id, scope, source) WHERE released_at IS NULL;

-- کد(های) قدیمی از نرم‌افزار مبدأ؛ پس از ادغام به برنده منتقل می‌شود. migration_run_id ارجاع نرم است
-- (migration در DAG بالادست است؛ FK خلاف جهت ممنوع).
CREATE TABLE IF NOT EXISTS parties.party_legacy_code (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  party_id          uuid NOT NULL,
  source_system     text NOT NULL CHECK (source_system ~ '^[a-z][a-z0-9_]{1,30}$'),   -- holoo, sepidar, mahak, hesabfa, excel, hesabketab, ...
  source_scope      text NOT NULL DEFAULT '' CHECK (char_length(source_scope) <= 100),   -- پایگاه داده/شرکت/سال در مبدأ
  legacy_code       text NOT NULL CHECK (legacy_code = core.fa_normalize_ident(legacy_code) AND char_length(legacy_code) BETWEEN 1 AND 100),
  legacy_name       text,
  legacy_kind       text CHECK (char_length(legacy_kind) <= 40),
  migration_run_id  uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, source_system, source_scope, legacy_code),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id) ON DELETE CASCADE
);
SELECT core.enable_tenant_rls('parties.party_legacy_code');
CREATE INDEX IF NOT EXISTS party_legacy_code_search ON parties.party_legacy_code (tenant_id, legacy_code);

-- سابقهٔ ادغام: فقط‌افزودنی
CREATE TABLE IF NOT EXISTS parties.party_merge (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  winner_party_id   uuid NOT NULL,
  loser_party_id    uuid NOT NULL,
  reason            text NOT NULL CHECK (char_length(btrim(reason)) >= 5),
  merged_by         uuid,
  merged_at         timestamptz NOT NULL DEFAULT now(),
  loser_snapshot    jsonb NOT NULL,
  winner_before     jsonb NOT NULL,
  moved             jsonb NOT NULL,          -- شمار ردیف‌های جابه‌جاشده در جدول‌های parties
  participants      jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(participants) = 'array'),   -- گزارش ماژول‌های دیگر
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, loser_party_id),
  FOREIGN KEY (tenant_id, winner_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, loser_party_id) REFERENCES parties.party(tenant_id, id),
  CHECK (winner_party_id <> loser_party_id)
);
SELECT core.enable_tenant_rls('parties.party_merge');

CREATE TABLE IF NOT EXISTS parties.duplicate_dismissal (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  party_a_id    uuid NOT NULL,
  party_b_id    uuid NOT NULL,
  reason        text CHECK (reason = core.fa_normalize_text(reason)),
  dismissed_by  uuid,
  dismissed_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, party_a_id, party_b_id),
  FOREIGN KEY (tenant_id, party_a_id) REFERENCES parties.party(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, party_b_id) REFERENCES parties.party(tenant_id, id) ON DELETE CASCADE,
  CHECK (party_a_id < party_b_id)
);
SELECT core.enable_tenant_rls('parties.duplicate_dismissal');

-- نتیجهٔ استعلام taxpayer (مؤدیان) — فقط‌افزودنی؛ استعلام را بخش مالیات انجام می‌دهد و از سرویس parties ثبت می‌کند.
CREATE TABLE IF NOT EXISTS parties.party_taxpayer_inquiry (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  party_id         uuid NOT NULL,
  economic_code    text NOT NULL CHECK (ref.is_valid_economic_code(economic_code)),
  outcome          text NOT NULL CHECK (outcome IN ('found','not_found','error')),
  taxpayer_name    text,
  taxpayer_status  text,
  raw              jsonb,
  adapter          text NOT NULL,
  inquired_by      uuid,
  inquired_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id)
);
SELECT core.enable_tenant_rls('parties.party_taxpayer_inquiry');
CREATE INDEX IF NOT EXISTS party_taxpayer_inquiry_last ON parties.party_taxpayer_inquiry (tenant_id, party_id, inquired_at DESC);

-- سری کد نمایشی اشخاص (= کد تفصیلی). دادهٔ پایه است نه سند قانونی: سطح مستأجر، بدون الزام پیوستگی،
-- کاربر می‌تواند کد را دستی بدهد. انتخاب سری: (نقش، گروه) > (نقش) > پیش‌فرض (NULL، NULL).
CREATE TABLE IF NOT EXISTS parties.code_series (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  role         text CHECK (role IN ('customer','supplier','employee','shareholder','bank','sales_agent','other')),
  group_id     uuid,
  prefix       text NOT NULL DEFAULT '' CHECK (prefix ~ '^([A-Za-z0-9][A-Za-z0-9._/-]{0,11})?$'),
  pad_width    smallint NOT NULL DEFAULT 5 CHECK (pad_width BETWEEN 1 AND 12),
  next_value   bigint NOT NULL DEFAULT 1 CHECK (next_value BETWEEN 1 AND 999999999999),
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, role, group_id),
  FOREIGN KEY (tenant_id, group_id, role) REFERENCES parties.party_group(tenant_id, id, role),
  CHECK (group_id IS NULL OR role IS NOT NULL)
);
SELECT core.enable_tenant_rls('parties.code_series');

-- =====================================================================
-- ۵. parties — تریگرها
-- =====================================================================
-- شخص: ماشین حالت، تغییرناپذیری ردیف ادغام‌شده، «merged» فقط از مسیر parties.merge_parties
CREATE OR REPLACE FUNCTION parties.party_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_target_status text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'merged' THEN
      RAISE EXCEPTION 'HK_PARTY_MERGED_ONLY_VIA_MERGE: a party cannot be created in merged state' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'merged' THEN
      RAISE EXCEPTION 'HK_PARTY_MERGED_IMMUTABLE: merged party % cannot be deleted', OLD.id USING ERRCODE = 'P0001';
    END IF;
    RETURN OLD;
  END IF;
  -- UPDATE
  IF NEW.tenant_id <> OLD.tenant_id OR NEW.id <> OLD.id THEN
    RAISE EXCEPTION 'HK_PARTY_IMMUTABLE_FIELD: tenant_id/id are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.status = 'merged' THEN
    -- فقط فشرده‌سازی مسیر: merged_into_id به برندهٔ تازه
    IF (to_jsonb(NEW) - ARRAY['merged_into_id','updated_at','row_version','name_search','name_key'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['merged_into_id','updated_at','row_version','name_search','name_key']) THEN
      RAISE EXCEPTION 'HK_PARTY_MERGED_IMMUTABLE: merged party % is read-only', OLD.id USING ERRCODE = 'P0001';
    END IF;
  ELSIF NEW.status = 'merged' THEN
    IF coalesce(current_setting('hk.parties_merge', true), '') <> NEW.id::text THEN
      RAISE EXCEPTION 'HK_PARTY_MERGED_ONLY_VIA_MERGE: status merged can only be set by parties.merge_parties' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF NEW.merged_into_id IS NOT NULL AND NEW.merged_into_id IS DISTINCT FROM OLD.merged_into_id THEN
    SELECT p.status INTO v_target_status FROM parties.party p WHERE p.tenant_id = NEW.tenant_id AND p.id = NEW.merged_into_id;
    IF v_target_status IS DISTINCT FROM 'active' AND v_target_status IS DISTINCT FROM 'inactive' THEN
      RAISE EXCEPTION 'HK_PARTY_MERGE_CHAIN: merge target % must not itself be merged', NEW.merged_into_id USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_party_guard ON parties.party;
CREATE TRIGGER trg_party_guard BEFORE INSERT OR UPDATE OR DELETE ON parties.party
  FOR EACH ROW EXECUTE FUNCTION parties.party_guard();

-- ردیف‌های فرزند: شخص ادغام‌شده فرزند تازه یا تغییر نمی‌پذیرد (ادغام پیش از برگرداندن وضعیت فرزندان را منتقل می‌کند)
CREATE OR REPLACE FUNCTION parties.child_party_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text; v_party uuid; v_col text := coalesce(TG_ARGV[0], 'party_id');
BEGIN
  v_party := (to_jsonb(NEW) ->> v_col)::uuid;
  IF v_party IS NULL THEN RETURN NEW; END IF;
  SELECT p.status INTO v_status FROM parties.party p WHERE p.tenant_id = NEW.tenant_id AND p.id = v_party;
  IF v_status = 'merged' THEN
    RAISE EXCEPTION 'HK_PARTY_MERGED: party % is merged; use its successor', v_party USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['party_role','party_contact','party_address','party_bank_account','party_hold',
                           'party_legacy_code','party_taxpayer_inquiry'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_child_party_guard ON parties.%I', t);
    EXECUTE format('CREATE TRIGGER trg_child_party_guard BEFORE INSERT OR UPDATE ON parties.%I '
                   'FOR EACH ROW EXECUTE FUNCTION parties.child_party_guard(''party_id'')', t);
  END LOOP;
END $$;
DROP TRIGGER IF EXISTS trg_child_party_guard ON parties.party_relation;
CREATE TRIGGER trg_child_party_guard BEFORE INSERT OR UPDATE ON parties.party_relation
  FOR EACH ROW EXECUTE FUNCTION parties.child_party_guard('party_id');
DROP TRIGGER IF EXISTS trg_child_party_guard_rel ON parties.party_relation;
CREATE TRIGGER trg_child_party_guard_rel BEFORE INSERT OR UPDATE ON parties.party_relation
  FOR EACH ROW EXECUTE FUNCTION parties.child_party_guard('related_party_id');

-- نقش: سازگاری با محدودیت شرکت شخص و «مشتری عمومی»
CREATE OR REPLACE FUNCTION parties.party_role_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE p parties.party;
BEGIN
  SELECT * INTO p FROM parties.party x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.party_id;
  IF p.company_id IS NOT NULL AND NEW.company_id IS NOT NULL AND NEW.company_id <> p.company_id THEN
    RAISE EXCEPTION 'HK_PARTY_ROLE_COMPANY_SCOPE: party % is restricted to another company', NEW.party_id USING ERRCODE = 'P0001';
  END IF;
  IF p.is_anonymous AND (NEW.role <> 'customer' OR NEW.credit_limit IS NOT NULL) THEN
    RAISE EXCEPTION 'HK_PARTY_ANONYMOUS_ROLE: anonymous party can only be a customer without credit' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.default_agent_party_id IS NOT NULL AND EXISTS (
       SELECT 1 FROM parties.party a WHERE a.tenant_id = NEW.tenant_id AND a.id = NEW.default_agent_party_id AND a.status = 'merged') THEN
    RAISE EXCEPTION 'HK_PARTY_MERGED: default agent % is merged', NEW.default_agent_party_id USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_party_role_guard ON parties.party_role;
CREATE TRIGGER trg_party_role_guard BEFORE INSERT OR UPDATE ON parties.party_role
  FOR EACH ROW EXECUTE FUNCTION parties.party_role_guard();

-- جمع سهم خطوط شرایط پرداخت = ۱۰۰ و حداقل یک خط (deferred)
CREATE OR REPLACE FUNCTION parties.payment_term_check() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_terms uuid[]; v_tenant uuid; v_term uuid; v_sum numeric; v_n int;
BEGIN
  IF TG_TABLE_NAME = 'payment_term' THEN
    v_tenant := NEW.tenant_id; v_terms := ARRAY[NEW.id];
  ELSIF TG_OP = 'DELETE' THEN
    v_tenant := OLD.tenant_id; v_terms := ARRAY[OLD.payment_term_id];
  ELSIF TG_OP = 'UPDATE' THEN
    v_tenant := NEW.tenant_id; v_terms := ARRAY[NEW.payment_term_id, OLD.payment_term_id];
  ELSE
    v_tenant := NEW.tenant_id; v_terms := ARRAY[NEW.payment_term_id];
  END IF;
  FOREACH v_term IN ARRAY v_terms LOOP
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM parties.payment_term t WHERE t.tenant_id = v_tenant AND t.id = v_term);
    SELECT coalesce(sum(l.portion_percent), 0), count(*) INTO v_sum, v_n
      FROM parties.payment_term_line l WHERE l.tenant_id = v_tenant AND l.payment_term_id = v_term;
    IF v_n = 0 OR v_sum <> 100 THEN
      RAISE EXCEPTION 'HK_PARTY_PAYMENT_TERM_SUM: payment term % lines sum to % percent in % lines (must be 100)', v_term, v_sum, v_n
        USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_payment_term_sum ON parties.payment_term_line;
CREATE CONSTRAINT TRIGGER trg_payment_term_sum AFTER INSERT OR UPDATE OR DELETE ON parties.payment_term_line
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION parties.payment_term_check();
DROP TRIGGER IF EXISTS trg_payment_term_has_lines ON parties.payment_term;
CREATE CONSTRAINT TRIGGER trg_payment_term_has_lines AFTER INSERT ON parties.payment_term
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION parties.payment_term_check();

-- حساب بانکی: بانک از روی شبا؛ ناسازگاری خطا؛ تغییر شبا/کارت راستی‌آزمایی را پاک می‌کند
CREATE OR REPLACE FUNCTION parties.bank_account_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_bank text;
BEGIN
  IF NEW.sheba IS NOT NULL THEN
    SELECT s.bank_code INTO v_bank FROM ref.bank_sheba_code s WHERE s.sheba_code = ref.sheba_bank_code(NEW.sheba);
    IF NEW.bank_code IS NULL THEN
      NEW.bank_code := v_bank;
    ELSIF v_bank IS NOT NULL AND NEW.bank_code <> v_bank THEN
      RAISE EXCEPTION 'HK_PARTY_BANK_MISMATCH: SHEBA belongs to bank %, not %', v_bank, NEW.bank_code USING ERRCODE = 'P0001';
    END IF;
  ELSIF NEW.card_number IS NOT NULL AND NEW.bank_code IS NULL THEN
    SELECT b.bank_code INTO NEW.bank_code FROM ref.bank_card_bin b WHERE b.bin = left(NEW.card_number, 6);
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.sheba IS DISTINCT FROM OLD.sheba OR NEW.card_number IS DISTINCT FROM OLD.card_number
                           OR NEW.account_number IS DISTINCT FROM OLD.account_number)
     AND NEW.verified_at IS NOT DISTINCT FROM OLD.verified_at THEN
    NEW.verified_at := NULL; NEW.verified_holder_name := NULL; NEW.verification_provider := NULL; NEW.verification_ref := NULL;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_bank_account_guard ON parties.party_bank_account;
CREATE TRIGGER trg_bank_account_guard BEFORE INSERT OR UPDATE ON parties.party_bank_account
  FOR EACH ROW EXECUTE FUNCTION parties.bank_account_guard();

-- توقیف: فقط یک‌بار آزاد می‌شود؛ بقیهٔ ستون‌ها تغییرناپذیر
CREATE OR REPLACE FUNCTION parties.hold_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.released_at IS NOT NULL THEN
    RAISE EXCEPTION 'HK_PARTY_HOLD_RELEASED: hold % is already released', OLD.id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.released_at IS NULL
     OR (to_jsonb(NEW) - ARRAY['released_at','released_by','release_note'])
        IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['released_at','released_by','release_note']) THEN
    RAISE EXCEPTION 'HK_PARTY_HOLD_IMMUTABLE: a hold can only be released' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_hold_guard ON parties.party_hold;
CREATE TRIGGER trg_hold_guard BEFORE UPDATE ON parties.party_hold
  FOR EACH ROW EXECUTE FUNCTION parties.hold_guard();

-- کد قدیمی: فقط party_id جابه‌جا می‌شود (ادغام)
CREATE OR REPLACE FUNCTION parties.legacy_code_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (to_jsonb(NEW) - 'party_id') IS DISTINCT FROM (to_jsonb(OLD) - 'party_id') THEN
    RAISE EXCEPTION 'HK_PARTY_LEGACY_CODE_IMMUTABLE: only party_id may change' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_legacy_code_guard ON parties.party_legacy_code;
CREATE TRIGGER trg_legacy_code_guard BEFORE UPDATE ON parties.party_legacy_code
  FOR EACH ROW EXECUTE FUNCTION parties.legacy_code_guard();

-- کد گروه شخص انتخابگر قواعد ثبت دفتر کل است (ledger.posting_rule.conditions با attr:<role>_group = code؛ parties.posting_attributes)
-- و با کد ارجاع می‌شود، نه FK؛ پس کد و نقش تغییرناپذیرند.
CREATE OR REPLACE FUNCTION parties.party_group_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.code <> OLD.code OR NEW.role <> OLD.role THEN
    RAISE EXCEPTION 'HK_PARTY_GROUP_CODE_IMMUTABLE: group code/role are posting selectors and cannot change' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_party_group_guard ON parties.party_group;
CREATE TRIGGER trg_party_group_guard BEFORE UPDATE ON parties.party_group
  FOR EACH ROW EXECUTE FUNCTION parties.party_group_guard();

-- فقط‌افزودنی‌ها
DROP TRIGGER IF EXISTS trg_immutable ON parties.party_merge;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON parties.party_merge
  FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();
DROP TRIGGER IF EXISTS trg_immutable ON parties.party_taxpayer_inquiry;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON parties.party_taxpayer_inquiry
  FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- updated_at / row_version
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['party_group','payment_term','party','party_role','party_contact','party_address',
                           'party_bank_account','party_relation','code_series'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_touch ON parties.%I', t);
    EXECUTE format('CREATE TRIGGER trg_touch BEFORE UPDATE ON parties.%I FOR EACH ROW EXECUTE FUNCTION core.touch_row()', t);
  END LOOP;
END $$;

-- =====================================================================
-- ۶. parties — ادغام (بخش درون‌ماژولی؛ مشارکت ماژول‌های دیگر در همان تراکنش از سرویس پایتون)
-- =====================================================================
CREATE OR REPLACE FUNCTION parties.merge_parties(p_winner uuid, p_loser uuid, p_reason text, p_actor uuid,
                                                 p_participants jsonb DEFAULT '[]'::jsonb)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_tenant uuid := core.current_tenant_id();
  w parties.party; l parties.party;
  v_merge_id uuid := uuidv7();
  v_moved jsonb := '{}'::jsonb;
  n int;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'HK_TENANT_CONTEXT_MISSING: app.tenant_id is not set' USING ERRCODE = 'P0001';
  END IF;
  IF p_winner = p_loser THEN
    RAISE EXCEPTION 'HK_PARTY_MERGE_SAME: winner and loser are the same party' USING ERRCODE = 'P0001';
  END IF;
  IF char_length(btrim(coalesce(p_reason, ''))) < 5 THEN
    RAISE EXCEPTION 'HK_PARTY_MERGE_REASON: a reason (>= 5 chars) is required' USING ERRCODE = 'P0001';
  END IF;
  -- قفل با ترتیب ثابت (جلوگیری از بن‌بست)
  PERFORM 1 FROM parties.party x WHERE x.tenant_id = v_tenant AND x.id IN (p_winner, p_loser) ORDER BY x.id FOR UPDATE;
  SELECT * INTO w FROM parties.party x WHERE x.tenant_id = v_tenant AND x.id = p_winner;
  IF NOT FOUND THEN RAISE EXCEPTION 'HK_PARTY_NOT_FOUND: %', p_winner USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO l FROM parties.party x WHERE x.tenant_id = v_tenant AND x.id = p_loser;
  IF NOT FOUND THEN RAISE EXCEPTION 'HK_PARTY_NOT_FOUND: %', p_loser USING ERRCODE = 'P0001'; END IF;
  IF w.status = 'merged' OR l.status = 'merged' THEN
    RAISE EXCEPTION 'HK_PARTY_ALREADY_MERGED: winner or loser is already merged' USING ERRCODE = 'P0001';
  END IF;
  IF w.is_anonymous OR l.is_anonymous THEN
    RAISE EXCEPTION 'HK_PARTY_MERGE_ANONYMOUS: the anonymous walk-in party cannot be merged' USING ERRCODE = 'P0001';
  END IF;
  IF l.national_id IS NOT NULL AND (
       (w.national_id IS NOT NULL AND w.national_id <> l.national_id) OR w.person_type <> l.person_type) THEN
    RAISE EXCEPTION 'HK_PARTY_MERGE_IDENTITY_CONFLICT: legal identities differ (swap winner/loser or correct data first)' USING ERRCODE = 'P0001';
  END IF;
  IF w.economic_code IS NOT NULL AND l.economic_code IS NOT NULL AND w.economic_code <> l.economic_code THEN
    RAISE EXCEPTION 'HK_PARTY_MERGE_IDENTITY_CONFLICT: economic codes differ' USING ERRCODE = 'P0001';
  END IF;
  IF w.company_id IS NOT NULL AND l.company_id IS DISTINCT FROM w.company_id THEN
    RAISE EXCEPTION 'HK_PARTY_MERGE_COMPANY_SCOPE: widen the winner''s company scope first' USING ERRCODE = 'P0001';
  END IF;

  -- نقش‌ها: انتقال آن‌هایی که برنده برای همان (نقش، شرکت) ندارد؛ بقیه روی بازنده غیرفعال
  WITH m AS (UPDATE parties.party_role r SET party_id = p_winner
              WHERE r.tenant_id = v_tenant AND r.party_id = p_loser
                AND NOT EXISTS (SELECT 1 FROM parties.party_role x WHERE x.tenant_id = v_tenant AND x.party_id = p_winner
                                  AND x.role = r.role AND x.company_id IS NOT DISTINCT FROM r.company_id)
              RETURNING 1) SELECT count(*) INTO n FROM m;
  v_moved := v_moved || jsonb_build_object('party_role', n);
  UPDATE parties.party_role SET is_active = false WHERE tenant_id = v_tenant AND party_id = p_loser AND is_active;
  WITH m AS (UPDATE parties.party_role SET default_agent_party_id = p_winner
              WHERE tenant_id = v_tenant AND default_agent_party_id = p_loser AND party_id <> p_winner RETURNING 1)
  SELECT count(*) INTO n FROM m;
  v_moved := v_moved || jsonb_build_object('party_role_agent', n);
  UPDATE parties.party_role SET default_agent_party_id = NULL WHERE tenant_id = v_tenant AND default_agent_party_id = p_loser;

  -- راه‌های ارتباطی: انتقال غیرتکراری‌ها؛ تکراری‌ها روی بازنده غیرفعال
  WITH m AS (UPDATE parties.party_contact c SET party_id = p_winner,
                    is_primary = c.is_primary AND NOT EXISTS (SELECT 1 FROM parties.party_contact y WHERE y.tenant_id = v_tenant
                                   AND y.party_id = p_winner AND y.kind = c.kind AND y.is_primary AND y.is_active)
              WHERE c.tenant_id = v_tenant AND c.party_id = p_loser
                AND NOT EXISTS (SELECT 1 FROM parties.party_contact x WHERE x.tenant_id = v_tenant AND x.party_id = p_winner
                                  AND x.kind = c.kind AND x.value = c.value)
              RETURNING 1) SELECT count(*) INTO n FROM m;
  v_moved := v_moved || jsonb_build_object('party_contact', n);
  UPDATE parties.party_contact SET is_active = false, is_primary = false WHERE tenant_id = v_tenant AND party_id = p_loser;

  -- نشانی‌ها: همه منتقل؛ اصلی بودن فقط اگر برنده اصلی ندارد
  WITH m AS (UPDATE parties.party_address a SET party_id = p_winner,
                    is_primary = a.is_primary AND NOT EXISTS (SELECT 1 FROM parties.party_address y WHERE y.tenant_id = v_tenant
                                   AND y.party_id = p_winner AND y.is_primary AND y.is_active),
                    moadian_branch_code = CASE WHEN EXISTS (SELECT 1 FROM parties.party_address z WHERE z.tenant_id = v_tenant
                                   AND z.party_id = p_winner AND z.moadian_branch_code = a.moadian_branch_code AND z.is_active)
                                   THEN NULL ELSE a.moadian_branch_code END
              WHERE a.tenant_id = v_tenant AND a.party_id = p_loser RETURNING 1) SELECT count(*) INTO n FROM m;
  v_moved := v_moved || jsonb_build_object('party_address', n);

  -- حساب‌های بانکی: انتقال غیرتکراری‌ها (شبا/کارت)؛ تکراری‌ها روی بازنده غیرفعال (ممکن است ارجاع خزانه داشته باشند)
  WITH m AS (UPDATE parties.party_bank_account b SET party_id = p_winner,
                    is_primary = b.is_primary AND NOT EXISTS (SELECT 1 FROM parties.party_bank_account y WHERE y.tenant_id = v_tenant
                                   AND y.party_id = p_winner AND y.is_primary AND y.is_active)
              WHERE b.tenant_id = v_tenant AND b.party_id = p_loser
                AND NOT EXISTS (SELECT 1 FROM parties.party_bank_account x WHERE x.tenant_id = v_tenant AND x.party_id = p_winner
                                  AND (x.sheba = b.sheba OR x.card_number = b.card_number))
              RETURNING 1) SELECT count(*) INTO n FROM m;
  v_moved := v_moved || jsonb_build_object('party_bank_account', n);
  UPDATE parties.party_bank_account SET is_active = false, is_primary = false WHERE tenant_id = v_tenant AND party_id = p_loser;

  -- روابط: حذف رابطهٔ برنده↔بازنده؛ انتقال بقیه بدون تکرار
  DELETE FROM parties.party_relation WHERE tenant_id = v_tenant
     AND ((party_id = p_loser AND related_party_id = p_winner) OR (party_id = p_winner AND related_party_id = p_loser));
  WITH m AS (UPDATE parties.party_relation r SET party_id = p_winner
              WHERE r.tenant_id = v_tenant AND r.party_id = p_loser
                AND NOT EXISTS (SELECT 1 FROM parties.party_relation x WHERE x.tenant_id = v_tenant AND x.party_id = p_winner
                                  AND x.related_party_id = r.related_party_id AND x.relation = r.relation) RETURNING 1),
       m2 AS (UPDATE parties.party_relation r SET related_party_id = p_winner
              WHERE r.tenant_id = v_tenant AND r.related_party_id = p_loser
                AND NOT EXISTS (SELECT 1 FROM parties.party_relation x WHERE x.tenant_id = v_tenant AND x.related_party_id = p_winner
                                  AND x.party_id = r.party_id AND x.relation = r.relation) RETURNING 1)
  SELECT (SELECT count(*) FROM m) + (SELECT count(*) FROM m2) INTO n;
  v_moved := v_moved || jsonb_build_object('party_relation', n);
  DELETE FROM parties.party_relation WHERE tenant_id = v_tenant AND (party_id = p_loser OR related_party_id = p_loser);

  -- توقیف‌های فعال: منتقل اگر برنده هم‌ارز ندارد؛ وگرنه آزاد با یادداشت
  WITH m AS (UPDATE parties.party_hold h SET party_id = p_winner
              WHERE h.tenant_id = v_tenant AND h.party_id = p_loser AND h.released_at IS NULL
                AND NOT EXISTS (SELECT 1 FROM parties.party_hold x WHERE x.tenant_id = v_tenant AND x.party_id = p_winner
                                  AND x.scope = h.scope AND x.source = h.source AND x.released_at IS NULL)
              RETURNING 1) SELECT count(*) INTO n FROM m;
  v_moved := v_moved || jsonb_build_object('party_hold', n);
  UPDATE parties.party_hold SET released_at = now(), released_by = p_actor, release_note = 'آزاد در ادغام (هم‌ارز روی برنده)'
   WHERE tenant_id = v_tenant AND party_id = p_loser AND released_at IS NULL;

  -- کدهای قدیمی و کد خود بازنده
  WITH m AS (UPDATE parties.party_legacy_code SET party_id = p_winner WHERE tenant_id = v_tenant AND party_id = p_loser RETURNING 1)
  SELECT count(*) INTO n FROM m;
  v_moved := v_moved || jsonb_build_object('party_legacy_code', n);
  INSERT INTO parties.party_legacy_code (tenant_id, party_id, source_system, source_scope, legacy_code, legacy_name, legacy_kind)
  VALUES (v_tenant, p_winner, 'hesabketab', 'merged', core.fa_normalize_ident(l.code), l.name, 'merged_party')
  ON CONFLICT (tenant_id, source_system, source_scope, legacy_code) DO NOTHING;

  DELETE FROM parties.duplicate_dismissal WHERE tenant_id = v_tenant AND (party_a_id = p_loser OR party_b_id = p_loser);

  -- وضعیت بازنده و فشرده‌سازی مسیر
  PERFORM set_config('hk.parties_merge', p_loser::text, true);
  UPDATE parties.party SET status = 'merged', merged_into_id = p_winner, merged_at = now()
   WHERE tenant_id = v_tenant AND id = p_loser;
  PERFORM set_config('hk.parties_merge', '', true);
  WITH m AS (UPDATE parties.party SET merged_into_id = p_winner
              WHERE tenant_id = v_tenant AND merged_into_id = p_loser AND id <> p_loser RETURNING 1)
  SELECT count(*) INTO n FROM m;
  v_moved := v_moved || jsonb_build_object('path_compressed', n);

  -- برنده شناسه‌های خالی خود را از بازنده می‌گیرد
  UPDATE parties.party SET
      national_id                 = CASE WHEN w.national_id IS NULL THEN l.national_id ELSE national_id END,
      national_id_status          = CASE WHEN w.national_id IS NULL THEN l.national_id_status ELSE national_id_status END,
      national_id_override_reason = CASE WHEN w.national_id IS NULL THEN l.national_id_override_reason ELSE national_id_override_reason END,
      national_id_override_by     = CASE WHEN w.national_id IS NULL THEN l.national_id_override_by ELSE national_id_override_by END,
      national_id_override_at     = CASE WHEN w.national_id IS NULL THEN l.national_id_override_at ELSE national_id_override_at END,
      economic_code               = coalesce(economic_code, l.economic_code),
      passport_no                 = CASE WHEN passport_no IS NULL THEN l.passport_no ELSE passport_no END,
      passport_country            = CASE WHEN passport_no IS NULL THEN l.passport_country ELSE passport_country END,
      registration_no             = CASE WHEN person_type = l.person_type THEN coalesce(registration_no, l.registration_no) ELSE registration_no END
   WHERE tenant_id = v_tenant AND id = p_winner;

  INSERT INTO parties.party_merge (tenant_id, id, winner_party_id, loser_party_id, reason, merged_by,
                                   loser_snapshot, winner_before, moved, participants)
  VALUES (v_tenant, v_merge_id, p_winner, p_loser, btrim(p_reason), p_actor,
          to_jsonb(l), to_jsonb(w), v_moved, coalesce(p_participants, '[]'::jsonb));
  RETURN v_merge_id;
END $$;

-- =====================================================================
-- ۷. parties — توابع پرس‌وجو و ویوها
-- =====================================================================
-- نامزدهای تکراری (مرحلهٔ blocking؛ امتیازدهی نهایی در پایتون)
CREATE OR REPLACE FUNCTION parties.find_duplicate_candidates(p_party_id uuid, p_min_similarity real DEFAULT 0.5, p_limit int DEFAULT 20)
RETURNS TABLE (candidate_id uuid, reasons text[], name_similarity real)
LANGUAGE sql STABLE AS $$
  WITH me AS (SELECT * FROM parties.party WHERE id = p_party_id),
  my_mobiles AS (SELECT c.value FROM parties.party_contact c, me WHERE c.tenant_id = me.tenant_id AND c.party_id = me.id AND c.kind = 'mobile'),
  my_shebas AS (SELECT b.sheba FROM parties.party_bank_account b, me WHERE b.tenant_id = me.tenant_id AND b.party_id = me.id AND b.sheba IS NOT NULL),
  cand AS (
    SELECT c.id,
           array_remove(ARRAY[
             CASE WHEN c.national_id IS NOT NULL AND c.national_id = me.national_id THEN 'national_id' END,
             CASE WHEN c.economic_code IS NOT NULL AND c.economic_code = me.economic_code THEN 'economic_code' END,
             CASE WHEN EXISTS (SELECT 1 FROM parties.party_contact x WHERE x.tenant_id = c.tenant_id AND x.party_id = c.id
                                AND x.kind = 'mobile' AND x.value IN (SELECT value FROM my_mobiles)) THEN 'mobile' END,
             CASE WHEN EXISTS (SELECT 1 FROM parties.party_bank_account x WHERE x.tenant_id = c.tenant_id AND x.party_id = c.id
                                AND x.sheba IN (SELECT sheba FROM my_shebas)) THEN 'sheba' END,
             CASE WHEN similarity(coalesce(c.name_key, ''), coalesce(me.name_key, '')) >= p_min_similarity THEN 'name' END
           ], NULL) AS reasons,
           similarity(coalesce(c.name_key, ''), coalesce(me.name_key, '')) AS sim
      FROM parties.party c, me
     WHERE c.tenant_id = me.tenant_id AND c.id <> me.id AND c.status <> 'merged' AND NOT c.is_anonymous
       AND NOT EXISTS (SELECT 1 FROM parties.duplicate_dismissal d WHERE d.tenant_id = c.tenant_id
                         AND d.party_a_id = least(c.id, me.id) AND d.party_b_id = greatest(c.id, me.id)))
  SELECT id, reasons, sim FROM cand
   WHERE cardinality(reasons) > 0
   ORDER BY (reasons && ARRAY['national_id','economic_code','sheba']) DESC, sim DESC, id
   LIMIT p_limit
$$;

-- تنظیمات مؤثر نقش برای یک شرکت: ردیف شرکت‌محور، وگرنه ردیف پیش‌فرض (company_id NULL)
CREATE OR REPLACE FUNCTION parties.role_settings(p_party_id uuid, p_role text, p_company_id uuid)
RETURNS SETOF parties.party_role
LANGUAGE sql STABLE AS $$
  SELECT r.* FROM parties.party_role r
   WHERE r.party_id = p_party_id AND r.role = p_role AND r.is_active
     AND (r.company_id = p_company_id OR r.company_id IS NULL)
   ORDER BY (r.company_id IS NULL), r.id
   LIMIT 1
$$;

CREATE OR REPLACE VIEW parties.v_party_canonical WITH (security_invoker = true) AS
  SELECT p.tenant_id, p.id AS party_id, coalesce(p.merged_into_id, p.id) AS canonical_party_id, p.status
    FROM parties.party p;

-- قرارداد ledger (DimensionService.ensure_value): ورودی‌های مقدار بُعد «party» برای هر شخص.
-- یک مقدار بُعد به ازای هر شخص (نه هر نقش)؛ کد = کد شخص؛ company_id = محدودیت دید شخص.
CREATE OR REPLACE VIEW parties.v_party_ledger_identity WITH (security_invoker = true) AS
  SELECT p.tenant_id, p.id AS party_id, p.code, p.name, p.company_id, p.status,
         coalesce(p.merged_into_id, p.id) AS canonical_party_id
    FROM parties.party p;

-- ویژگی‌های شرط قاعدهٔ نگاشت حساب (ledger.posting_rule.conditions) برای یک (شخص، نقش، شرکت):
-- {"<role>_group": کد گروه مؤثر, "party_person_type": نوع شخص}. شخص ادغام‌شده به جانشین ترجمه می‌شود.
-- گروه مؤثر: گروه ردیف نقش شرکت‌محور > ردیف پیش‌فرض > گروه پیش‌فرض فعال همان نقش > هیچ (کلید حذف می‌شود).
CREATE OR REPLACE FUNCTION parties.posting_attributes(p_party_id uuid, p_role text, p_company_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE p parties.party; v_group_id uuid; v_group text;
BEGIN
  IF p_role IS NULL OR p_role NOT IN ('customer','supplier','employee','shareholder','bank','sales_agent','other') THEN
    RAISE EXCEPTION 'HK_PARTY_ROLE_INVALID: %', p_role USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO p FROM parties.party x WHERE x.id = p_party_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF p.status = 'merged' THEN
    SELECT * INTO p FROM parties.party x WHERE x.tenant_id = p.tenant_id AND x.id = p.merged_into_id;
  END IF;
  SELECT r.group_id INTO v_group_id FROM parties.role_settings(p.id, p_role, p_company_id) r;
  IF v_group_id IS NOT NULL THEN
    SELECT g.code INTO v_group FROM parties.party_group g WHERE g.tenant_id = p.tenant_id AND g.id = v_group_id;
  ELSE
    SELECT g.code INTO v_group FROM parties.party_group g
     WHERE g.tenant_id = p.tenant_id AND g.role = p_role AND g.is_default AND g.is_active;
  END IF;
  RETURN jsonb_strip_nulls(jsonb_build_object(p_role || '_group', v_group, 'party_person_type', p.person_type));
END $$;

-- تخصیص کد نمایشی شخص از سری مناسب (قفل ردیف سری؛ کدهای دستی موجود رد می‌شوند)
CREATE OR REPLACE FUNCTION parties.next_party_code(p_role text DEFAULT NULL, p_group_id uuid DEFAULT NULL) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_tenant uuid := core.current_tenant_id(); s parties.code_series; v_next bigint; v_code text;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'HK_TENANT_CONTEXT_MISSING: app.tenant_id is not set' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO s FROM parties.code_series c
   WHERE c.tenant_id = v_tenant AND c.is_active
     AND ((c.role = p_role AND c.group_id = p_group_id) OR (c.role = p_role AND c.group_id IS NULL)
          OR (c.role IS NULL AND c.group_id IS NULL))
   ORDER BY (c.group_id IS NULL), (c.role IS NULL)
   LIMIT 1
   FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO parties.code_series (tenant_id, role, group_id) VALUES (v_tenant, NULL, NULL) ON CONFLICT DO NOTHING;
    SELECT * INTO s FROM parties.code_series c WHERE c.tenant_id = v_tenant AND c.role IS NULL AND c.group_id IS NULL FOR UPDATE;
    IF NOT s.is_active THEN
      RAISE EXCEPTION 'HK_PARTY_CODE_SERIES_INACTIVE: no active code series' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  v_next := s.next_value;
  LOOP
    v_code := s.prefix || CASE WHEN length(v_next::text) >= s.pad_width THEN v_next::text ELSE lpad(v_next::text, s.pad_width, '0') END;
    IF char_length(v_code) > 40 OR v_next > 999999999999 THEN
      RAISE EXCEPTION 'HK_PARTY_CODE_SERIES_EXHAUSTED: series % is exhausted', s.id USING ERRCODE = 'P0001';
    END IF;
    v_next := v_next + 1;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM parties.party x WHERE x.tenant_id = v_tenant AND x.code = v_code);
  END LOOP;
  UPDATE parties.code_series SET next_value = v_next WHERE tenant_id = v_tenant AND id = s.id;
  RETURN v_code;
END $$;

CREATE OR REPLACE VIEW parties.v_party_hold_state WITH (security_invoker = true) AS
  SELECT h.tenant_id, h.party_id,
         bool_or(h.scope IN ('sales','all'))    AS sales_hold,
         bool_or(h.scope IN ('purchase','all')) AS purchase_hold,
         bool_or(h.scope IN ('payment','all'))  AS payment_hold,
         count(*)                               AS active_holds
    FROM parties.party_hold h
   WHERE h.released_at IS NULL
   GROUP BY h.tenant_id, h.party_id;

-- پروفایل خریدار برای صورتحساب مؤدیان (فقط طبقه‌بندی؛ نگاشت به tob/bid/tinb/bpc/bbc در بخش مالیات)
CREATE OR REPLACE VIEW parties.v_party_moadian_profile WITH (security_invoker = true) AS
  SELECT p.tenant_id, p.id AS party_id, p.person_type, p.is_anonymous, p.name, p.national_id, p.national_id_status,
         p.economic_code, p.passport_no, p.passport_country, a.id AS address_id, a.postal_code, a.moadian_branch_code
    FROM parties.party p
    LEFT JOIN LATERAL (
      SELECT x.id, x.postal_code, x.moadian_branch_code FROM parties.party_address x
       WHERE x.tenant_id = p.tenant_id AND x.party_id = p.id AND x.is_active
       ORDER BY x.is_registered DESC, x.is_billing DESC, x.is_primary DESC, x.id
       LIMIT 1) a ON true
   WHERE p.status <> 'merged';

-- =====================================================================
-- ۸. catalog — جدول‌ها
-- =====================================================================
CREATE TABLE IF NOT EXISTS catalog.uom (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  code               text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$'),
  name               text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 60),
  symbol             text CHECK (char_length(symbol) <= 10),
  dimension          text NOT NULL CHECK (dimension IN ('count','mass','length','area','volume','time','other')),
  dimension_factor   core.rate CHECK (dimension_factor > 0),   -- ۱ این واحد = factor × واحد مرجع بُعد (عدد، kg، m، m2، l، ساعت)
  qty_decimals       smallint NOT NULL DEFAULT 0 CHECK (qty_decimals BETWEEN 0 AND 6),
  moadian_unit_code  text REFERENCES ref.moadian_unit(code),
  is_active          boolean NOT NULL DEFAULT true,
  source_pack        text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  CHECK (dimension_factor IS NULL OR dimension <> 'other')
);
SELECT core.enable_tenant_rls('catalog.uom');

CREATE TABLE IF NOT EXISTS catalog.item_posting_group (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  code         text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'),
  name         text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  is_active    boolean NOT NULL DEFAULT true,
  source_pack  text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code)
);
SELECT core.enable_tenant_rls('catalog.item_posting_group');

CREATE TABLE IF NOT EXISTS catalog.attribute (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  code                 text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{0,39}$'),
  name                 text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 100),
  value_type           text NOT NULL CHECK (value_type IN ('option','text','number','boolean')),
  unit_label           text CHECK (char_length(unit_label) <= 20),
  can_be_variant_axis  boolean NOT NULL DEFAULT false,
  is_active            boolean NOT NULL DEFAULT true,
  source_pack          text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  CHECK (NOT can_be_variant_axis OR value_type = 'option')
);
SELECT core.enable_tenant_rls('catalog.attribute');

CREATE TABLE IF NOT EXISTS catalog.attribute_value (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  attribute_id  uuid NOT NULL,
  code          text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$'),
  name          text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 60),
  sort_order    integer NOT NULL DEFAULT 0,
  swatch_hex    text CHECK (swatch_hex ~ '^#[0-9a-f]{6}$'),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, attribute_id, id),
  UNIQUE (tenant_id, attribute_id, code),
  FOREIGN KEY (tenant_id, attribute_id) REFERENCES catalog.attribute(tenant_id, id) ON DELETE CASCADE
);
SELECT core.enable_tenant_rls('catalog.attribute_value');

-- قالب ویژگی (از بستهٔ صنفی یا تعریف کاربر): کدام ویژگی‌ها محور variant و کدام توصیفی‌اند
CREATE TABLE IF NOT EXISTS catalog.attribute_set (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  code                 text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{0,39}$'),
  name                 text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 100),
  is_active            boolean NOT NULL DEFAULT true,
  source_pack          text,
  source_pack_version  text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  CHECK ((source_pack IS NULL) = (source_pack_version IS NULL))
);
SELECT core.enable_tenant_rls('catalog.attribute_set');

CREATE TABLE IF NOT EXISTS catalog.attribute_set_member (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  attribute_set_id  uuid NOT NULL,
  attribute_id      uuid NOT NULL,
  usage             text NOT NULL CHECK (usage IN ('variant_axis','descriptive')),
  axis_position     smallint CHECK (axis_position BETWEEN 1 AND 3),
  is_required       boolean NOT NULL DEFAULT false,
  sort_order        integer NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, attribute_set_id, attribute_id),
  FOREIGN KEY (tenant_id, attribute_set_id) REFERENCES catalog.attribute_set(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, attribute_id) REFERENCES catalog.attribute(tenant_id, id),
  CHECK ((usage = 'variant_axis') = (axis_position IS NOT NULL))
);
SELECT core.enable_tenant_rls('catalog.attribute_set_member');
CREATE UNIQUE INDEX IF NOT EXISTS attribute_set_axis_position ON catalog.attribute_set_member (tenant_id, attribute_set_id, axis_position)
  WHERE axis_position IS NOT NULL;

CREATE TABLE IF NOT EXISTS catalog.brand (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  code         text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'),
  name         text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 100),
  name_search  text GENERATED ALWAYS AS (core.fa_search_key(name)) STORED,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code)
);
SELECT core.enable_tenant_rls('catalog.brand');

-- دستهٔ کالا: درخت (بدون چرخه، عمق ≤ ۱۰)
CREATE TABLE IF NOT EXISTS catalog.item_category (
  tenant_id                  uuid NOT NULL REFERENCES core.tenant(id),
  id                         uuid NOT NULL DEFAULT uuidv7(),
  parent_id                  uuid,
  code                       text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'),
  name                       text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  name_search                text GENERATED ALWAYS AS (core.fa_search_key(name)) STORED,
  sort_order                 integer NOT NULL DEFAULT 0,
  default_posting_group_id   uuid,
  default_tax_category_code  text CHECK (default_tax_category_code ~ '^[a-z][a-z0-9_.]{1,63}$'),
  default_uom_id             uuid,
  default_attribute_set_id   uuid,
  is_active                  boolean NOT NULL DEFAULT true,
  source_pack                text,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now(),
  row_version                integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, parent_id) REFERENCES catalog.item_category(tenant_id, id),
  FOREIGN KEY (tenant_id, default_posting_group_id) REFERENCES catalog.item_posting_group(tenant_id, id),
  FOREIGN KEY (tenant_id, default_uom_id) REFERENCES catalog.uom(tenant_id, id),
  FOREIGN KEY (tenant_id, default_attribute_set_id) REFERENCES catalog.attribute_set(tenant_id, id),
  CHECK (parent_id IS NULL OR parent_id <> id)
);
SELECT core.enable_tenant_rls('catalog.item_category');

-- کالا/خدمت (الگو). هر کالا دست‌کم یک variant (SKU) دارد؛ کالای ساده دقیقاً یک variant پیش‌فرض.
CREATE TABLE IF NOT EXISTS catalog.item (
  tenant_id                   uuid NOT NULL REFERENCES core.tenant(id),
  id                          uuid NOT NULL DEFAULT uuidv7(),
  company_id                  uuid,
  code                        text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,39}$'),
  name                        text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 300 AND strpos(name, E'\n') = 0),
  name_search                 text GENERATED ALWAYS AS (core.fa_search_key(name)) STORED,
  short_name                  text CHECK (short_name = core.fa_normalize_text(short_name) AND char_length(short_name) BETWEEN 1 AND 40),
  description                 text CHECK (description = core.fa_normalize_text(description)),
  item_type                   text NOT NULL CHECK (item_type IN ('stock','non_stock','service')),
  category_id                 uuid,
  brand_id                    uuid,
  posting_group_id            uuid,
  attribute_set_id            uuid,
  base_uom_id                 uuid NOT NULL,
  has_variants                boolean NOT NULL DEFAULT false,
  variant_axis1_id            uuid,
  variant_axis2_id            uuid,
  variant_axis3_id            uuid,
  track_serial                boolean NOT NULL DEFAULT false,
  track_batch                 boolean NOT NULL DEFAULT false,
  track_expiry                boolean NOT NULL DEFAULT false,
  shelf_life_days             integer CHECK (shelf_life_days BETWEEN 1 AND 36500),
  warranty_days               integer CHECK (warranty_days BETWEEN 1 AND 36500),
  warranty_provider_party_id  uuid,
  sstid                       text CHECK (sstid ~ '^[0-9]{13}$'),
  sstid_kind                  text CHECK (sstid_kind IN ('general','specific')),
  moadian_title               text CHECK (moadian_title = core.fa_normalize_text(moadian_title) AND char_length(moadian_title) BETWEEN 1 AND 400),
  tax_category_code           text NOT NULL DEFAULT 'standard' CHECK (tax_category_code ~ '^[a-z][a-z0-9_.]{1,63}$'),
  other_tax_category_code     text CHECK (other_tax_category_code ~ '^[a-z][a-z0-9_.]{1,63}$'),
  is_sellable                 boolean NOT NULL DEFAULT true,
  is_purchasable              boolean NOT NULL DEFAULT true,
  allow_discount              boolean NOT NULL DEFAULT true,
  allow_price_override        boolean NOT NULL DEFAULT true,
  status                      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
  usage_locked_at             timestamptz,             -- اولین ثبت قطعی در هر ماژول (CatalogService.mark_used)
  custom                      jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(custom) = 'object'),
  source_pack                 text,
  created_by                  uuid,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  row_version                 integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, category_id) REFERENCES catalog.item_category(tenant_id, id),
  FOREIGN KEY (tenant_id, brand_id) REFERENCES catalog.brand(tenant_id, id),
  FOREIGN KEY (tenant_id, posting_group_id) REFERENCES catalog.item_posting_group(tenant_id, id),
  FOREIGN KEY (tenant_id, attribute_set_id) REFERENCES catalog.attribute_set(tenant_id, id),
  FOREIGN KEY (tenant_id, base_uom_id) REFERENCES catalog.uom(tenant_id, id),
  FOREIGN KEY (tenant_id, variant_axis1_id) REFERENCES catalog.attribute(tenant_id, id),
  FOREIGN KEY (tenant_id, variant_axis2_id) REFERENCES catalog.attribute(tenant_id, id),
  FOREIGN KEY (tenant_id, variant_axis3_id) REFERENCES catalog.attribute(tenant_id, id),
  FOREIGN KEY (tenant_id, warranty_provider_party_id) REFERENCES parties.party(tenant_id, id),
  CONSTRAINT item_tracking_stock_only CHECK (item_type = 'stock' OR NOT (track_serial OR track_batch OR track_expiry)),
  CONSTRAINT item_expiry_needs_batch CHECK (NOT track_expiry OR track_batch),
  CONSTRAINT item_shelf_life_needs_expiry CHECK (shelf_life_days IS NULL OR track_expiry),
  CONSTRAINT item_sstid_pair CHECK ((sstid IS NULL) = (sstid_kind IS NULL)),
  CONSTRAINT item_warranty_provider CHECK (warranty_provider_party_id IS NULL OR warranty_days IS NOT NULL),
  CONSTRAINT item_axes_shape CHECK (has_variants = (variant_axis1_id IS NOT NULL)
        AND (variant_axis2_id IS NULL OR variant_axis1_id IS NOT NULL)
        AND (variant_axis3_id IS NULL OR variant_axis2_id IS NOT NULL)),
  CONSTRAINT item_axes_distinct CHECK (
        (variant_axis2_id IS NULL OR variant_axis2_id <> variant_axis1_id)
    AND (variant_axis3_id IS NULL OR (variant_axis3_id <> variant_axis1_id AND variant_axis3_id <> variant_axis2_id)))
);
SELECT core.enable_tenant_rls('catalog.item');
CREATE INDEX IF NOT EXISTS item_name_search_trgm ON catalog.item USING gin (name_search gin_trgm_ops);
CREATE INDEX IF NOT EXISTS item_category_idx ON catalog.item (tenant_id, category_id);
CREATE INDEX IF NOT EXISTS item_sstid_idx ON catalog.item (tenant_id, sstid) WHERE sstid IS NOT NULL;

-- variant = SKU (واحد نگهداری/فروش). حداکثر سه محور؛ ترکیب مقادیر یکتا.
CREATE TABLE IF NOT EXISTS catalog.item_variant (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  item_id         uuid NOT NULL,
  code            text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,59}$'),
  is_default      boolean NOT NULL DEFAULT false,
  axis1_value_id  uuid,
  axis2_value_id  uuid,
  axis3_value_id  uuid,
  name_suffix     text CHECK (name_suffix = core.fa_normalize_text(name_suffix) AND char_length(name_suffix) BETWEEN 1 AND 120),
  sstid           text CHECK (sstid ~ '^[0-9]{13}$'),
  sstid_kind      text CHECK (sstid_kind IN ('general','specific')),
  plu_code        text CHECK (plu_code ~ '^[1-9][0-9]{0,5}$'),
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  row_version     integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, item_id, id),
  UNIQUE (tenant_id, code),
  UNIQUE NULLS NOT DISTINCT (tenant_id, item_id, axis1_value_id, axis2_value_id, axis3_value_id),
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, axis1_value_id) REFERENCES catalog.attribute_value(tenant_id, id),
  FOREIGN KEY (tenant_id, axis2_value_id) REFERENCES catalog.attribute_value(tenant_id, id),
  FOREIGN KEY (tenant_id, axis3_value_id) REFERENCES catalog.attribute_value(tenant_id, id),
  CONSTRAINT variant_default_no_axes CHECK (NOT is_default OR num_nonnulls(axis1_value_id, axis2_value_id, axis3_value_id) = 0),
  CONSTRAINT variant_axes_shape CHECK ((axis2_value_id IS NULL OR axis1_value_id IS NOT NULL) AND (axis3_value_id IS NULL OR axis2_value_id IS NOT NULL)),
  CONSTRAINT variant_sstid_pair CHECK ((sstid IS NULL) = (sstid_kind IS NULL))
);
SELECT core.enable_tenant_rls('catalog.item_variant');
CREATE UNIQUE INDEX IF NOT EXISTS item_variant_one_default ON catalog.item_variant (tenant_id, item_id) WHERE is_default;
CREATE UNIQUE INDEX IF NOT EXISTS item_variant_plu ON catalog.item_variant (tenant_id, plu_code) WHERE plu_code IS NOT NULL;

-- واحدهای مجاز هر کالا: ۱ واحد = factor × واحد پایه. ردیف پایه (factor = 1) همیشه هست.
CREATE TABLE IF NOT EXISTS catalog.item_uom (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  item_id              uuid NOT NULL,
  uom_id               uuid NOT NULL,
  factor               core.rate NOT NULL CHECK (factor > 0),
  is_base              boolean NOT NULL DEFAULT false,
  allow_sales          boolean NOT NULL DEFAULT true,
  allow_purchase       boolean NOT NULL DEFAULT true,
  is_sales_default     boolean NOT NULL DEFAULT false,
  is_purchase_default  boolean NOT NULL DEFAULT false,
  moadian_unit_code    text REFERENCES ref.moadian_unit(code),     -- بازنویسی کد واحد uom برای این کالا
  is_active            boolean NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, uom_id) REFERENCES catalog.uom(tenant_id, id),
  CONSTRAINT item_uom_base_factor CHECK (NOT is_base OR (factor = 1 AND is_active)),
  CHECK (NOT is_sales_default OR allow_sales),
  CHECK (NOT is_purchase_default OR allow_purchase)
);
SELECT core.enable_tenant_rls('catalog.item_uom');
CREATE UNIQUE INDEX IF NOT EXISTS item_uom_one_base ON catalog.item_uom (tenant_id, item_id) WHERE is_base;
CREATE UNIQUE INDEX IF NOT EXISTS item_uom_one_sales_default ON catalog.item_uom (tenant_id, item_id) WHERE is_sales_default;
CREATE UNIQUE INDEX IF NOT EXISTS item_uom_one_purchase_default ON catalog.item_uom (tenant_id, item_id) WHERE is_purchase_default;

-- ویژگی توصیفی کالا (غیر محور)
CREATE TABLE IF NOT EXISTS catalog.item_attribute_value (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  item_id       uuid NOT NULL,
  attribute_id  uuid NOT NULL,
  value_id      uuid,
  value_text    text CHECK (value_text = core.fa_normalize_text(value_text) AND char_length(value_text) BETWEEN 1 AND 500),
  value_number  numeric,
  value_bool    boolean,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, item_id, attribute_id),
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, attribute_id) REFERENCES catalog.attribute(tenant_id, id),
  FOREIGN KEY (tenant_id, attribute_id, value_id) REFERENCES catalog.attribute_value(tenant_id, attribute_id, id),
  CHECK (num_nonnulls(value_id, value_text, value_number, value_bool) = 1)
);
SELECT core.enable_tenant_rls('catalog.item_attribute_value');

-- بارکد: یکتا در مستأجر؛ به (variant، واحد) اشاره می‌کند.
CREATE TABLE IF NOT EXISTS catalog.barcode (
  tenant_id   uuid NOT NULL REFERENCES core.tenant(id),
  id          uuid NOT NULL DEFAULT uuidv7(),
  item_id     uuid NOT NULL,
  variant_id  uuid NOT NULL,
  uom_id      uuid NOT NULL,
  code        text NOT NULL CHECK (code ~ '^[!-~]{1,64}$'),                 -- ASCII چاپی، بدون فاصله
  symbology   text NOT NULL CHECK (symbology IN ('ean13','ean8','upca','gtin14','code128','code39','qr','other')),
  source      text NOT NULL CHECK (source IN ('manufacturer','internal','supplier','legacy')),
  is_primary  boolean NOT NULL DEFAULT false,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id) ON DELETE CASCADE,
  CONSTRAINT barcode_gtin_shape CHECK (
        (symbology = 'ean13'  AND code ~ '^[0-9]{13}$')
     OR (symbology = 'ean8'   AND code ~ '^[0-9]{8}$')
     OR (symbology = 'upca'   AND code ~ '^[0-9]{12}$')
     OR (symbology = 'gtin14' AND code ~ '^[0-9]{14}$')
     OR symbology NOT IN ('ean13','ean8','upca','gtin14')),
  CONSTRAINT barcode_gtin_check_digit CHECK (symbology NOT IN ('ean13','ean8','upca','gtin14') OR ref.is_valid_gtin(code)),
  CONSTRAINT barcode_internal_rcn CHECK (source <> 'internal' OR (symbology = 'ean13' AND code ~ '^04[0-9]{11}$'))
);
SELECT core.enable_tenant_rls('catalog.barcode');
CREATE UNIQUE INDEX IF NOT EXISTS barcode_one_primary ON catalog.barcode (tenant_id, variant_id, uom_id) WHERE is_primary;

CREATE TABLE IF NOT EXISTS catalog.barcode_counter (
  tenant_id   uuid NOT NULL REFERENCES core.tenant(id),
  id          uuid NOT NULL DEFAULT uuidv7(),
  prefix      text NOT NULL CHECK (prefix = '04'),
  next_value  bigint NOT NULL DEFAULT 1 CHECK (next_value BETWEEN 1 AND 10000000000),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, prefix)
);
SELECT core.enable_tenant_rls('catalog.barcode_counter');

-- الگوی بارکد ترازو (EAN-13 با پیشوند 02 یا 20..29). موقعیت‌ها ۱-مبنا روی کد ۱۳ رقمی؛ رقم ۱۳ = کنترل کل.
CREATE TABLE IF NOT EXISTS catalog.scale_barcode_pattern (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  code                   text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$'),
  name                   text NOT NULL CHECK (name = core.fa_normalize_text(name)),
  prefix                 text NOT NULL CHECK (prefix ~ '^(02|2[0-9])$'),
  plu_start              smallint NOT NULL,
  plu_length             smallint NOT NULL CHECK (plu_length BETWEEN 1 AND 6),
  value_kind             text NOT NULL CHECK (value_kind IN ('weight','price','quantity')),
  value_start            smallint NOT NULL,
  value_length           smallint NOT NULL CHECK (value_length BETWEEN 1 AND 7),
  value_decimals         smallint NOT NULL DEFAULT 0 CHECK (value_decimals BETWEEN 0 AND 4),
  weight_uom_id          uuid,
  price_currency         char(3) REFERENCES ref.currency(code),
  price_amount_unit      core.amount_unit,
  value_check_position   smallint,             -- رقم کنترل داخلی قیمت/وزن (در v1 فقط نادیده گرفته می‌شود)
  is_active              boolean NOT NULL DEFAULT true,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, weight_uom_id) REFERENCES catalog.uom(tenant_id, id),
  CONSTRAINT scale_plu_range CHECK (plu_start >= 3 AND plu_start + plu_length - 1 <= 12),
  CONSTRAINT scale_value_range CHECK (value_start >= 3 AND value_start + value_length - 1 <= 12),
  CONSTRAINT scale_ranges_disjoint CHECK (plu_start + plu_length - 1 < value_start OR value_start + value_length - 1 < plu_start),
  CONSTRAINT scale_check_position CHECK (value_check_position IS NULL OR (value_check_position BETWEEN 3 AND 12
        AND value_check_position NOT BETWEEN plu_start AND plu_start + plu_length - 1
        AND value_check_position NOT BETWEEN value_start AND value_start + value_length - 1)),
  CONSTRAINT scale_weight_uom CHECK ((value_kind = 'weight') = (weight_uom_id IS NOT NULL)),
  CONSTRAINT scale_price_unit CHECK ((value_kind = 'price') = (price_currency IS NOT NULL)
                                     AND (price_currency IS NULL) = (price_amount_unit IS NULL)),
  CONSTRAINT scale_irr_units CHECK (price_currency IS NULL OR price_currency = 'IRR' OR price_amount_unit IS NULL
                                    OR price_amount_unit = 'IRR')
);
SELECT core.enable_tenant_rls('catalog.scale_barcode_pattern');
CREATE UNIQUE INDEX IF NOT EXISTS scale_pattern_active_prefix ON catalog.scale_barcode_pattern (tenant_id, prefix) WHERE is_active;

-- فهرست قیمت (فروش/خرید)؛ مشتق‌شده از فهرست پایه با درصد و گرد کردن
CREATE TABLE IF NOT EXISTS catalog.price_list (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid,
  code                 text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'),
  name                 text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  kind                 text NOT NULL CHECK (kind IN ('sales','purchase')),
  currency             char(3) NOT NULL REFERENCES ref.currency(code),
  price_precision      smallint NOT NULL CHECK (price_precision BETWEEN 0 AND 4),
  prices_include_tax   boolean NOT NULL DEFAULT false,
  base_price_list_id   uuid,
  base_adjust_percent  numeric(9,4) CHECK (base_adjust_percent > -100 AND base_adjust_percent <= 10000),
  rounding_increment   core.amount CHECK (rounding_increment > 0),
  rounding_mode        text CHECK (rounding_mode IN ('nearest','up','down')),
  valid_from           date,
  valid_to             date,
  is_default           boolean NOT NULL DEFAULT false,
  is_active            boolean NOT NULL DEFAULT true,
  created_by           uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, base_price_list_id) REFERENCES catalog.price_list(tenant_id, id),
  CHECK ((base_price_list_id IS NULL) = (base_adjust_percent IS NULL)),
  CHECK ((rounding_increment IS NULL) = (rounding_mode IS NULL)),
  CHECK (base_price_list_id IS NULL OR base_price_list_id <> id),
  CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from)
);
SELECT core.enable_tenant_rls('catalog.price_list');
CREATE UNIQUE INDEX IF NOT EXISTS price_list_one_default ON catalog.price_list (tenant_id, company_id, kind) NULLS NOT DISTINCT
  WHERE is_default AND is_active;

-- سطر قیمت با تاریخ اعتبار و شکست مقداری (min_qty به واحد همین سطر)
CREATE TABLE IF NOT EXISTS catalog.price_list_item (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  price_list_id  uuid NOT NULL,
  item_id        uuid NOT NULL,
  variant_id     uuid,                 -- NULL = همهٔ variantهای کالا
  uom_id         uuid NOT NULL,
  min_qty        core.qty NOT NULL DEFAULT 0 CHECK (min_qty >= 0),
  valid_from     date NOT NULL,
  valid_to       date,
  price          core.amount NOT NULL CHECK (price >= 0),
  created_by     uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, price_list_id) REFERENCES catalog.price_list(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id) ON DELETE CASCADE,
  CHECK (valid_to IS NULL OR valid_to >= valid_from),
  CONSTRAINT price_list_item_no_overlap EXCLUDE USING gist (
    tenant_id WITH =, price_list_id WITH =, item_id WITH =,
    (coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid)) WITH =,
    uom_id WITH =, min_qty WITH =,
    daterange(valid_from, valid_to, '[]') WITH &&)
);
SELECT core.enable_tenant_rls('catalog.price_list_item');
CREATE INDEX IF NOT EXISTS price_list_item_lookup ON catalog.price_list_item (tenant_id, price_list_id, item_id, valid_from);

-- انتساب فهرست قیمت: شخص > گروه شخص > شعبه > پیش‌فرض شرکت (ترتیب در سرویس قیمت‌یابی بخش فروش)
CREATE TABLE IF NOT EXISTS catalog.price_list_assignment (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  price_list_id   uuid NOT NULL,
  party_id        uuid,
  party_group_id  uuid,
  branch_id       uuid,
  company_id      uuid,
  channel         text CHECK (channel IN ('pos','invoice','online')),
  priority        smallint NOT NULL DEFAULT 100 CHECK (priority BETWEEN 0 AND 1000),
  valid_from      date,
  valid_to        date,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  row_version     integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, price_list_id, party_id, party_group_id, branch_id, company_id, channel),
  FOREIGN KEY (tenant_id, price_list_id) REFERENCES catalog.price_list(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, party_group_id) REFERENCES parties.party_group(tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id) REFERENCES core.branch(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  CHECK (num_nonnulls(party_id, party_group_id) <= 1),
  CHECK (num_nonnulls(party_id, party_group_id, branch_id, company_id, channel) >= 1),
  CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from)
);
SELECT core.enable_tenant_rls('catalog.price_list_assignment');

-- اطلاعات تأمین‌کننده برای کالا (کد کالای تأمین‌کننده، حداقل سفارش)
CREATE TABLE IF NOT EXISTS catalog.item_supplier (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  item_id             uuid NOT NULL,
  variant_id          uuid,
  supplier_party_id   uuid NOT NULL,
  supplier_item_code  text CHECK (supplier_item_code = core.fa_normalize_ident(supplier_item_code) AND char_length(supplier_item_code) BETWEEN 1 AND 60),
  supplier_item_name  text CHECK (supplier_item_name = core.fa_normalize_text(supplier_item_name)),
  purchase_uom_id     uuid,
  min_order_qty       core.qty CHECK (min_order_qty > 0),
  lead_time_days      integer CHECK (lead_time_days BETWEEN 0 AND 3650),
  is_preferred        boolean NOT NULL DEFAULT false,
  is_active           boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, item_id, variant_id, supplier_party_id),
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, purchase_uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, supplier_party_id) REFERENCES parties.party(tenant_id, id)
);
SELECT core.enable_tenant_rls('catalog.item_supplier');
CREATE UNIQUE INDEX IF NOT EXISTS item_supplier_code ON catalog.item_supplier (tenant_id, supplier_party_id, supplier_item_code)
  WHERE supplier_item_code IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS item_supplier_one_preferred ON catalog.item_supplier (tenant_id, item_id, variant_id) NULLS NOT DISTINCT
  WHERE is_preferred AND is_active;

-- تصویر کالا (فایل در core.attachment؛ FK در سند §۱۲)
CREATE TABLE IF NOT EXISTS catalog.item_image (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  item_id        uuid NOT NULL,
  variant_id     uuid,
  attachment_id  uuid NOT NULL,
  position       smallint NOT NULL DEFAULT 0 CHECK (position BETWEEN 0 AND 100),
  is_primary     boolean NOT NULL DEFAULT false,
  alt_text       text CHECK (alt_text = core.fa_normalize_text(alt_text)),
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, item_id, attachment_id),
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id) ON DELETE CASCADE
);
SELECT core.enable_tenant_rls('catalog.item_image');
CREATE UNIQUE INDEX IF NOT EXISTS item_image_one_primary ON catalog.item_image (tenant_id, item_id, variant_id) NULLS NOT DISTINCT WHERE is_primary;

CREATE TABLE IF NOT EXISTS catalog.item_legacy_code (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  item_id           uuid NOT NULL,
  variant_id        uuid,
  source_system     text NOT NULL CHECK (source_system ~ '^[a-z][a-z0-9_]{1,30}$'),
  source_scope      text NOT NULL DEFAULT '' CHECK (char_length(source_scope) <= 100),
  legacy_code       text NOT NULL CHECK (legacy_code = core.fa_normalize_ident(legacy_code) AND char_length(legacy_code) BETWEEN 1 AND 100),
  legacy_name       text,
  migration_run_id  uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, source_system, source_scope, legacy_code),
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id) ON DELETE CASCADE
);
SELECT core.enable_tenant_rls('catalog.item_legacy_code');
CREATE INDEX IF NOT EXISTS item_legacy_code_search ON catalog.item_legacy_code (tenant_id, legacy_code);

-- سری کد کالا (مثل «کد گروه + شماره» در هلو). category_id NULL = پیش‌فرض؛ نزدیک‌ترین نیای دارای سری برنده است.
CREATE TABLE IF NOT EXISTS catalog.code_series (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  category_id  uuid,
  prefix       text NOT NULL DEFAULT '' CHECK (prefix ~ '^([A-Za-z0-9][A-Za-z0-9._/-]{0,15})?$'),
  pad_width    smallint NOT NULL DEFAULT 5 CHECK (pad_width BETWEEN 1 AND 12),
  next_value   bigint NOT NULL DEFAULT 1 CHECK (next_value BETWEEN 1 AND 999999999999),
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, category_id),
  FOREIGN KEY (tenant_id, category_id) REFERENCES catalog.item_category(tenant_id, id) ON DELETE CASCADE
);
SELECT core.enable_tenant_rls('catalog.code_series');

-- BOM سبک: kit (بستهٔ فروشی، انفجار هنگام فروش)، recipe (دستور پخت، مصرف هنگام فروش)،
-- production (تولید داخلی کالای انباری مثل سیروپ). منطق مصرف در بخش انبار است.
CREATE TABLE IF NOT EXISTS catalog.bom (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  item_id       uuid NOT NULL,
  variant_id    uuid,                -- NULL = برای همهٔ variantها
  kind          text NOT NULL CHECK (kind IN ('kit','recipe','production')),
  version_no    integer NOT NULL CHECK (version_no >= 1),
  status        text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','archived')),
  valid_from    date,
  valid_to      date,
  yield_qty     core.qty NOT NULL DEFAULT 1 CHECK (yield_qty > 0),
  yield_uom_id  uuid NOT NULL,
  note          text CHECK (note = core.fa_normalize_text(note)),
  activated_at  timestamptz,
  activated_by  uuid,
  archived_at   timestamptz,
  created_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, item_id, variant_id, kind, version_no),
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, yield_uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  CHECK (status = 'draft' OR (valid_from IS NOT NULL AND activated_at IS NOT NULL)),
  CHECK ((status = 'archived') = (archived_at IS NOT NULL)),
  CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from),
  CONSTRAINT bom_active_no_overlap EXCLUDE USING gist (
    tenant_id WITH =, item_id WITH =,
    (coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid)) WITH =,
    kind WITH =, daterange(valid_from, valid_to, '[]') WITH &&) WHERE (status = 'active')
);
SELECT core.enable_tenant_rls('catalog.bom');

CREATE TABLE IF NOT EXISTS catalog.bom_line (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  bom_id                uuid NOT NULL,
  line_no               smallint NOT NULL CHECK (line_no BETWEEN 1 AND 500),
  component_item_id     uuid NOT NULL,
  component_variant_id  uuid,
  qty                   core.qty NOT NULL CHECK (qty > 0),
  uom_id                uuid NOT NULL,
  waste_percent         numeric(7,4) NOT NULL DEFAULT 0 CHECK (waste_percent >= 0 AND waste_percent < 100),
  note                  text CHECK (note = core.fa_normalize_text(note)),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, bom_id, line_no),
  FOREIGN KEY (tenant_id, bom_id) REFERENCES catalog.bom(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, component_item_id) REFERENCES catalog.item(tenant_id, id),
  FOREIGN KEY (tenant_id, component_item_id, component_variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, component_item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id)
);
SELECT core.enable_tenant_rls('catalog.bom_line');

-- =====================================================================
-- ۹. catalog — تریگرها
-- =====================================================================
CREATE OR REPLACE FUNCTION catalog.category_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_cur uuid := NEW.parent_id; v_depth int := 1;
BEGIN
  WHILE v_cur IS NOT NULL LOOP
    IF v_cur = NEW.id THEN
      RAISE EXCEPTION 'HK_CATALOG_CATEGORY_CYCLE: category % would become its own ancestor', NEW.id USING ERRCODE = 'P0001';
    END IF;
    v_depth := v_depth + 1;
    IF v_depth > 10 THEN
      RAISE EXCEPTION 'HK_CATALOG_CATEGORY_TOO_DEEP: category tree depth exceeds 10' USING ERRCODE = 'P0001';
    END IF;
    SELECT c.parent_id INTO v_cur FROM catalog.item_category c WHERE c.tenant_id = NEW.tenant_id AND c.id = v_cur;
  END LOOP;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_category_guard ON catalog.item_category;
CREATE TRIGGER trg_category_guard BEFORE INSERT OR UPDATE OF parent_id ON catalog.item_category
  FOR EACH ROW EXECUTE FUNCTION catalog.category_guard();

-- کد گروه ثبت کالا انتخابگر قواعد ثبت (attr:item_posting_group = code؛ catalog.posting_attributes) است؛ تغییرناپذیر
CREATE OR REPLACE FUNCTION catalog.posting_group_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.code <> OLD.code THEN
    RAISE EXCEPTION 'HK_CATALOG_POSTING_GROUP_CODE_IMMUTABLE: posting group code is a ledger selector and cannot change' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_posting_group_guard ON catalog.item_posting_group;
CREATE TRIGGER trg_posting_group_guard BEFORE UPDATE ON catalog.item_posting_group
  FOR EACH ROW EXECUTE FUNCTION catalog.posting_group_guard();

CREATE OR REPLACE FUNCTION catalog.attribute_axis_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_attr uuid; v_ok boolean; v_attrs uuid[];
BEGIN
  IF TG_TABLE_NAME = 'item' THEN
    v_attrs := ARRAY[NEW.variant_axis1_id, NEW.variant_axis2_id, NEW.variant_axis3_id];
  ELSE
    v_attrs := ARRAY[(to_jsonb(NEW) ->> 'attribute_id')::uuid];
    IF to_jsonb(NEW) ->> 'usage' <> 'variant_axis' THEN v_attrs := ARRAY[]::uuid[]; END IF;
  END IF;
  FOREACH v_attr IN ARRAY v_attrs LOOP
    CONTINUE WHEN v_attr IS NULL;
    SELECT a.can_be_variant_axis INTO v_ok FROM catalog.attribute a WHERE a.tenant_id = NEW.tenant_id AND a.id = v_attr;
    IF v_ok IS NOT TRUE THEN
      RAISE EXCEPTION 'HK_CATALOG_ATTRIBUTE_NOT_AXIS: attribute % cannot be a variant axis', v_attr USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_axis_guard ON catalog.attribute_set_member;
CREATE TRIGGER trg_axis_guard BEFORE INSERT OR UPDATE ON catalog.attribute_set_member
  FOR EACH ROW EXECUTE FUNCTION catalog.attribute_axis_guard();

-- کالا: محورها، قفل پس از استفاده
CREATE OR REPLACE FUNCTION catalog.item_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.usage_locked_at IS NOT NULL THEN
      RAISE EXCEPTION 'HK_CATALOG_ITEM_LOCK_ON_INSERT: usage lock is set by CatalogService.mark_used only' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.tenant_id <> OLD.tenant_id OR NEW.id <> OLD.id THEN
    RAISE EXCEPTION 'HK_CATALOG_IMMUTABLE_FIELD: tenant_id/id are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.usage_locked_at IS NOT NULL THEN
    IF NEW.usage_locked_at IS DISTINCT FROM OLD.usage_locked_at
       OR NEW.base_uom_id <> OLD.base_uom_id OR NEW.item_type <> OLD.item_type
       OR NEW.track_serial <> OLD.track_serial OR NEW.track_batch <> OLD.track_batch
       OR (OLD.has_variants AND NOT NEW.has_variants)
       OR (OLD.variant_axis1_id IS NOT NULL AND NEW.variant_axis1_id IS DISTINCT FROM OLD.variant_axis1_id)
       OR (OLD.variant_axis2_id IS NOT NULL AND NEW.variant_axis2_id IS DISTINCT FROM OLD.variant_axis2_id)
       OR (OLD.variant_axis3_id IS NOT NULL AND NEW.variant_axis3_id IS DISTINCT FROM OLD.variant_axis3_id) THEN
      RAISE EXCEPTION 'HK_CATALOG_ITEM_LOCKED: item % is in use; base unit, type, tracking and existing axes are frozen', OLD.id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_item_guard ON catalog.item;
CREATE TRIGGER trg_item_guard BEFORE INSERT OR UPDATE ON catalog.item
  FOR EACH ROW EXECUTE FUNCTION catalog.item_guard();
DROP TRIGGER IF EXISTS trg_item_axis_guard ON catalog.item;
CREATE TRIGGER trg_item_axis_guard BEFORE INSERT OR UPDATE OF variant_axis1_id, variant_axis2_id, variant_axis3_id ON catalog.item
  FOR EACH ROW EXECUTE FUNCTION catalog.attribute_axis_guard();

-- variant: پس از قفل کالا، مقدار محور فقط از NULL به مقدار (تبدیل variant پیش‌فرض) تغییر می‌کند
CREATE OR REPLACE FUNCTION catalog.variant_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_locked timestamptz;
BEGIN
  IF NEW.item_id <> OLD.item_id OR NEW.tenant_id <> OLD.tenant_id OR NEW.id <> OLD.id THEN
    RAISE EXCEPTION 'HK_CATALOG_IMMUTABLE_FIELD: variant identity is immutable' USING ERRCODE = 'P0001';
  END IF;
  SELECT i.usage_locked_at INTO v_locked FROM catalog.item i WHERE i.tenant_id = NEW.tenant_id AND i.id = NEW.item_id;
  IF v_locked IS NOT NULL AND (
       (OLD.axis1_value_id IS NOT NULL AND NEW.axis1_value_id IS DISTINCT FROM OLD.axis1_value_id)
    OR (OLD.axis2_value_id IS NOT NULL AND NEW.axis2_value_id IS DISTINCT FROM OLD.axis2_value_id)
    OR (OLD.axis3_value_id IS NOT NULL AND NEW.axis3_value_id IS DISTINCT FROM OLD.axis3_value_id)) THEN
    RAISE EXCEPTION 'HK_CATALOG_VARIANT_LOCKED: axis values of a used item''s variant cannot change' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_variant_guard ON catalog.item_variant;
CREATE TRIGGER trg_variant_guard BEFORE UPDATE ON catalog.item_variant
  FOR EACH ROW EXECUTE FUNCTION catalog.variant_guard();

-- واحد کالا: پس از قفل، ضریب و هویت ثابت و حذف ممنوع (غیرفعال کنید)
CREATE OR REPLACE FUNCTION catalog.item_uom_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_locked timestamptz; r record;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  SELECT i.usage_locked_at INTO v_locked FROM catalog.item i WHERE i.tenant_id = r.tenant_id AND i.id = r.item_id;
  IF v_locked IS NULL THEN
    RETURN r;
  END IF;
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'HK_CATALOG_ITEM_LOCKED: unit of a used item cannot be deleted (deactivate it)' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.factor <> OLD.factor OR NEW.uom_id <> OLD.uom_id OR NEW.is_base <> OLD.is_base OR NEW.item_id <> OLD.item_id THEN
    RAISE EXCEPTION 'HK_CATALOG_ITEM_LOCKED: unit factor of a used item is frozen (add a new unit instead)' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_item_uom_guard ON catalog.item_uom;
CREATE TRIGGER trg_item_uom_guard BEFORE UPDATE OR DELETE ON catalog.item_uom
  FOR EACH ROW EXECUTE FUNCTION catalog.item_uom_guard();

-- یکپارچگی کالا (deferred): ردیف واحد پایه؛ variant پیش‌فرض برای کالای ساده؛ مقادیر محور برای کالای variantدار
CREATE OR REPLACE FUNCTION catalog.check_item_integrity(p_tenant uuid, p_item uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE i catalog.item; v_n int; v_bad int;
BEGIN
  SELECT * INTO i FROM catalog.item x WHERE x.tenant_id = p_tenant AND x.id = p_item;
  IF NOT FOUND THEN RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM catalog.item_uom u WHERE u.tenant_id = p_tenant AND u.item_id = p_item
                    AND u.is_base AND u.uom_id = i.base_uom_id) THEN
    RAISE EXCEPTION 'HK_CATALOG_ITEM_BASE_UOM: item % must have exactly one base unit row equal to base_uom_id (factor 1)', i.code
      USING ERRCODE = 'P0001';
  END IF;
  SELECT count(*) INTO v_n FROM catalog.item_variant v WHERE v.tenant_id = p_tenant AND v.item_id = p_item;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'HK_CATALOG_ITEM_NO_VARIANT: item % has no variant (SKU)', i.code USING ERRCODE = 'P0001';
  END IF;
  IF NOT i.has_variants THEN
    IF v_n <> 1 OR NOT EXISTS (SELECT 1 FROM catalog.item_variant v WHERE v.tenant_id = p_tenant AND v.item_id = p_item
                                  AND v.is_default AND v.code = i.code) THEN
      RAISE EXCEPTION 'HK_CATALOG_ITEM_DEFAULT_VARIANT: simple item % needs exactly one default variant with the item code', i.code
        USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT count(*) INTO v_bad
      FROM catalog.item_variant v
      LEFT JOIN catalog.attribute_value a1 ON a1.tenant_id = v.tenant_id AND a1.id = v.axis1_value_id
      LEFT JOIN catalog.attribute_value a2 ON a2.tenant_id = v.tenant_id AND a2.id = v.axis2_value_id
      LEFT JOIN catalog.attribute_value a3 ON a3.tenant_id = v.tenant_id AND a3.id = v.axis3_value_id
     WHERE v.tenant_id = p_tenant AND v.item_id = p_item
       AND (v.is_default
            OR a1.attribute_id IS DISTINCT FROM i.variant_axis1_id
            OR a2.attribute_id IS DISTINCT FROM i.variant_axis2_id
            OR a3.attribute_id IS DISTINCT FROM i.variant_axis3_id);
    IF v_bad > 0 THEN
      RAISE EXCEPTION 'HK_CATALOG_VARIANT_AXES: % variant(s) of item % do not match its axes', v_bad, i.code USING ERRCODE = 'P0001';
    END IF;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION catalog.item_integrity_trg() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_TABLE_NAME = 'item' THEN
    PERFORM catalog.check_item_integrity(NEW.tenant_id, NEW.id);
  ELSE
    IF TG_OP IN ('INSERT','UPDATE') THEN PERFORM catalog.check_item_integrity(NEW.tenant_id, NEW.item_id); END IF;
    IF TG_OP IN ('UPDATE','DELETE') AND (TG_OP = 'DELETE' OR OLD.item_id <> NEW.item_id) THEN
      PERFORM catalog.check_item_integrity(OLD.tenant_id, OLD.item_id);
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_item_integrity ON catalog.item;
CREATE CONSTRAINT TRIGGER trg_item_integrity AFTER INSERT OR UPDATE ON catalog.item
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION catalog.item_integrity_trg();
DROP TRIGGER IF EXISTS trg_item_integrity ON catalog.item_variant;
CREATE CONSTRAINT TRIGGER trg_item_integrity AFTER INSERT OR UPDATE OR DELETE ON catalog.item_variant
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION catalog.item_integrity_trg();
DROP TRIGGER IF EXISTS trg_item_integrity ON catalog.item_uom;
CREATE CONSTRAINT TRIGGER trg_item_integrity AFTER INSERT OR UPDATE OR DELETE ON catalog.item_uom
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION catalog.item_integrity_trg();

-- ویژگی توصیفی: نوع مقدار با نوع ویژگی؛ محور variant همان کالا نباشد
CREATE OR REPLACE FUNCTION catalog.item_attribute_value_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_type text; i catalog.item;
BEGIN
  SELECT a.value_type INTO v_type FROM catalog.attribute a WHERE a.tenant_id = NEW.tenant_id AND a.id = NEW.attribute_id;
  IF (v_type = 'option'  AND NEW.value_id IS NULL) OR (v_type = 'text' AND NEW.value_text IS NULL)
  OR (v_type = 'number'  AND NEW.value_number IS NULL) OR (v_type = 'boolean' AND NEW.value_bool IS NULL) THEN
    RAISE EXCEPTION 'HK_CATALOG_ATTRIBUTE_VALUE_TYPE: value does not match attribute type %', v_type USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO i FROM catalog.item x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.item_id;
  IF NEW.attribute_id IN (i.variant_axis1_id, i.variant_axis2_id, i.variant_axis3_id) THEN
    RAISE EXCEPTION 'HK_CATALOG_ATTRIBUTE_IS_AXIS: attribute is a variant axis of this item' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_item_attribute_value_guard ON catalog.item_attribute_value;
CREATE TRIGGER trg_item_attribute_value_guard BEFORE INSERT OR UPDATE ON catalog.item_attribute_value
  FOR EACH ROW EXECUTE FUNCTION catalog.item_attribute_value_guard();

-- بارکد: تداخل با پیشوند الگوی ترازوی فعال ممنوع؛ هویت تغییرناپذیر
CREATE OR REPLACE FUNCTION catalog.barcode_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.code <> OLD.code OR NEW.item_id <> OLD.item_id OR NEW.variant_id <> OLD.variant_id
                           OR NEW.uom_id <> OLD.uom_id OR NEW.symbology <> OLD.symbology OR NEW.source <> OLD.source) THEN
    RAISE EXCEPTION 'HK_CATALOG_BARCODE_IMMUTABLE: delete and re-add the barcode instead' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.code ~ '^[0-9]{13}$' AND EXISTS (
       SELECT 1 FROM catalog.scale_barcode_pattern s
        WHERE s.tenant_id = NEW.tenant_id AND s.is_active AND left(NEW.code, 2) = s.prefix) THEN
    RAISE EXCEPTION 'HK_CATALOG_BARCODE_SCALE_PREFIX: % collides with an active scale barcode prefix', NEW.code USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_barcode_guard ON catalog.barcode;
CREATE TRIGGER trg_barcode_guard BEFORE INSERT OR UPDATE ON catalog.barcode
  FOR EACH ROW EXECUTE FUNCTION catalog.barcode_guard();

CREATE OR REPLACE FUNCTION catalog.scale_pattern_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  IF NEW.is_active THEN
    SELECT count(*) INTO v_n FROM catalog.barcode b
     WHERE b.tenant_id = NEW.tenant_id AND b.code ~ '^[0-9]{13}$' AND left(b.code, 2) = NEW.prefix;
    IF v_n > 0 THEN
      RAISE EXCEPTION 'HK_CATALOG_SCALE_PREFIX_CONFLICT: % existing barcode(s) start with prefix %', v_n, NEW.prefix USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF NEW.weight_uom_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM catalog.uom u WHERE u.tenant_id = NEW.tenant_id AND u.id = NEW.weight_uom_id AND u.dimension = 'mass') THEN
    RAISE EXCEPTION 'HK_CATALOG_SCALE_WEIGHT_UOM: weight unit must be a mass unit' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_scale_pattern_guard ON catalog.scale_barcode_pattern;
CREATE TRIGGER trg_scale_pattern_guard BEFORE INSERT OR UPDATE ON catalog.scale_barcode_pattern
  FOR EACH ROW EXECUTE FUNCTION catalog.scale_pattern_guard();

-- فهرست قیمت: پایه هم‌نوع و هم‌ارز؛ بدون چرخه؛ عمق ≤ ۳
CREATE OR REPLACE FUNCTION catalog.price_list_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE b catalog.price_list; v_cur uuid := NEW.base_price_list_id; v_depth int := 0;
BEGIN
  IF NEW.base_price_list_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO b FROM catalog.price_list x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.base_price_list_id;
  IF b.kind <> NEW.kind OR b.currency <> NEW.currency THEN
    RAISE EXCEPTION 'HK_CATALOG_PRICE_LIST_BASE_MISMATCH: base list must have the same kind and currency' USING ERRCODE = 'P0001';
  END IF;
  WHILE v_cur IS NOT NULL LOOP
    IF v_cur = NEW.id THEN
      RAISE EXCEPTION 'HK_CATALOG_PRICE_LIST_CYCLE: derived price lists form a cycle' USING ERRCODE = 'P0001';
    END IF;
    v_depth := v_depth + 1;
    IF v_depth > 3 THEN
      RAISE EXCEPTION 'HK_CATALOG_PRICE_LIST_TOO_DEEP: derivation depth exceeds 3' USING ERRCODE = 'P0001';
    END IF;
    SELECT x.base_price_list_id INTO v_cur FROM catalog.price_list x WHERE x.tenant_id = NEW.tenant_id AND x.id = v_cur;
  END LOOP;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_price_list_guard ON catalog.price_list;
CREATE TRIGGER trg_price_list_guard BEFORE INSERT OR UPDATE ON catalog.price_list
  FOR EACH ROW EXECUTE FUNCTION catalog.price_list_guard();

-- سطر قیمت: دقت مبلغ؛ اثر روی روزهای گذشته تغییرناپذیر (جز با پرچم پس‌تاریخ در UoW مهاجرت)
CREATE OR REPLACE FUNCTION catalog.price_list_item_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_prec smallint; v_today date; v_backdate boolean := coalesce(current_setting('hk.catalog_allow_backdate', true), '') = 'on';
        r record;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  v_today := catalog.tenant_today(r.tenant_id);
  IF TG_OP = 'DELETE' THEN
    IF OLD.valid_from < v_today AND NOT v_backdate THEN
      RAISE EXCEPTION 'HK_CATALOG_PRICE_PAST_IMMUTABLE: an entry already effective cannot be deleted (close it instead)' USING ERRCODE = 'P0001';
    END IF;
    RETURN OLD;
  END IF;
  SELECT l.price_precision INTO v_prec FROM catalog.price_list l WHERE l.tenant_id = NEW.tenant_id AND l.id = NEW.price_list_id;
  IF NEW.price <> round(NEW.price, v_prec) THEN
    RAISE EXCEPTION 'HK_CATALOG_PRICE_PRECISION: price % exceeds list precision %', NEW.price, v_prec USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.valid_from < v_today AND NOT v_backdate THEN
      RAISE EXCEPTION 'HK_CATALOG_PRICE_BACKDATED: valid_from % is before today %', NEW.valid_from, v_today USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE
  IF NEW.price_list_id <> OLD.price_list_id OR NEW.item_id <> OLD.item_id OR NEW.variant_id IS DISTINCT FROM OLD.variant_id
     OR NEW.uom_id <> OLD.uom_id OR NEW.min_qty <> OLD.min_qty THEN
    RAISE EXCEPTION 'HK_CATALOG_PRICE_IDENTITY_IMMUTABLE: add a new entry instead' USING ERRCODE = 'P0001';
  END IF;
  IF v_backdate OR OLD.valid_from >= v_today THEN
    IF NEW.valid_from < v_today AND NOT v_backdate THEN
      RAISE EXCEPTION 'HK_CATALOG_PRICE_BACKDATED: valid_from % is before today %', NEW.valid_from, v_today USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.valid_to IS NOT NULL AND OLD.valid_to < v_today - 1 THEN
    RAISE EXCEPTION 'HK_CATALOG_PRICE_PAST_IMMUTABLE: entry ended in the past' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.price <> OLD.price OR NEW.valid_from <> OLD.valid_from
     OR (NEW.valid_to IS DISTINCT FROM OLD.valid_to AND NEW.valid_to IS NOT NULL AND NEW.valid_to < v_today - 1) THEN
    RAISE EXCEPTION 'HK_CATALOG_PRICE_PAST_IMMUTABLE: only valid_to (>= yesterday) may change on an effective entry' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_price_list_item_guard ON catalog.price_list_item;
CREATE TRIGGER trg_price_list_item_guard BEFORE INSERT OR UPDATE OR DELETE ON catalog.price_list_item
  FOR EACH ROW EXECUTE FUNCTION catalog.price_list_item_guard();

-- انتساب فهرست قیمت: گروه شخص با نوع فهرست سازگار؛ شخص ادغام‌شده ممنوع
CREATE OR REPLACE FUNCTION catalog.price_list_assignment_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_kind text; v_role text;
BEGIN
  SELECT l.kind INTO v_kind FROM catalog.price_list l WHERE l.tenant_id = NEW.tenant_id AND l.id = NEW.price_list_id;
  IF NEW.party_group_id IS NOT NULL THEN
    SELECT g.role INTO v_role FROM parties.party_group g WHERE g.tenant_id = NEW.tenant_id AND g.id = NEW.party_group_id;
    IF (v_kind = 'sales' AND v_role <> 'customer') OR (v_kind = 'purchase' AND v_role <> 'supplier') THEN
      RAISE EXCEPTION 'HK_CATALOG_ASSIGNMENT_GROUP_ROLE: % list cannot be assigned to a % group', v_kind, v_role USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF NEW.party_id IS NOT NULL AND EXISTS (SELECT 1 FROM parties.party p WHERE p.tenant_id = NEW.tenant_id
                                            AND p.id = NEW.party_id AND p.status = 'merged') THEN
    RAISE EXCEPTION 'HK_PARTY_MERGED: party % is merged', NEW.party_id USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_price_list_assignment_guard ON catalog.price_list_assignment;
CREATE TRIGGER trg_price_list_assignment_guard BEFORE INSERT OR UPDATE ON catalog.price_list_assignment
  FOR EACH ROW EXECUTE FUNCTION catalog.price_list_assignment_guard();

CREATE OR REPLACE FUNCTION catalog.item_supplier_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM parties.party p WHERE p.tenant_id = NEW.tenant_id AND p.id = NEW.supplier_party_id AND p.status = 'merged') THEN
    RAISE EXCEPTION 'HK_PARTY_MERGED: supplier % is merged', NEW.supplier_party_id USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_item_supplier_guard ON catalog.item_supplier;
CREATE TRIGGER trg_item_supplier_guard BEFORE INSERT OR UPDATE ON catalog.item_supplier
  FOR EACH ROW EXECUTE FUNCTION catalog.item_supplier_guard();

-- BOM: رسیدن مؤلفه به کالای والد از طریق BOMهای پیش‌نویس/فعال (تشخیص چرخه، سطح کالا)
CREATE OR REPLACE FUNCTION catalog.bom_reaches(p_tenant uuid, p_from_item uuid, p_target_item uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE walk(item_id, depth) AS (
    SELECT p_from_item, 0
    UNION
    SELECT l.component_item_id, w.depth + 1
      FROM walk w
      JOIN catalog.bom b ON b.tenant_id = p_tenant AND b.item_id = w.item_id AND b.status IN ('draft','active')
      JOIN catalog.bom_line l ON l.tenant_id = p_tenant AND l.bom_id = b.id
     WHERE w.depth < 25)
  SELECT EXISTS (SELECT 1 FROM walk WHERE item_id = p_target_item)
$$;

CREATE OR REPLACE FUNCTION catalog.bom_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE i catalog.item; v_lines int;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION 'HK_CATALOG_BOM_NOT_DRAFT: only draft BOMs can be deleted (archive instead)' USING ERRCODE = 'P0001';
    END IF;
    RETURN OLD;
  END IF;
  SELECT * INTO i FROM catalog.item x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.item_id;
  IF (NEW.kind IN ('kit','recipe') AND i.item_type = 'stock') OR (NEW.kind = 'production' AND i.item_type <> 'stock') THEN
    RAISE EXCEPTION 'HK_CATALOG_BOM_KIND: % BOM is not allowed for a % item', NEW.kind, i.item_type USING ERRCODE = 'P0001';
  END IF;
  IF NEW.variant_id IS NOT NULL AND NOT i.has_variants THEN
    RAISE EXCEPTION 'HK_CATALOG_BOM_VARIANT: simple items use an item-level BOM (variant_id NULL)' USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN
      RAISE EXCEPTION 'HK_CATALOG_BOM_NOT_DRAFT: BOMs are created as draft' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.item_id <> OLD.item_id OR NEW.variant_id IS DISTINCT FROM OLD.variant_id OR NEW.kind <> OLD.kind
     OR NEW.version_no <> OLD.version_no THEN
    RAISE EXCEPTION 'HK_CATALOG_BOM_IDENTITY_IMMUTABLE: item/variant/kind/version are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.status = 'draft' AND NEW.status = 'active' THEN
    SELECT count(*) INTO v_lines FROM catalog.bom_line l WHERE l.tenant_id = NEW.tenant_id AND l.bom_id = NEW.id;
    IF v_lines = 0 THEN
      RAISE EXCEPTION 'HK_CATALOG_BOM_EMPTY: a BOM needs at least one line to be activated' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.status = 'active' AND NEW.status = 'active' THEN
    IF (to_jsonb(NEW) - ARRAY['valid_to','updated_at','row_version']) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['valid_to','updated_at','row_version']) THEN
      RAISE EXCEPTION 'HK_CATALOG_BOM_ACTIVE_IMMUTABLE: an active BOM can only be closed (valid_to) or archived' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.status = 'active' AND NEW.status = 'archived' THEN
    IF (to_jsonb(NEW) - ARRAY['status','archived_at','valid_to','updated_at','row_version'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','archived_at','valid_to','updated_at','row_version']) THEN
      RAISE EXCEPTION 'HK_CATALOG_BOM_ACTIVE_IMMUTABLE: archiving changes nothing else' USING ERRCODE = 'P0001';
    END IF;
  ELSIF NOT (OLD.status = 'draft' AND NEW.status = 'draft') THEN
    RAISE EXCEPTION 'HK_CATALOG_BOM_TRANSITION: % -> % is not allowed', OLD.status, NEW.status USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_bom_guard ON catalog.bom;
CREATE TRIGGER trg_bom_guard BEFORE INSERT OR UPDATE OR DELETE ON catalog.bom
  FOR EACH ROW EXECUTE FUNCTION catalog.bom_guard();

CREATE OR REPLACE FUNCTION catalog.bom_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE b catalog.bom; r record; v_has_variants boolean;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  SELECT * INTO b FROM catalog.bom x WHERE x.tenant_id = r.tenant_id AND x.id = r.bom_id;
  IF NOT FOUND THEN RETURN r; END IF;              -- حذف آبشاری BOM پیش‌نویس
  IF b.status <> 'draft' THEN
    RAISE EXCEPTION 'HK_CATALOG_BOM_NOT_DRAFT: lines of a % BOM are immutable (create a new version)', b.status USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF NEW.bom_id <> coalesce(OLD.bom_id, NEW.bom_id) THEN
    RAISE EXCEPTION 'HK_CATALOG_BOM_IDENTITY_IMMUTABLE: a line cannot move between BOMs' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.component_item_id = b.item_id OR catalog.bom_reaches(NEW.tenant_id, NEW.component_item_id, b.item_id) THEN
    RAISE EXCEPTION 'HK_CATALOG_BOM_CYCLE: component would contain its own parent' USING ERRCODE = 'P0001';
  END IF;
  SELECT i.has_variants INTO v_has_variants FROM catalog.item i WHERE i.tenant_id = NEW.tenant_id AND i.id = NEW.component_item_id;
  IF v_has_variants AND NEW.component_variant_id IS NULL THEN
    RAISE EXCEPTION 'HK_CATALOG_BOM_COMPONENT_VARIANT: a component with variants needs component_variant_id' USING ERRCODE = 'P0001';
  END IF;
  IF NOT v_has_variants AND NEW.component_variant_id IS NOT NULL THEN
    RAISE EXCEPTION 'HK_CATALOG_BOM_COMPONENT_VARIANT: simple components are referenced by item only' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_bom_line_guard ON catalog.bom_line;
CREATE TRIGGER trg_bom_line_guard BEFORE INSERT OR UPDATE OR DELETE ON catalog.bom_line
  FOR EACH ROW EXECUTE FUNCTION catalog.bom_line_guard();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['uom','item_posting_group','attribute','attribute_value','attribute_set','brand','item_category',
                           'item','item_variant','item_uom','scale_barcode_pattern','price_list','price_list_item',
                           'price_list_assignment','item_supplier','bom','code_series'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_touch ON catalog.%I', t);
    EXECUTE format('CREATE TRIGGER trg_touch BEFORE UPDATE ON catalog.%I FOR EACH ROW EXECUTE FUNCTION core.touch_row()', t);
  END LOOP;
END $$;

-- =====================================================================
-- ۱۰. catalog — توابع و ویوها
-- =====================================================================
-- تخصیص بارکد داخلی RCN-13 با پیشوند GS1 «04» + ۱۰ رقم + رقم کنترل (شمارندهٔ قفل‌دار هر مستأجر)
CREATE OR REPLACE FUNCTION catalog.allocate_internal_barcode() RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_tenant uuid := core.current_tenant_id(); v_next bigint; v_body text; v_code text;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'HK_TENANT_CONTEXT_MISSING: app.tenant_id is not set' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO catalog.barcode_counter (tenant_id, prefix) VALUES (v_tenant, '04') ON CONFLICT (tenant_id, prefix) DO NOTHING;
  SELECT c.next_value INTO v_next FROM catalog.barcode_counter c WHERE c.tenant_id = v_tenant AND c.prefix = '04' FOR UPDATE;
  LOOP
    IF v_next > 9999999999 THEN
      RAISE EXCEPTION 'HK_CATALOG_BARCODE_SPACE_EXHAUSTED: internal barcode space is exhausted' USING ERRCODE = 'P0001';
    END IF;
    v_body := '04' || lpad(v_next::text, 10, '0');
    v_code := v_body || ref.gtin_check_digit(v_body)::text;
    v_next := v_next + 1;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM catalog.barcode b WHERE b.tenant_id = v_tenant AND b.code = v_code);
  END LOOP;
  UPDATE catalog.barcode_counter SET next_value = v_next WHERE tenant_id = v_tenant AND prefix = '04';
  RETURN v_code;
END $$;

-- تجزیهٔ بارکد ترازو
CREATE OR REPLACE FUNCTION catalog.parse_scale_barcode(p_code text)
RETURNS TABLE (pattern_id uuid, plu_code text, variant_id uuid, item_id uuid, value_kind text, value numeric,
               weight_uom_id uuid, price_currency char(3), price_amount_unit core.amount_unit)
LANGUAGE plpgsql STABLE AS $$
DECLARE c text := p_code; p catalog.scale_barcode_pattern; v_plu text;
BEGIN
  IF c ~ '^[0-9]{12}$' THEN c := '0' || c; END IF;          -- UPC-A ← EAN-13
  IF c IS NULL OR c !~ '^[0-9]{13}$' OR NOT ref.is_valid_gtin(c) THEN RETURN; END IF;
  SELECT * INTO p FROM catalog.scale_barcode_pattern s WHERE s.is_active AND s.prefix = left(c, 2);
  IF NOT FOUND THEN RETURN; END IF;
  pattern_id := p.id;
  v_plu := nullif(ltrim(substr(c, p.plu_start, p.plu_length), '0'), '');
  plu_code := v_plu;
  value_kind := p.value_kind;
  value := substr(c, p.value_start, p.value_length)::numeric / (10::numeric ^ p.value_decimals);
  weight_uom_id := p.weight_uom_id;
  price_currency := p.price_currency;
  price_amount_unit := p.price_amount_unit;
  SELECT v.id, v.item_id INTO variant_id, item_id FROM catalog.item_variant v WHERE v.plu_code = v_plu;
  RETURN NEXT;
END $$;

-- تبدیل مقدار بین دو واحد یک کالا (گرد به مقیاس core.qty)
CREATE OR REPLACE FUNCTION catalog.convert_qty(p_item_id uuid, p_qty numeric, p_from_uom uuid, p_to_uom uuid) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT round(p_qty * f.factor / t.factor, 6)
    FROM catalog.item_uom f, catalog.item_uom t
   WHERE f.item_id = p_item_id AND f.uom_id = p_from_uom AND t.item_id = p_item_id AND t.uom_id = p_to_uom
$$;

-- قیمت‌یابی از یک فهرست (بدون تخفیف؛ موتور تخفیف در بخش فروش). ترجیح: واحد دقیق > واحد پایه × ضریب؛
-- سپس variant مشخص > سطح کالا؛ سپس بزرگ‌ترین شکست مقداری ≤ مقدار (مقایسه به واحد پایه).
-- اگر فهرست سطری نداشت و مشتق است، از فهرست پایه با درصد و گرد کردن (از درون به بیرون).
CREATE OR REPLACE FUNCTION catalog.resolve_price(p_price_list_id uuid, p_variant_id uuid, p_uom_id uuid, p_qty numeric, p_on date)
RETURNS TABLE (price numeric, source_price_list_id uuid, entry_id uuid, via text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_item uuid; v_req_factor numeric; v_list catalog.price_list; v_list_id uuid := p_price_list_id;
  v_chain catalog.price_list[] := ARRAY[]::catalog.price_list[]; v_depth int := 0;
  e record; v_price numeric; k int;
BEGIN
  SELECT v.item_id INTO v_item FROM catalog.item_variant v WHERE v.id = p_variant_id;
  SELECT u.factor INTO v_req_factor FROM catalog.item_uom u WHERE u.item_id = v_item AND u.uom_id = p_uom_id AND u.is_active;
  IF v_item IS NULL OR v_req_factor IS NULL OR p_qty IS NULL OR p_qty < 0 THEN RETURN; END IF;
  LOOP
    SELECT * INTO v_list FROM catalog.price_list l WHERE l.id = v_list_id;
    EXIT WHEN NOT FOUND;
    -- اعتبار و فعال بودن فقط برای فهرست درخواستی؛ فهرست پایه فقط منبع داده است
    IF v_depth = 0 AND (NOT v_list.is_active OR (v_list.valid_from IS NOT NULL AND p_on < v_list.valid_from)
                        OR (v_list.valid_to IS NOT NULL AND p_on > v_list.valid_to)) THEN
      RETURN;
    END IF;
    SELECT x.id, x.price, x.uom_id INTO e
      FROM catalog.price_list_item x
      JOIN catalog.item_uom u ON u.tenant_id = x.tenant_id AND u.item_id = x.item_id AND u.uom_id = x.uom_id
     WHERE x.price_list_id = v_list.id AND x.item_id = v_item
       AND (x.variant_id = p_variant_id OR x.variant_id IS NULL)
       AND x.valid_from <= p_on AND (x.valid_to IS NULL OR x.valid_to >= p_on)
       AND (x.uom_id = p_uom_id OR u.is_base)
       AND x.min_qty * u.factor <= p_qty * v_req_factor
     ORDER BY (x.uom_id = p_uom_id) DESC, (x.variant_id IS NOT NULL) DESC, x.min_qty * u.factor DESC
     LIMIT 1;
    IF FOUND THEN
      v_price := CASE WHEN e.uom_id = p_uom_id THEN e.price ELSE round(e.price * v_req_factor, v_list.price_precision) END;
      -- اعمال قواعد فهرست‌های مشتق از درونی‌ترین به بیرونی‌ترین
      FOR k IN REVERSE coalesce(array_length(v_chain, 1), 0) .. 1 LOOP
        v_price := v_price * (1 + v_chain[k].base_adjust_percent / 100);
        IF v_chain[k].rounding_increment IS NOT NULL THEN
          v_price := v_chain[k].rounding_increment * CASE v_chain[k].rounding_mode
                       WHEN 'up'   THEN ceil(v_price / v_chain[k].rounding_increment)
                       WHEN 'down' THEN floor(v_price / v_chain[k].rounding_increment)
                       ELSE round(v_price / v_chain[k].rounding_increment) END;
        END IF;
        v_price := round(v_price, v_chain[k].price_precision);
      END LOOP;
      price := v_price; source_price_list_id := v_list.id; entry_id := e.id;
      via := CASE WHEN array_length(v_chain, 1) > 0 THEN 'derived' WHEN e.uom_id <> p_uom_id THEN 'base_uom' ELSE 'direct' END;
      RETURN NEXT; RETURN;
    END IF;
    EXIT WHEN v_list.base_price_list_id IS NULL;
    v_chain := v_chain || v_list;
    v_list_id := v_list.base_price_list_id;
    v_depth := v_depth + 1;
    EXIT WHEN v_depth > 3;
  END LOOP;
  RETURN;
END $$;

-- دستهٔ مؤثر: مسیر درخت و پیش‌فرض‌های ارث‌برده از نزدیک‌ترین نیا (گروه ثبت، دستهٔ مالیاتی، واحد، قالب ویژگی).
-- فقط posting_group در زمان اجرا ارث برده می‌شود؛ بقیه پیش‌پرکردن فرم کالای تازه‌اند (سرویس).
CREATE OR REPLACE VIEW catalog.v_category_effective WITH (security_invoker = true) AS
  WITH RECURSIVE t AS (
    SELECT c.tenant_id, c.id, c.parent_id, c.code, 1 AS depth, ARRAY[c.id] AS path_ids, c.code AS path_codes, c.name AS path_names,
           c.default_posting_group_id AS posting_group_id, c.default_tax_category_code AS tax_category_code,
           c.default_uom_id AS uom_id, c.default_attribute_set_id AS attribute_set_id
      FROM catalog.item_category c WHERE c.parent_id IS NULL
    UNION ALL
    SELECT c.tenant_id, c.id, c.parent_id, c.code, t.depth + 1, t.path_ids || c.id, t.path_codes || '/' || c.code,
           t.path_names || ' / ' || c.name,
           coalesce(c.default_posting_group_id, t.posting_group_id), coalesce(c.default_tax_category_code, t.tax_category_code),
           coalesce(c.default_uom_id, t.uom_id), coalesce(c.default_attribute_set_id, t.attribute_set_id)
      FROM catalog.item_category c JOIN t ON t.tenant_id = c.tenant_id AND t.id = c.parent_id
     WHERE t.depth < 10)
  SELECT tenant_id, id AS category_id, parent_id, code, depth, path_ids, path_codes, path_names,
         posting_group_id AS effective_posting_group_id, tax_category_code AS effective_tax_category_code,
         uom_id AS effective_uom_id, attribute_set_id AS effective_attribute_set_id
    FROM t;

CREATE OR REPLACE VIEW catalog.v_sku WITH (security_invoker = true) AS
  SELECT v.tenant_id, v.id AS variant_id, v.item_id, v.code AS sku_code, i.code AS item_code,
         CASE WHEN v.name_suffix IS NULL THEN i.name ELSE i.name || ' — ' || v.name_suffix END AS display_name,
         i.item_type, i.base_uom_id, i.category_id, i.brand_id,
         coalesce(i.posting_group_id, c.effective_posting_group_id) AS posting_group_id,
         i.track_serial, i.track_batch, i.track_expiry,
         coalesce(v.sstid, i.sstid) AS sstid, CASE WHEN v.sstid IS NOT NULL THEN v.sstid_kind ELSE i.sstid_kind END AS sstid_kind,
         i.tax_category_code, i.other_tax_category_code,
         i.is_sellable, i.is_purchasable, i.allow_discount, i.allow_price_override,
         (i.status = 'active' AND v.status = 'active') AS is_active,
         v.is_default, v.axis1_value_id, v.axis2_value_id, v.axis3_value_id, v.plu_code, i.company_id
    FROM catalog.item_variant v
    JOIN catalog.item i ON i.tenant_id = v.tenant_id AND i.id = v.item_id
    LEFT JOIN catalog.v_category_effective c ON c.tenant_id = i.tenant_id AND c.category_id = i.category_id;

-- ویژگی‌های شرط قاعدهٔ نگاشت حساب برای یک SKU: item_posting_group (مؤثر)، item_type و item_category (کد دستهٔ مستقیم).
CREATE OR REPLACE FUNCTION catalog.posting_attributes(p_variant_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
           'item_posting_group', g.code,
           'item_type', s.item_type,
           'item_category', c.code))
    FROM catalog.v_sku s
    LEFT JOIN catalog.item_posting_group g ON g.tenant_id = s.tenant_id AND g.id = s.posting_group_id
    LEFT JOIN catalog.item_category c ON c.tenant_id = s.tenant_id AND c.id = s.category_id
   WHERE s.variant_id = p_variant_id
$$;

-- تخصیص کد کالا: سری نزدیک‌ترین نیای دارای سری فعال، وگرنه سری پیش‌فرض (ساخته می‌شود). کد باید در کالا و SKU آزاد باشد.
CREATE OR REPLACE FUNCTION catalog.next_item_code(p_category_id uuid DEFAULT NULL) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_tenant uuid := core.current_tenant_id(); s catalog.code_series; v_path uuid[]; v_next bigint; v_code text;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'HK_TENANT_CONTEXT_MISSING: app.tenant_id is not set' USING ERRCODE = 'P0001';
  END IF;
  IF p_category_id IS NOT NULL THEN
    SELECT e.path_ids INTO v_path FROM catalog.v_category_effective e WHERE e.tenant_id = v_tenant AND e.category_id = p_category_id;
    IF v_path IS NULL THEN
      RAISE EXCEPTION 'HK_CATALOG_CATEGORY_NOT_FOUND: %', p_category_id USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO s FROM catalog.code_series c
     WHERE c.tenant_id = v_tenant AND c.is_active AND c.category_id = ANY (v_path)
     ORDER BY array_position(v_path, c.category_id) DESC
     LIMIT 1
     FOR UPDATE;
  END IF;
  IF s.id IS NULL THEN
    INSERT INTO catalog.code_series (tenant_id, category_id) VALUES (v_tenant, NULL) ON CONFLICT DO NOTHING;
    SELECT * INTO s FROM catalog.code_series c WHERE c.tenant_id = v_tenant AND c.category_id IS NULL FOR UPDATE;
    IF NOT s.is_active THEN
      RAISE EXCEPTION 'HK_CATALOG_CODE_SERIES_INACTIVE: no active code series' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  v_next := s.next_value;
  LOOP
    v_code := s.prefix || CASE WHEN length(v_next::text) >= s.pad_width THEN v_next::text ELSE lpad(v_next::text, s.pad_width, '0') END;
    IF char_length(v_code) > 40 OR v_next > 999999999999 THEN
      RAISE EXCEPTION 'HK_CATALOG_CODE_SERIES_EXHAUSTED: series % is exhausted', s.id USING ERRCODE = 'P0001';
    END IF;
    v_next := v_next + 1;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM catalog.item x WHERE x.tenant_id = v_tenant AND x.code = v_code)
          AND NOT EXISTS (SELECT 1 FROM catalog.item_variant x WHERE x.tenant_id = v_tenant AND x.code = v_code);
  END LOOP;
  UPDATE catalog.code_series SET next_value = v_next WHERE tenant_id = v_tenant AND id = s.id;
  RETURN v_code;
END $$;

CREATE OR REPLACE VIEW catalog.v_item_uom_effective WITH (security_invoker = true) AS
  SELECT iu.tenant_id, iu.item_id, iu.uom_id, iu.factor, iu.is_base, iu.allow_sales, iu.allow_purchase,
         iu.is_sales_default, iu.is_purchase_default, iu.is_active, u.code AS uom_code, u.name AS uom_name, u.qty_decimals,
         coalesce(iu.moadian_unit_code, u.moadian_unit_code) AS moadian_unit_code
    FROM catalog.item_uom iu
    JOIN catalog.uom u ON u.tenant_id = iu.tenant_id AND u.id = iu.uom_id;

CREATE OR REPLACE VIEW catalog.v_barcode_lookup WITH (security_invoker = true) AS
  SELECT b.tenant_id, b.code, b.variant_id, b.item_id, b.uom_id, iu.factor, b.symbology, b.source,
         (i.status = 'active' AND v.status = 'active' AND iu.is_active) AS is_active
    FROM catalog.barcode b
    JOIN catalog.item_variant v ON v.tenant_id = b.tenant_id AND v.id = b.variant_id
    JOIN catalog.item i ON i.tenant_id = b.tenant_id AND i.id = b.item_id
    JOIN catalog.item_uom iu ON iu.tenant_id = b.tenant_id AND iu.item_id = b.item_id AND iu.uom_id = b.uom_id;

-- =====================================================================
-- ۱۱. دسترسی
-- =====================================================================
GRANT SELECT ON ref.country, ref.province, ref.city, ref.bank, ref.bank_sheba_code, ref.bank_card_bin,
                ref.moadian_unit, ref.sstid TO hk_app, hk_readonly;

GRANT SELECT, INSERT, UPDATE, DELETE ON
  parties.party_group, parties.payment_term, parties.payment_term_line, parties.party, parties.party_role,
  parties.party_contact, parties.party_address, parties.party_bank_account, parties.party_relation,
  parties.party_legacy_code TO hk_app;
GRANT SELECT, INSERT, UPDATE ON parties.party_hold TO hk_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON parties.code_series TO hk_app;
GRANT SELECT, INSERT, DELETE ON parties.duplicate_dismissal TO hk_app;
GRANT SELECT, INSERT ON parties.party_merge, parties.party_taxpayer_inquiry TO hk_app;
GRANT SELECT ON ALL TABLES IN SCHEMA parties TO hk_readonly;

GRANT SELECT, INSERT, UPDATE, DELETE ON
  catalog.uom, catalog.item_posting_group, catalog.attribute, catalog.attribute_value, catalog.attribute_set,
  catalog.attribute_set_member, catalog.brand, catalog.item_category, catalog.item, catalog.item_variant,
  catalog.item_uom, catalog.item_attribute_value, catalog.barcode, catalog.scale_barcode_pattern, catalog.price_list,
  catalog.price_list_item, catalog.price_list_assignment, catalog.item_supplier, catalog.item_image,
  catalog.item_legacy_code, catalog.bom, catalog.bom_line TO hk_app;
GRANT SELECT, INSERT, UPDATE ON catalog.barcode_counter TO hk_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON catalog.code_series TO hk_app;
GRANT SELECT ON parties.v_party_canonical, parties.v_party_ledger_identity, parties.v_party_hold_state,
                parties.v_party_moadian_profile, catalog.v_category_effective, catalog.v_sku,
                catalog.v_item_uom_effective, catalog.v_barcode_lookup TO hk_app;
GRANT SELECT ON ALL TABLES IN SCHEMA catalog TO hk_readonly;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ref, parties, catalog TO hk_app, hk_readonly;
