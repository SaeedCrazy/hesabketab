# درخواست‌های تغییر و تصمیم‌های یکپارچه‌سازی

> مالک: یکپارچه‌ساز (بخش ۱ از ۲). ورودی: همهٔ درخواست‌ها و تعارض‌های §۱۳ ده سند طراحی (حدود ۱۷۰ مورد).
> فایل‌های مالک یکپارچه‌ساز: `sql/00_foundation.sql`، `sql/dev_roles.sql`، `sql/99_cross_fk.sql`، `sql/run_all.sh` و همین سند.
> هر یافتهٔ بازبینی با شناسهٔ `RV-IT-*` در پاسخ ساخت‌یافتهٔ یکپارچه‌ساز آمده است و این‌جا فقط به آن ارجاع می‌شود.

**راهنمای ستون‌ها**

- **تصمیم:** پذیرفته، رد، یا به تعویق.
- **وضعیت:**
  - «انجام‌شده»: در فایل‌ها اعمال و با `run_all.sh` آزموده شده است.
  - «باز»: پذیرفته شده و مسئول اجرا باید آن را انجام دهد.
  - «پرسش صاحب محصول»: تصمیم محصولی است و در فهرست پرسش‌های صاحب محصول آمده است.
- **شناسه:** شمارهٔ سند مبدأ و شناسهٔ همان سند، مثلاً `01:C-02` یا `02:۱۳.۸`. بند‌های بی‌شناسهٔ سند ۰۲ با شمارهٔ بندشان در §۱۳ آمده‌اند.

---

## قواعد یکپارچه‌سازی

این قاعده‌ها بر متن هر سند مقدم‌اند. هر جا سندی با آن‌ها نمی‌خواند، همان سند باید اصلاح شود.

### R-DB — ساخت پایگاه داده
- پایگاه دادهٔ صفحهٔ داده و صفحهٔ کنترل همیشه با این دستور ساخته می‌شود:
  `CREATE DATABASE <name> ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8'`
- `00_foundation.sql` در آغاز این‌ها را assert می‌کند:
  - `HK_ENCODING`: پایگاه UTF8 است.
  - `HK_PG_VERSION`: نسخه PostgreSQL 18 یا بالاتر است.
  - `HK_WRONG_DATABASE`: فایل روی پایگاه کنترل اجرا نمی‌شود.
- assertهای `HK_ENCODING` در فایل‌های ماژول تکرار بی‌خطرند و می‌مانند.

### R-ROLE — مدل نقش‌ها
همهٔ نقش‌های صفحهٔ داده فقط در `00_foundation.sql` ساخته می‌شوند: `NOLOGIN`، بدون رمز، و با سخت‌سازی idempotent ویژگی‌ها.

| نقش | ویژگی | کاربرد |
|---|---|---|
| `hk_migrator` | `BYPASSRLS`؛ مالک اسکیماها و اشیای پایه؛ `GRANT SET ON PARAMETER session_replication_role` | `hk migrate`، `hkctl`، نگهداری، پاک‌سازی و درون‌ریزی |
| `hk_app` | `NOBYPASSRLS`؛ مالک هیچ شیئی نیست؛ `statement_timeout=30s`، `idle_in_transaction_session_timeout=15s` | زمان اجرا. jobهای طولانی با `SET LOCAL statement_timeout` مهلت خود را بالا می‌برند |
| `hk_readonly` | `NOBYPASSRLS`؛ فقط `SELECT` صریح؛ روی جدول‌های دارای راز فقط GRANT ستونی | پشتیبانی و ابزار گزارش |
| `hk_reports` | عضو `hk_readonly` (`INHERIT TRUE, SET FALSE`)؛ `statement_timeout=300s` | replica گزارش. GRANT جدایی ندارد |
| `hk_dispatcher` | `NOBYPASSRLS`؛ policy مختص روی جدول‌های صف | برداشتن job و outbox |
| `hk_audit_writer`، `hk_core_definer`، `hk_ledger_definer`، `hk_inventory_definer` | همیشه `NOLOGIN NOBYPASSRLS` | مالک توابع `SECURITY DEFINER` فهرست مجاز D-32 |

- **فعال‌سازی ورود:**
  - استقرار: ابزار استقرار `ALTER ROLE … LOGIN PASSWORD` را با رمز `SecretStore` اجرا می‌کند.
  - توسعه و آزمون محلی: `psql -v hk_dev_ok=1 -f sql/dev_roles.sql`. بدون این متغیر، اسکریپت با `HK_DEV_ROLES_REFUSED` متوقف می‌شود.
- **محدودیت فایل‌های ماژول:** هیچ فایل ماژولی نقش نمی‌سازد و رمز نمی‌نویسد. بلوک‌های شرطی موجود در 10، 20 و 30 بی‌اثرند، چون پایه زودتر نقش را ساخته است، ولی باید حذف شوند (RV-IT-15).
- **صفحهٔ کنترل:** `70_platform.sql` همین الگو را با نقش‌های `hk_platform_*` رعایت کند (RV-IT-14). `dev_roles.sql` آن نقش‌ها را هم پوشش می‌دهد.

### R-EXT — افزونه‌ها
- `btree_gist` و `pg_trgm` فقط در پایه ساخته می‌شوند، در اسکیمای `public`.
- اسکیمای جدای `ext` رد شد:
  - نام opclassها (`gin_trgm_ops`) و عملگرها (`%`) در فایل‌ها بی‌پیشوندند و با `search_path` پیدا می‌شوند.
  - با اسکیمای جدا، این ارجاع‌ها می‌شکنند.
- `CREATE EXTENSION IF NOT EXISTS` در فایل‌های ماژول بی‌اثر است و حذفش اختیاری است.

### R-REF — دادهٔ مرجع
- **دامنهٔ `ref`:** فقط دادهٔ مرجع بیرونی (ارز، تقسیمات، بانک، واحد و شناسهٔ کالای مؤدیان).
- **کاتالوگ‌های کدمحور:** مثل `core.permission`، `core.setting_def`، `ledger.posting_key` و `ledger.dimension_type_catalog`. هر کدام در اسکیمای ماژول مالک، بدون `tenant_id` و با migration.
- **مالکیت جدول‌های `ref`:**
  - پایه: `ref.currency`.
  - بخش ۰۴: `country`، `province`، `city`، `bank`، `bank_sheba_code`، `bank_card_bin`، `moadian_unit`، `sstid` و توابع `ref.is_valid_*` و `ref.gtin_check_digit` و `ref.sheba_bank_code`.
  - بخش ۰۶: `sayad_credit_status`، `psp`.
  - بخش ۰۷: `sstid_vat_rate`، `ssi_job_code`.
  - هیچ بخشی جدول `ref` بخش دیگر را دوباره تعریف نمی‌کند.
- **نوشتن در `ref`:**
  - فقط `hk_migrator`، از راه migration داده یا بستهٔ امضاشدهٔ `reference_snapshot`.
  - `hk_app` هیچ GRANT نوشتنی روی `ref` ندارد. روی پایگاه یکپارچه بررسی شد: صفر.
  - `SELECT` پیش‌فرض با `ALTER DEFAULT PRIVILEGES` (فقط اسکیمای `ref`).
- **یک‌جاسازی:** انتقال همهٔ جدول‌های `ref` به یک فایل `05_ref.sql` به تعویق افتاد (پس از انجماد v1).

### R-GRANT — دسترسی
- هر فایل پس از ساخت جدول‌هایش GRANT صریح می‌دهد. برای اسکیماهای ماژول هیچ «پیش‌فرض» (default privilege) نیست.
- قسمت «SELECT پیش‌فرض برای اسکیماهای تجاری» در 01:C-04 رد شد، چون با 02:۱۳.۶ تعارض دارد.
- جدولی که ستون راز دارد (`export_table_registry.secret_columns`) به `hk_readonly` فقط GRANT ستونی می‌دهد.
- `core.tenant`:
  - `hk_app`: `SELECT`، `INSERT` و `UPDATE (display_name, locale, timezone)`.
  - `status`، `slug` و `deployment` را فقط `hk_migrator`، از راه فرمان پنل مالک، تغییر می‌دهد.

### R-ORDER — ترتیب فایل‌ها
- **ترتیب رسمی صفحهٔ داده:** `00 → 10 → 20 → 25 → 30 → 40 → 50 → 60 → 80 → 99`.
- **استقلال 20 و 25:** نسبت به هم مستقل‌اند. ترتیب `00 → 10 → 25 → 20 → … → 99` هم در هارنس سبز است.
- **پیش‌نیازها:**
  - 30، 40 و 50 به 10، 20 و 25 نیاز دارند (`HK_PREREQ`).
  - 60 و 80 به 10 نیاز دارند.
  - 99 همیشه آخر و پیش از هر داده است.
- **از این پس 10 پیش‌نیاز همهٔ فایل‌های داده است.**
  - بخش‌های ۰۳ و ۰۴ زنجیرهٔ مستقل خود را به `00 → 10 → X` تغییر دهند.
  - shim `core.fa_*` در 25 حذف شود (04:CR-03).
  - FKهای آن دو بخش به `core` به فایل خودشان برود. `99_cross_fk.sql` FK هم‌ارز را با هر نامی تشخیص می‌دهد و تکرار نمی‌کند.
  - هارنس پس از این تغییر زنجیره‌ها را به‌روز می‌کند.
- **تغییر نام 25 به 15 (C-L07/CR-07):** به تعویق افتاد. پوشش 99 کار می‌کند و تغییر نام وسط بازبینی همهٔ زنجیره‌ها را جابه‌جا می‌کند.

### R-XFK — کلیدهای خارجی بین‌ماژولی (`99_cross_fk.sql`)
1. **تعریف FK:**
   - هر FK بین دو جدول مستأجری ترکیبی است و با `tenant_id` شروع می‌شود.
   - اگر هر دو سو `company_id` دارند و مقصد `UNIQUE (tenant_id, company_id, id)` دارد، FK سه‌ستونیِ «همان شرکت» است.
   - با این قاعده نسخهٔ سه‌ستونی این FKها انتخاب شد:
     - `pos.terminal → inventory.warehouse`
     - `pos.* → tax.memory/tax.invoice`
     - `sales.invoice → tax.invoice`
2. **FK به جدول سراسری** (`ref.*`، `rules.tax_category`) تک‌ستونی است.
3. **نام قید:** `fk_<from_table>__<to_schema>_<to_table>[_<نقش ستون>]` (01 §۱۲ بند ۴). اگر سندی نام دیگری داده، باید نام 99 را بپذیرد:
   - 02 §۱۲: `role_assignment_scope_*_fk`
   - 04 §۱۲: `fk_party__created_by` و مانند آن
   - 06 §۱۲: `terminal_*_fk` و `ticket_*_fk`
   - 07 §۱۲: `fk_tax_invoice__…` و `fk_item__tax_category`
4. **idempotent:**
   - قید هم‌نام باید هم‌تعریف باشد، وگرنه `HK_XFK_NAME_CLASH`.
   - FK هم‌ارز با نام دیگر دوباره ساخته نمی‌شود.
5. **FK بیرون از DAG:** هر FK بین‌اسکیمایی باید جفت (ماژول مبدأ، ماژول مقصد) آن در ستون «وابستگی مجاز» جدول 01 §۵-۱ باشد. این ستون فهرست کامل است، نه بستار گذرا؛ مثلاً `pos` به `ledger` وابسته نیست، هرچند `treasury` هست. مقایسهٔ شمارهٔ لایه کافی نیست (RV-ARCH-08)، چون یال هم‌لایه (چرخهٔ `inventory ↔ tax`) و یال رو به پایینِ اعلام‌نشده (`treasury → catalog`) را نمی‌گیرد.
   - **منبع در پایگاه داده:** `core.module_registry()` در `00_foundation.sql` (ماژول، لایه، `depends_on`). برابر جدول 01 §۵-۱ است به‌اضافهٔ دو تصمیم پذیرفته: `catalog → parties` (04:CR-01) و `assistant` در L8 با وابستگی به L0 تا L7 (10:C-AS-05). `ModuleSpec.depends_on` باید با آن برابر باشد. هر تغییر DAG هر دو را با هم عوض می‌کند.
   - **lint:** `core.xfk_dag_violations()` هر FK بیرون از `depends_on` را که برچسب `COMMENT ON CONSTRAINT … 'HK_DAG_EXCEPTION: …'` ندارد برمی‌گرداند. اسکیمای ثبت‌نشده هم خطاست. خودآزمایی پایانی 99 با `HK_XFK_DAG` متوقف می‌شود. آزمون یکپارچه این‌ها را می‌سنجد:
     - `A2.cross_schema_fks_follow_dag`؛
     - `A2.dag_registry_matches_schemas` و `A2.dag_registry_is_layered_dag`؛
     - `A2.dag_exceptions_match_rulings`: هر برچسب باید در جدول زیر باشد، پس بخشی نمی‌تواند با برچسب زدن به FK خودش از lint بگذرد؛
     - `A2.dag_lint_flags_same_layer_upward_and_undeclared` (کاوش).
   - **استثناهای پذیرفته** (فقط این‌ها):

     | FK | جهت |
     |---|---|
     | `core.role_assignment_scope → inventory.warehouse/treasury.cash_box/pos.terminal/ledger.dimension_value` | L0 به بالا |
     | `rules.param_override → payroll.workshop` | L1→L5 |
     | `tax.invoice → sales.invoice` | L4→L5 |
     | `tax.invoice_issue_line → sales.invoice_line` | L4→L5 |
     | `assets.disposal → sales.invoice` | L4→L5 |
     | `pos.cash_movement (posting_key) → ledger.posting_key` | L6→L3، بیرون از `pos.depends_on` (RV-ARCH-08). فقط کاتالوگ کد سراسری؛ کد `pos` هرگز `ledger` را import نمی‌کند (06 INV-POS-14) و ثبت را treasury انجام می‌دهد |

   - کد ماژول پایین‌دست هرگز ماژول بالادست را import نمی‌کند و شناسه را از payload فرمان یا رویداد می‌گیرد.
   - این بند INV-ARCH-09 بند ۱ و 01 §۵-۲ بند ۳ را اصلاح می‌کند: «هم‌جهت DAG» یعنی «در `depends_on`»، نه «لایهٔ پایین‌تر».
6. **FKهای عمداً بیرون از 99** (در §۱۲ هر سند مستندند):
   - ارجاع‌های نرم و چندریختی.
   - FKهای تایپ‌شدهٔ اختیاری `migration.posting`.
   - هر FK به پایگاه کنترل. چنین FKی ممکن نیست.

### R-ACTOR — ستون‌های کنشگر
- هر `*_by` و `actor_user_id` در جدول مستأجری FK ترکیبی به `core.tenant_membership (tenant_id, user_id)` دارد.
- کنشگر سیستمی `NULL` است و نوع کنشگر در `core.audit_log.actor_kind` ثبت می‌شود.
- fixtureهای آزمون مشترک برای هر کاربر عضویت می‌سازند (C-L18).

### R-APPEND — جدول فقط‌افزودنی
- **سازوکار:**
  - تریگر سطری `core.forbid_mutation` برای `UPDATE/DELETE`.
  - تریگر سطح دستور `BEFORE TRUNCATE`.
  - کمک‌تابع پایه: `core.make_append_only(regclass)`.
- **پوشش جدول‌های موجود:** `99_cross_fk.sql` روی هر جدول دارای تریگر سطری `forbid_mutation` خودکار `trg_no_truncate` می‌گذارد. روی پایگاه یکپارچه ۸۰ جدول پوشش گرفتند.
- **پاک‌سازی و درون‌ریزی:** پاک‌سازی نهایی مستأجر و درون‌ریزی `.hkx` با `session_replication_role=replica` (فقط `hk_migrator`) از این تریگرها می‌گذرند.
- **منع `ENABLE ALWAYS`:** هیچ بخشی روی جدول فقط‌افزودنی تریگر `ENABLE ALWAYS` نمی‌گذارد. بررسی شد: صفر مورد.

### R-IMPORT — درون‌ریزی بستهٔ صادراتی همان مستأجر (تعارض 01:C-08 با 02:۱۳.۸ و 03:C-L04)
- **تصمیم به نفع روش replica:**
  - `hk_migrator` با context همان مستأجر و `session_replication_role=replica` COPY می‌کند.
  - سپس قلاب‌های **اجباری** راستی‌آزمایی هر ماژول اجرا می‌شوند.
  - هر ناسازگاری درون‌ریزی را رد می‌کند.
- **قلاب‌ها و کنترل‌ها:**

  | منبع | قلاب یا کنترل |
  |---|---|
  | ledger | D-L27 و بازسازی `balance_bucket` |
  | inventory | `setval` و `rebuild_derived` (CR-C12) |
  | tax | `package_id`ها، مهر دوبارهٔ کلید، `check_control_accounts` (CR-CMP-20) |
  | همه | برابری مقادیر کنترلی |

- **بخش ردشدهٔ 01:C-08:** «تریگرهای روشن» برای مسیر درون‌ریزی رد شد، چون سند دائم و دورهٔ بسته با تریگر روشن درج‌پذیر نیست.
- **بخش پذیرفتهٔ 01:C-08:** «سند تازه ساخته نمی‌شود و مقادیر کنترلی برابرند» در قلاب‌ها حفظ شده است.
- **مهاجرت از نرم‌افزار دیگر** همچنان فقط از `PostingRequest` می‌رود.

### R-TX — یک تراکنش، یک مستأجر
- تنظیم دوبارهٔ `app.tenant_id` با مقدار دیگر در یک تراکنش خطاست. اجرا با `UnitOfWork` است و ledger با `assert_tenant_context` fail-safe است (C-L05).
- **استثنای مسیرهای stream دستیار (C-AS-15):** چند UoW کوتاه پشت سر هم مجاز است، و هر UoW یک مستأجر دارد.

### R-GUC — رجیستری GUC
- **مالک رجیستری:** بخش ۰۲. هر GUC تراکنشی (`set_config(…, true)`) آن‌جا ثبت می‌شود.
- **فهرست GUCهای `app.*`:** `app.tenant_id`، `app.user_id`، `app.actor_via` و `app.impersonation_session_id`.
- **فهرست GUCهای `hk.*`:** `hk.parties_merge`، `hk.catalog_allow_backdate`، `hk.migration_purge` و `hk.redenomination`. مورد آخر برای نگهبان ارز پایهٔ C-L09 است.
- **حفاظت:** `UnitOfWork` تنظیم `hk.*` را از کد ثبت‌نشده رد می‌کند (04:CR-10).

### R-IDEM — کدهای وضعیت Idempotency (تعارض 01 با 02 و 09)
مطابق الگوریتم 01 §۵-۸ (`run_idempotent`، 01:1321-1349)، سناریوهای مرزی 01 §۸ ردیف ۱۵ و ۱۶، قاعدهٔ «اجباری» 01 §۶ و
INV-API-01 (01:2617). این جدول را بازبینی RV-ARCH-13 / RV-X1-14 اصلاح کرد: نسخهٔ پیشین «کلید نیست» و «کلید بدشکل است» را
در یک ردیف `400 core.idempotency.key_invalid` گذاشته بود و به‌اشتباه به 01 نسبت می‌داد.

| حالت | کد وضعیت | کد خطا |
|---|---|---|
| کلید نیست و مسیر آن را **اجباری** دارد (`money_moving` یا `Idem.REQUIRED`) | **`428`** | `core.idempotency.key_required` |
| کلید هست ولی بدشکل است (با `IDEM_KEY_RE` نمی‌خواند) | `400` | `core.idempotency.key_invalid` |
| درخواست اول در جریان است | `409` | `core.idempotency.in_progress`، با `Retry-After: 2` |
| همان کلید با بدنه یا مسیر دیگر | **`422`** | `core.idempotency.key_reused` |

- **انحراف آگاهانه از پیش‌نویس IETF:** draft-ietf-httpapi-idempotency-key-header برای «کلید نیست» `400` را توصیه (SHOULD) می‌کند. حساب‌کتاب `428 Precondition Required` (RFC 6585) را نگه می‌دارد:
  - هم‌خوان با «نبودِ `If-Match`» که آن هم `428 core.concurrency.precondition_required` است (01:2132)؛
  - کلاینت از کد وضعیت تشخیص می‌دهد که باید سرآیند بفرستد و همان درخواست را تکرار کند، بی‌آن‌که بدنه را تغییر دهد؛
  - همهٔ بخش‌ها (01:2552 و 2617، 06:1712، 07:938، 08:1494، 09:1845) و آزمون قرارداد `test_money_moving_routes_require_idempotency` همین را فرض کرده‌اند.
  - سه حالت دیگر (کلید بدشکل `400`، استفادهٔ دوباره `422`، درخواست هم‌زمان `409`) همان مقادیر پیش‌نویس‌اند.
- **مسیر «پشتیبانی» (اختیاری):** بدون کلید اجرا می‌شود و بازپخش ندارد. کلید بدشکل همان `400` را می‌گیرد.
- **بندهای مخالف:**
  - 02 INV-IDEM-02 «همان کلید + درخواست دیگر ← ۴۰۹» (02:1345) و متن 02:1109 (`409 core.idempotency.key_reused`) باید `422` شوند (RV-IT-07). در همان 02:1109 `Retry-After: 1` باید `2` شود.
  - 02:1173 نام کوتاه `428 idempotency_key_required` باید کد کامل `core.idempotency.key_required` شود (RV-X1-14). در همان سطر «`If-Match` نخواندن ← `409 version_conflict`» باید با 01:2132 یکی شود: `412 core.concurrency.stale` برای عدم تطابق و `428 core.concurrency.precondition_required` برای نبود سرآیند.
  - 09 «`HK_PLT_IDEMPOTENCY_COMPLETED` ← ۴۰۹» (09:1764) باید اصلاح شود (RV-IT-08).
- **تعارض کسب‌وکاری ۴۰۹ می‌ماند.** این موارد مربوط به سرآیند `Idempotency-Key` نیستند:
  - کلید مبدأ تکراری با hash دیگر در ledger (INV-LED-26).
  - `treasury.open_item.source_conflict`.
- **کلید اجباری است** روی:
  - هر POST پولی؛
  - تصمیم تأیید؛
  - رزرو، بستن رزرو و ابطال شماره (02:۱۳.۱۰).

### R-ERR — فضای نام کدهای خطا
- **پایگاه داده:** پیام `HK_<NS>_<REASON>` با `ERRCODE P0001`، مگر SQLSTATE استاندارد.
- **فضاهای نام:**

  | سند | فضای نام |
  |---|---|
  | پایه | `HK_IMMUTABLE`، `HK_ENCODING`، `HK_PG_VERSION`، `HK_PREREQ`، `HK_WRONG_DATABASE`، `HK_TENANT_*`، `HK_DEFINER_*` |
  | 02 | `HK_CORE`، `HK_NUM`، `HK_APPROVAL`، `HK_JOB`، `HK_IMP`، `HK_CF`، `HK_ATT`، `HK_SETTING`، `HK_SCHEDULE`، `HK_RET`، `HK_OUTBOX`، `HK_SOD` |
  | 03 | `HK_LEDGER` (`HK_UNBALANCED` نام مستعار مجاز می‌ماند) |
  | 04 | `HK_PARTY`، `HK_CATALOG` |
  | 05 | `HK_INV`، `HK_SALES`، `HK_PUR`، `HK_COMMERCE` |
  | 06 | `HK_TRS`، `HK_CHQ`، `HK_POS`، `HK_SYNC`، `HK_BNK`، `HK_GW`، `HK_CRD` |
  | 07 | `HK_TAX`، `HK_RULES`، `HK_PAYROLL`، `HK_ASSETS` |
  | 08 | `HK_MIG` |
  | 09 | `HK_PLT` |
  | 10 | `HK_AST` |
  | یکپارچه‌ساز | `HK_XFK` |

  `HK_AST` (دستیار) و `HK_ASSETS` (دارایی) جدا می‌مانند.
- **API** (فیلد `code` در بدنهٔ RFC 9457؛ قاعدهٔ یکتا پس از بازبینی RV-X1-16):
  1. **شکل:** `^[a-z]+(\.[a-z0-9_]+){2,3}$`، یعنی `<module>.<object>.<reason>` یا `<module>.<object>.<sub>.<reason>`. کد ۲ بخشی (`assistant.busy`، `sales.internal_inconsistency`) و کد بی‌پیشوند (`not_found`، `version_conflict`) هیچ استثنایی ندارد. توضیح regex در 01 §۵-۲۲-۲ (`{2}`) باید `{2,3}` شود.
  2. **پیشوند = ماژول تعریف‌کننده:** بخش اول نام ماژولی از 01 §۵-۱ است که کد در `errors.yaml` همان ماژول تعریف شده است. `commerce` ماژول نیست و پیشوند نمی‌شود. کاتالوگ عمومی kernel پیشوند `core.` دارد (مثل نگاشت‌های 01 §۵-۵: `core.reference.not_found`، `core.validation.constraint`، `core.concurrency.*`، `core.idempotency.*`، `core.record.immutable`).
  3. **صدور:** هر ماژول فقط کدهای خودش و کدهای عمومی `core.*` کاتالوگ kernel را برمی‌گرداند (نگاشت پایگاه داده همین را می‌کند). تنها کد بین‌ماژولی `assistant.principal.write_forbidden` است (بند ۵).
  4. **ردهٔ ۵۰۰ (ناوردای شکسته، باگ):** یک املا: `<module>.internal.<reason>`. بخش `internal` رزرو است: وضعیت `500`، `category: internal`، `retryable: false`، بدون مقدار ستون یا stack. برعکس، هر کد `500` همین بخش را دارد. کدهای عمومی kernel: `core.internal.unexpected`، `core.internal.tenant_isolation` (Sev-1) و `core.internal.invariant` (Sev-2؛ هر ماژول می‌تواند آن را برگرداند، مثل 06:1629). پیشوند سطح بالای `internal.*` و شکل `<module>.internal_<x>` ممنوع است.
  5. **رد principal دستیار** (C-AS-11): وابستگی kernel `forbid_assistant_actor` و کد `assistant.principal.write_forbidden` (۴۰۳). کد در `assistant/api/errors.yaml` تعریف می‌شود و kernel آن را از `ErrorCode` تولیدشدهٔ سراسری می‌گیرد، بی‌آن‌که `assistant` را import کند. نام‌های `assistant.write_forbidden` و `ledger.journal.assistant_cannot_post` فقط به‌شکل `alias_of` در کاتالوگ فقط‌افزودنی می‌مانند و هرگز صادر نمی‌شوند.
  6. **lint:** `hk lint errors` (job `arch-py` در 01 §CI) بندهای ۱ تا ۴ را روی هر `errors.yaml` می‌سنجد (regex، پیشوند = `module:` فایل، `internal` ⇔ `500`، و `alias_of` فقط به کد موجود). آزمون: `tests/unit/kernel/test_error_catalog.py::test_codes_follow_r_err`.
- **نام‌های ناسازگار در متن بخش‌ها** (برداشت بازبینی RV-X1-16 به‌اضافهٔ پویش جدول‌های نگاشت همهٔ سندها؛ هر بخش در متن خودش اصلاح می‌کند):

  | سند و سطر | نام فعلی | نام درست |
  |---|---|---|
  | 01:1166 و 01:1167 | `internal.tenant_isolation`، `internal.unexpected` | `core.internal.tenant_isolation`، `core.internal.unexpected` |
  | 02:565 و 02:1433 | `401 mfa_step_up_required` | `core.auth.mfa_step_up_required` |
  | 02:622 و 02:624 | `403 field_write_denied`، `409 sod_conflict` | `core.field.write_denied`، `core.sod.conflict` |
  | 02:1173 | `428 idempotency_key_required`، `409 version_conflict` | `core.idempotency.key_required` و R-IDEM (`412 core.concurrency.stale` / `428 core.concurrency.precondition_required`) |
  | 02:1353، 02:1357، 02:1374 | `last_owner`، `fiscal_year_not_found`، `impersonation_ended` | `core.member.last_owner`، `core.numbering.fiscal_year_not_found`، `core.impersonation.ended` |
  | 03:1052 | `ledger.reason_required` | `ledger.request.reason_required` |
  | 04:1315 | `catalog.code_space_exhausted`، `parties.code_space_exhausted` | `catalog.code_series.exhausted`، `parties.code_series.exhausted` |
  | 04:1321 (۵۰۰) | `core.immutable_field` | `parties.internal.immutable_field` و `catalog.internal.immutable_field` |
  | 05:975 | `inventory.negative_stock` | `inventory.stock.negative` |
  | 05:986 | `sales.internal_inconsistency` | `sales.internal.inconsistency` |
  | 05:987 | `commerce.internal_link` | `<inventory\|sales\|purchase>.internal.link` (ماژول جدولی که پیام را بالا می‌برد) |
  | 05:990 | `purchase.duplicate_supplier_invoice` | `purchase.invoice.duplicate_supplier_invoice` |
  | 05:991 | `not_found` | `core.resource.not_found` |
  | 06:2001 | `ledger.period_closed` (۴۲۲) | `ledger.period.closed` (۴۰۹؛ 03:1039) |
  | 07:988 | `409 inquiry_pending` | `tax.invoice.inquiry_pending` |
  | 10:1206، 10:1227، 10:1432؛ 05:1007 | `assistant.write_forbidden` | `assistant.principal.write_forbidden` |
  | 10:1207 | `assistant.impersonation_forbidden` | `assistant.principal.impersonation_forbidden` |
  | 10:1208، 10:1213، 10:1224 | `assistant.disabled`، `assistant.busy`، `assistant.validation` | `assistant.service.disabled`، `assistant.run.busy`، `assistant.thread.invalid` |
  | 10:1216، 10:1219، 10:1225 | `internal.assistant_budget_config`، `internal.assistant_invariant`، `internal.assistant_retention` | `assistant.internal.budget_config`، `assistant.internal.invariant`، `assistant.internal.retention` |

  نام پیشنهادی ستون سوم الزامی نیست؛ هر نام دیگری که بندهای ۱ تا ۴ را رعایت کند پذیرفته است. وضعیت HTTP هر سطر تغییر نمی‌کند، جز سطر 06:2001.

### R-INV — فضای نام شناسهٔ ناوردا
هر سند فقط در فضای نام خودش شناسه **تعریف** می‌کند. ارجاع به شناسهٔ سند دیگر آزاد است.

| سند | پیشوندها |
|---|---|
| 01 | `ARCH`، `OPS`، `API`، `FE`، `SEC`، `DEV`، `EDGE` |
| 02 | `IAM`، `TEN`، `AUTHZ`، `NUM`، `JOB`، `IMP`، `AUD`، `SET`، `ATT`، `APR`، `TXT`، `SOD`، `RET`، `OBX`، `CF`، `IDEM`، `EXP`، `NTF` |
| 03 | `LED` |
| 04 | `PTY`، `CAT`، `MD`، `REF` |
| 05 | `INV`، `SAL`، `PUR`، `PCK`، `COM` |
| 06 | `CHQ`، `TRS`، `POS`، `SYNC`، `BNK`، `GW`، `CRD`، **`POSSEC`** (جایگزین `SEC-01..05`)، **`POSEDGE`** (جایگزین `EDGE-01..03`) |
| 07 | `TAX`، `PAY`، `RUL`، `AST` (دارایی ثابت)، `CMP` |
| 08 | `MIG` |
| 09 | `P*` (`PBIL`، `PTNT`، …) |
| 10 | **`AI`** (جایگزین `AST-01..33`) |
| یکپارچه‌ساز | `INT` |

- **برخوردهای شناسه:**
  - `INV-SEC-01..05` و `INV-EDGE-01..03` هم در 01 تعریف شده‌اند و هم در 06. مقایسه کنید 06:1975-1987 با 01:2641-2660 (RV-IT-09).
  - `INV-AST-01..13` در 07:1139 و `INV-AST-01..33` در 10:1271 تعریف شده‌اند (RV-IT-10).
- **انتخاب سندی که تغییر نام می‌دهد:** سندی که هزینهٔ تغییر کمتری دارد. 07 در ۵۲ برچسب آزمون SQL از `INV-AST` استفاده می‌کند. 10 هیچ برچسب آزمون SQL با `INV-AST` ندارد.

### R-AI — تنها استثنای «بدون فراخوانی خارجی» (Q-F)
1. **فراخوانی مجاز:** تنها فراخوانی شبکه‌ای که ممکن است به سرویس غیرایرانی برسد، endpoint سازگار با OpenAI دستیار است.
2. **مسیر فراخوانی:**
   - فقط از `contracts.ports.llm.LlmCompletionPort` در ماژول `assistant`.
   - از راه `OutboundHttpClient`، با allowlist اپراتور (`platform.ai_provider` و بلوک امضاشدهٔ `assistant_policy` در `hkcellstate/1`).
   - هیچ ماژول دیگری کلاینت LLM نمی‌سازد. پیشنهاد نگاشت مهاجرت هم از همین درگاه با `purpose=migration_mapping` می‌رود (C-AS-14).
3. **پیش‌فرض و رضایت:**
   - پیش‌فرض برای هر مستأجر خاموش است.
   - روشن شدن به رضایت مستأجر با هدف و ردهٔ داده نیاز دارد.
   - بودجه، ممیزی و کلید خاموشی دارد. خاموش کردن آزاد است و روشن کردن با تأیید دونفره (CR-PLT-10).
4. **بی‌اثر بر حسابداری:**
   - خاموش یا قطع بودن دستیار هیچ اثری بر حسابداری ندارد.
   - هیچ FK از ماژول دیگر به `assistant` نیست.
   - پیش‌نویس‌ها فقط ستون منشأ دارند.
   - هیچ مسیر حسابداری منتظر پاسخ مدل نمی‌ماند.
5. **حالت مدل:**
   - هر فراخوانی ابزار در حالت مدل در تراکنش `READ ONLY` با `app.actor_via='assistant'` اجرا می‌شود.
   - تحقق پیشنهاد فقط با تأیید انسانی و `actor_via='assistant_confirm'` انجام می‌شود.
   - مجوز critical هرگز در سقف دستیار نیست.
6. **On-prem و سرور داخل سلول:** ارائه‌دهنده می‌تواند سرور مدل داخل سلول یا خودمیزبان باشد. `http` فقط برای `network='cell_private'` مجاز است.
7. **سایر فراخوانی‌های بیرونی** (مؤدیان، بانک، پیامک، درگاه) فقط به سرویس‌های داخلی و از ماژول بی‌حالت `integrations` می‌روند (C-AS-13).

### R-AI-PRINCIPAL — principal دستیار (03:C-L17، 07:CR-CMP-18، 10:C-AS-01)
- `Principal.delegation` و `is_ai_assistant` افزوده می‌شوند.
- `core.audit_log.actor_kind` مقدار `'assistant'` را می‌پذیرد، با `actor_user_id` اجباری.
- قالب نقش `ai_assistant` حذف می‌شود.
- سقف مجوز دستیار = اشتراک سقف ابزار (`assistant.v_permission_ceiling`) و مجوزهای کاربر نیابت‌دهنده.
- در حالت مدل فقط `*.read` مجاز است و مجوز critical هرگز.

### R-EXPORT — رجیستری صدور برای هر جدول مستأجری
- هر جدول دارای `tenant_id` در **همان فایلی که آن را می‌سازد** در `core.export_table_registry` ثبت می‌شود: `rows`، `hook`، یا `skip` با دلیل اجباری.
- یافتهٔ `tenant_table_not_in_export_registry` در هارنس allowlist ندارد و گام lint را قرمز می‌کند (RV-IT-01).

### R-OUTBOX — fan-out تحویل
- ساخت ردیف‌های `outbox_delivery` با تریگر `core.outbox_fanout` روی کاتالوگ مشترک‌ها است (02:۱۳.۱۴).
- `OutboxWriter` فقط رویداد را درج می‌کند.
- متن 01:657 و INV-OPS-01 (01:2629) باید اصلاح شود (RV-IT-06).

### سایر قاعده‌های مشترک پذیرفته
- **R-USER:** جدول‌های سطح کاربر در `core` بدون `tenant_id`، با RLS کاربرمحور (`core.current_user_id()`) مجازند و فقط بخش ۰۲ آن‌ها را تعریف می‌کند (02:۱۳.۴).
- **R-PK:** برای جدول‌های پرحجم فقط‌افزودنی که نامزد پارتیشن `HASH(tenant_id)` هستند، `PRIMARY KEY (tenant_id, id)` مجاز است. شرط `UNIQUE (tenant_id, id)` با همان کلید برقرار است. تصمیم پیش از تولید اعمال شود (C-L01).
- **R-CP:** در پایگاه کنترل:
  - `tenant_id` شناسهٔ موضوع است و محور RLS نماینده (`partner_own`) است.
  - مبلغ `numeric(24,0)` ریال صحیح است، با ستون `currency` و `CHECK currency='IRR'`. حذف چهار صفر با migration انجام می‌شود (CR-PLT-01/02).
  - کمک‌تابع‌های تکراری `platform.*` با آزمون برابری با پایه هم‌خوان نگه داشته می‌شوند (CR-PLT-16).
- **R-STDDATA:** کدینگ، قالب صورت‌ها و سایر «دادهٔ استاندارد» با `industry_pack_version` منتشر می‌شوند: بازبین، `confidence` و دروازهٔ `report_coverage` به‌اضافهٔ ردیف کنترلی صفر (C-L11، CR-PLT-13).
- **R-QUALITY:**
  - هر بررسی پایگاه داده‌ای با الگوی دقیق کد و پیام خودش آزموده می‌شود.
  - CI آزمون جهش را روی همهٔ فایل‌های SQL اجرا می‌کند.
  - بازماندهٔ مجاز فقط با اثبات دسترس‌ناپذیری پذیرفته است.
  - اجرای موازی جهش، `ALTER ROLE` را از اعمال جهش جدا می‌کند (C-L19، CR-PLT-14).
- **R-GLOSSARY:**
  - در ledger: posted = temporary ∪ permanent، و cancelled = voided یا reversed (مشتق).
  - فقط `permanent` قطعی قانونی است (C-L02).
  - rollback مهاجرت فقط جبرانی است (CR-MG17).
  - اصطلاحات HIF، `migration.job` و staging مشترک با RLS (CR-MG16).

---

## ۱. پایه (`00_foundation.sql`، `dev_roles.sql`) — مسئول: یکپارچه‌ساز

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 01:C-01 | معماری | نقش‌ها `NOLOGIN` و بدون رمز | پذیرفته | رمز ثابت نباید به تولید برسد (R-ROLE) | یکپارچه‌ساز | انجام‌شده (+ `dev_roles.sql`) |
| 01:C-02 | معماری | `hk_migrator`، `hk_dispatcher`، `hk_reports` و مهلت‌ها | پذیرفته | 01 D-06. `hk_reports` عضو `hk_readonly` شد تا GRANT ستونی تکرار نشود | یکپارچه‌ساز | انجام‌شده |
| 01:C-03 | معماری | policy `dispatcher_read` و GRANT ستونی `(id, slug, status)` روی `core.tenant` | پذیرفته | policy و GRANT در 10_core ساخته شده‌اند. نقش در پایه است | هسته | انجام‌شده |
| 01:C-04 | معماری | `ALTER DEFAULT PRIVILEGES` | پذیرفته فقط برای `ref` | پیش‌فرض SELECT روی اسکیماهای تجاری با پنهان کردن ستون راز (02:۱۳.۶) تعارض دارد (R-GRANT) | یکپارچه‌ساز | انجام‌شده |
| 01:C-05 | معماری | نوشتن `ref` فقط با `hk_migrator` | پذیرفته | R-REF. روی پایگاه یکپارچه هیچ GRANT نوشتنی برای `hk_app` روی `ref` نیست | همه | انجام‌شده |
| 02:۱۳.۱ | هسته | assert `UTF8` در پایه | پذیرفته | R-DB | یکپارچه‌ساز | انجام‌شده |
| 02:۱۳.۲ | هسته | نقش‌ها و افزونه‌ها در پایه؛ اسکیمای `ext` | نقش و افزونه پذیرفته؛ `ext` رد | بدون پیشوند ماندن `gin_trgm_ops` و `%` (R-EXT) | یکپارچه‌ساز | انجام‌شده |
| 02:۱۳.۳ | هسته | `UNIQUE (tenant_id, company_id, id)` روی `core.branch`، policyهای `core.tenant`، رجیستری صدور company/branch | پذیرفته | قید با همان نام به پایه آمد (بررسی 10_core بی‌اثر می‌شود). policy و رجیستری مال هسته می‌مانند، چون به `tenant_membership` وابسته‌اند | یکپارچه‌ساز / هسته | انجام‌شده |
| 02:۱۳.۸ | هسته | نسخهٔ `TRUNCATE` نگهبان؛ بدون `ENABLE ALWAYS` | پذیرفته | R-APPEND: `core.make_append_only`. 99 روی ۸۰ جدول `trg_no_truncate` گذاشت. در حالت replica عبور می‌کند (آزموده شد) | یکپارچه‌ساز | انجام‌شده |
| 02:۱۳.۹ | هسته | GRANT ستونی `UPDATE` روی `core.tenant` | پذیرفته | وضعیت و نوع استقرار را پنل مالک تعیین می‌کند | یکپارچه‌ساز | انجام‌شده |
| 03:C-L06 | دفتر کل | ساخت `hk_ledger_definer` در پایه | پذیرفته | R-ROLE. ورود به allowlist ← جدول معماری | یکپارچه‌ساز | انجام‌شده |
| 03:C-L10 | دفتر کل | ردیف ریال جدید در `ref.currency` | به تعویق | کد ISO 4217 هنوز قطعی نیست. ضریب فقط در پارامتر `currency.redenomination.factor` است (CR-CMP-15) | یکپارچه‌ساز | باز (پس از اعلام کد) |
| 04:CR-09 | دادهٔ پایه | انتقال نگهبان `HK_ENCODING` به پایه | پذیرفته | R-DB | یکپارچه‌ساز | انجام‌شده |
| 04:CR-11 | دادهٔ پایه | نقش `hk_migrator` | پذیرفته | R-ROLE | یکپارچه‌ساز | انجام‌شده |
| 05:CR-C03 | تجارت | ساخت `hk_inventory_definer` و همهٔ نقش‌های definer در پایه | پذیرفته | migration ماژول به `CREATEROLE` نیاز ندارد | یکپارچه‌ساز | انجام‌شده |
| 07:CR-CMP-01 | انطباق | نقش `hk_migrator` | پذیرفته | R-ROLE | یکپارچه‌ساز | انجام‌شده |
| 08:CR-MG19 | مهاجرت | نقش `hk_migrator` | پذیرفته | R-ROLE | یکپارچه‌ساز | انجام‌شده |
| 08:CR-MG14 | مهاجرت | `core.company.kind IN ('live','rehearsal')` | به تعویق | ستونی که هیچ ماژولی رعایتش نکند امنیت کاذب می‌دهد. شرکت تمرینی باید در ارسال مؤدیان، دفاتر الکترونیکی و پیامک قطعاً مستثنا شود (بخش ۰۷ و ۰۲). حساب شدن یا نشدنش در پلن تصمیم محصولی است | یکپارچه‌ساز + ۰۲ + ۰۷ | پرسش صاحب محصول |
| 10:C-AS-16 | دستیار | اسکیمای `assistant` و `USAGE` در پایه | پذیرفته | یک اسکیما برای هر ماژول، در یک جا | یکپارچه‌ساز | انجام‌شده |
| 04:CR-02 | دادهٔ پایه | فایل `05_ref.sql` یا مالکیت رسمی | پذیرفته (مالکیت رسمی)؛ یک‌جاسازی به تعویق | R-REF | ۰۴ | انجام‌شده (قاعده) |
| 06:CR-T11 | خزانه | انتقال `ref.sayad_credit_status` و `ref.psp` به فایل `ref` | به تعویق | R-REF: مالکیت با ۰۶ می‌ماند | ۰۶ | انجام‌شده (قاعده) |
| 07:CR-CMP-02 | انطباق | افزودن `ref.sstid_vat_rate` و `ref.ssi_job_code` به فهرست رسمی و `reference_snapshot` | پذیرفته | R-REF. سازوکار snapshot در بخش ۰۹ و ۰۷ | ۰۷ / ۰۹ | باز (snapshot) |

## ۲. قرارداد مشترک (همهٔ بخش‌ها)

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 02:۱۳.۴ | هسته | جدول‌های سطح کاربر بدون `tenant_id` | پذیرفته | R-USER | ۰۲ | انجام‌شده |
| 02:۱۳.۵ | هسته | `ref` فقط دادهٔ بیرونی؛ کاتالوگ‌ها در اسکیمای ماژول | پذیرفته | R-REF | همه | انجام‌شده |
| 02:۱۳.۶ | هسته | `hk_readonly` بدون ستون‌های راز | پذیرفته | R-GRANT | همه | انجام‌شده (۰۲، ۰۷)؛ دیگر بخش‌ها هنگام افزودن راز |
| 07:CR-CMP-07 | انطباق | همان: GRANT ستونی عمومی | پذیرفته | R-GRANT | همه | انجام‌شده |
| 02:۱۳.۷ | هسته | FK کنشگر به `tenant_membership` | پذیرفته | R-ACTOR | همه | انجام‌شده |
| 03:C-L08 | دفتر کل | همان، قرارداد مشترک شود | پذیرفته | R-ACTOR | همه | انجام‌شده |
| 03:C-L18 | دفتر کل | 99 پیش از داده؛ fixture با عضویت | پذیرفته | R-ACTOR و R-ORDER. هارنس 99 را پیش از هر آزمون یکپارچه اجرا می‌کند | یکپارچه‌ساز / همه | انجام‌شده |
| 08:CR-MG21 | مهاجرت | همان | پذیرفته | R-ACTOR | همه | انجام‌شده |
| 02:۱۳.۱۰ | هسته | ۴۰۹ به‌جای ۴۲۲؛ کلید اجباری روی تأیید و شماره | ۴۰۹ رد (R-IDEM: ۴۲۲)؛ اجباری بودن پذیرفته | هم‌راستا با 01 و پیش‌نویس IETF | ۰۲ / ۰۹ | باز (RV-IT-07، RV-IT-08) |
| 02:۱۳.۱۱ | هسته | `details` ممیزی متن canonical | پذیرفته | hash مستقل از قالب jsonb | ۰۲ | انجام‌شده |
| 02:۱۳.۱۲ | هسته | جلالی فقط در Python و TS | پذیرفته؛ `core.jalali_ym` به تعویق | منطق تقویم فقط یک مالک دارد | ۰۲ | انجام‌شده |
| 02:۱۳.۱۳ | هسته | کلید `fy:<uuid>` بدون FK | پذیرفته | جلوگیری از چرخه. سال مالی دارای سند حذف‌شدنی نیست | ۰۳ | انجام‌شده |
| 02:۱۳.۱۴ | هسته | fan-out با تریگر | پذیرفته | R-OUTBOX. «رویداد بدون تحویل» در پایگاه داده ناممکن است | ۰۱ (متن) | باز (RV-IT-06) |
| 02:۱۳.۱۵ | هسته | مجوز ۳ تا ۴ بخشی؛ نوع رویداد ۳ تا ۵ بخشی | پذیرفته | CHECKهای 10_core همین را اجبار می‌کنند | همه | انجام‌شده |
| RV-ARCH-13 | بازبینی | R-IDEM «کلید نیست ← ۴۰۰» را به ۰۱ نسبت می‌داد، ولی ۰۱ و همهٔ بخش‌ها `428` دارند | پذیرفته | R-IDEM اصلاح شد: نبود کلید `428 core.idempotency.key_required`؛ کلید بدشکل `400 core.idempotency.key_invalid` | یکپارچه‌ساز / ۰۲ | انجام‌شده (قاعده)؛ باز (02:1173 نام کامل کد) |
| RV-X1-14 | بازبینی | همان RV-ARCH-13 | تکراری | — | — | انجام‌شده (RV-ARCH-13) |
| RV-X1-16 | بازبینی | R-ERR «۳ یا ۴ بخش، پیشوند ماژول» را می‌گفت ولی خودش `assistant.write_forbidden` (۲ بخش) را اجباری می‌کرد؛ سه املا برای ردهٔ ۵۰۰؛ پیشوند `commerce` | پذیرفته | R-ERR بندهای ۱ تا ۶: regex `{2,3}`، پیشوند = ماژول تعریف‌کننده، کاتالوگ عمومی `core.*`، ردهٔ ۵۰۰ فقط `<module>.internal.<reason>`، `assistant.principal.write_forbidden`، lint `hk lint errors`. جدول نام‌های ناسازگار در R-ERR | ۰۱ / ۰۲ / ۰۳ / ۰۴ / ۰۵ / ۰۶ / ۰۷ / ۱۰ | انجام‌شده (قاعده)؛ باز (متن بخش‌ها) |
| 03:C-L01 | دفتر کل | `PRIMARY KEY (tenant_id, id)` برای جدول‌های پرحجم | پذیرفته | R-PK. پیش از تولید اعمال شود | ۰۳ | باز |
| 03:C-L02 | دفتر کل | واژه‌نامهٔ posted، permanent و cancelled | پذیرفته | R-GLOSSARY | همه | انجام‌شده |
| 03:C-L05 | دفتر کل | یک تراکنش، یک مستأجر | پذیرفته | R-TX | ۰۱ / ۰۲ (UoW) | باز (UoW) |
| 03:C-L19 | دفتر کل | آزمون دقیق کد و پیام + جهش در CI | پذیرفته | R-QUALITY | ۰۱ (CI) / همه | باز |
| 09:CR-PLT-14 | پلتفرم | جهش موازی و جهش CHECK | پذیرفته | R-QUALITY | ۰۱ (CI) | باز |
| 03:C-L11 | دفتر کل | خانهٔ «دادهٔ استاندارد» | پذیرفته | R-STDDATA | ۰۹ / ۰۵ / ۰۳ | باز |
| 09:CR-PLT-13 | پلتفرم | همان | پذیرفته | R-STDDATA | ۰۹ | باز |
| 04:CR-10 | دادهٔ پایه | رجیستری GUC | پذیرفته | R-GUC | ۰۲ | باز |
| 06:CR-T12 | خزانه | `freeze_columns` (بدون ستون مولد) به `core` | پذیرفته | کمک‌تابع عمومی مانند `forbid_mutation`. به `core.raise_hk` وابسته است، پس مال 10_core است | ۰۲ | باز |
| 08:CR-MG16 | مهاجرت | اصطلاحات HIF و `migration.job` | پذیرفته | R-GLOSSARY. متن ۰۵ «run_id» ← `job_id` | ۰۵ | باز |
| 08:CR-MG17 | مهاجرت | rollback فقط جبرانی | پذیرفته | تغییرناپذیری سند ثبت‌شده | همه | انجام‌شده |
| 09:CR-PLT-01 | پلتفرم | قاعدهٔ RLS مستأجری فقط برای صفحهٔ داده | پذیرفته | R-CP | ۰۹ | انجام‌شده |
| 09:CR-PLT-02 | پلتفرم | پول صفحهٔ کنترل `numeric(24,0)` IRR | پذیرفته | R-CP | ۰۹ | انجام‌شده |
| 09:CR-PLT-16 | پلتفرم | تکرار عمدی کمک‌تابع‌ها | پذیرفته | پایه روی پایگاه کنترل اجرا نمی‌شود. آزمون برابری لازم است | ۰۹ | باز (آزمون برابری) |
| 10:C-AS-13 | دستیار | «تنها فراخوانی بیرونی» و حصار آن | پذیرفته | R-AI | ۰۱ / ۱۰ | انجام‌شده (قاعده) |
| 10:C-AS-15 | دستیار | چند UoW در مسیر stream دستیار | پذیرفته (محدود به همین مسیر) | R-TX | ۰۱ / ۰۲ | باز (متن ۰۱ D-05) |
| 10:C-AS-17 | دستیار | برخورد `INV-SEC-05` | پذیرفته | R-INV | ۰۶ / ۱۰ | باز (RV-IT-09، RV-IT-10) |
| 10:C-AS-11 | دستیار | نام واحد نگهبان دستیار | پذیرفته؛ نام کد با RV-X1-16 سه‌بخشی شد | R-ERR بند ۵: وابستگی `forbid_assistant_actor` و کد `assistant.principal.write_forbidden`؛ `assistant.write_forbidden` و `ledger.journal.assistant_cannot_post` فقط `alias_of` | ۰۳ / ۰۵ / ۰۶ / ۱۰ | باز |
| 07:CR-CMP-09 | انطباق | محدودیت فنی API بیرونی = پارامتر قواعد با سقف عقلانی DB | پذیرفته | سازمان‌ها بی‌اعلام تغییر می‌دهند | همه | انجام‌شده (۰۷) |
| 01:C-06 | معماری | نسخهٔ پین‌شده «کف» است؛ وصلهٔ امنیتی اجباری | پذیرفته | PostgreSQL 18.7 و PgBouncer 1.26.1 | ۰۱ | انجام‌شده |
| 01:C-07 | معماری | همهٔ فایل‌های امضاشده HKSB v1 | پذیرفته | یک راستی‌آزما | ۰۱ / ۰۷ / ۰۸ / ۰۹ | انجام‌شده (قاعده) |
| 01:C-08 | معماری | درون‌ریزی با تریگرهای روشن | رد برای مسیر درون‌ریزی؛ اصل «بی‌سند تازه، برابری کنترل» پذیرفته | R-IMPORT | ۰۲ / همه | باز (قلاب‌ها) |
| 03:C-L04 | دفتر کل | replica + قلاب راستی‌آزمایی | پذیرفته | R-IMPORT. `GRANT SET ON PARAMETER session_replication_role TO hk_migrator` در پایه است | ۰۲ / همه | انجام‌شده (نقش)؛ باز (قلاب‌ها) |
| 03:C-L12 | دفتر کل | نوع `Rate` و `Qty` در JSON | پذیرفته | هم‌تراز با دامنه‌های `core.rate` و `core.qty` | ۰۱ (kernel) | باز |

## ۳. معماری (`01-architecture.md`)

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 01:C-09 | معماری | رد `hk_platform BYPASSRLS` | پذیرفته | D-06. پلتفرم فقط از uplink و پشتیبانی با رضایت می‌بیند | ۰۹ | انجام‌شده |
| 01:C-10 | معماری | `integrations` بی‌حالت و بی‌اسکیما | پذیرفته | — | همه | انجام‌شده |
| 01:C-11 | معماری | کد ONE CAFE بی‌اصلاح قابل استفاده نیست | پذیرفته | کنتراست، پول float، RPC و ARIA. اصلاحات ۵-۲۳-۱۱ الزامی‌اند | ۰۱ (FE) | باز |
| 01:C-12 | معماری | build دوم POS برای Chromium 88 | پذیرفته | Tailwind 4 به Chrome 111+ نیاز دارد | ۰۱ / ۰۶ | باز |
| 01:C-13 | معماری | pub/sub Valkey برای SSE «گذرا» است | پذیرفته | هیچ تحویل پایداری به آن وابسته نیست. outbox منبع است | ۰۱ | انجام‌شده |
| 01:C-14 | معماری | `core.alembic_version` | پذیرفته | بدون `tenant_id`؛ lint آن را نادیده می‌گیرد | ۰۱ / ۰۲ | باز |
| 01:C-15 | معماری | `edge` در `core.tenant.deployment` لازم نیست | پذیرفته | لبه ویژگی نصب است: `core.deployment_info.profile` | ۰۲ | انجام‌شده |
| 01:C-16 | معماری | ساخت جدول‌های قرارداد §۴ در هسته | پذیرفته | 10_core ابرمجموعه را ساخته است (02:۱۳.۱۶) | ۰۲ | انجام‌شده |
| 01:C-17 | معماری | psycopg 3 و صف PostgreSQL | پذیرفته | — | همه | انجام‌شده |
| 01:C-18 | معماری | `SECURITY DEFINER` فقط با allowlist و پنج شرط | پذیرفته | `security_lint` شرط‌ها را می‌سنجد | ۰۱ | انجام‌شده |
| 03:C-L06 | دفتر کل | سه تابع definer ledger در allowlist | پذیرفته | پنج شرط را دارند (lint صفر) | ۰۱ | باز (فایل allowlist) |
| 05:CR-C04 | تجارت | ده تابع definer موجودی در allowlist | پذیرفته با بازبینی | یک الگوریتم برای ثبت و بازپخش؛ `hk_app` به مشتق‌ها دسترسی نوشتن ندارد. lint صفر | ۰۱ | باز (فایل allowlist) |
| 04:CR-01 | دادهٔ پایه | `catalog.depends_on += parties` | پذیرفته | سه ارجاع ذاتی؛ چرخه ندارد. در `core.module_registry()` (پایه) اعمال شد و lint DAG پایگاه داده آن را می‌پذیرد | ۰۱ | انجام‌شده (پایه)؛ باز (جدول ۰۱ §۵-۱، نمودار ۵-۲ و import-linter) |
| 05:CR-C02 | تجارت | ماژول کدی `packs` و مجوزهای `packs.pack.*` | پذیرفته | بسته داده می‌ماند و `packs` فقط نصب‌کننده است. مجوزها هنوز در `core.permission` نیستند | ۰۱ / ۰۵ | باز |
| 05:CR-C07 | تجارت | FK `core.role_assignment_scope → inventory.warehouse` فقط در 99 | پذیرفته | R-XFK بند ۵ (برچسب `HK_DAG_EXCEPTION`) | یکپارچه‌ساز | انجام‌شده |
| 07:CR-CMP-08 | انطباق | استثنای DAG `rules.param_override → payroll.workshop`؛ جهت فشاری sales ← tax | پذیرفته | R-XFK بند ۵. FK `tax.invoice → sales.invoice` هم برچسب گرفت | یکپارچه‌ساز / ۰۱ | انجام‌شده (99)؛ باز (متن INV-ARCH-09) |
| RV-ARCH-08 | بازبینی | lint DAG پایگاه داده فقط شمارهٔ لایه را می‌سنجید و یال هم‌لایه، چرخه و یال رو به پایینِ اعلام‌نشده را رد نمی‌کرد | پذیرفته | R-XFK بند ۵: `core.module_registry()` و `core.xfk_dag_violations()` در پایه؛ خودآزمایی 99 و پنج بررسی `A2.*` آزمون یکپارچه. متن ۰۱ (§۵-۲ بند ۳، INV-ARCH-09، §۱۲ بند ۱) باید بگوید «در `depends_on`»، نه «لایهٔ پایین‌تر»، و `test_cross_schema_fks_follow_dag` باید `core.module_registry()` را با `ModuleSpec` برابر بداند | یکپارچه‌ساز / ۰۱ | انجام‌شده (SQL و آزمون)؛ باز (متن ۰۱) |
| 08:CR-MG06 | مهاجرت | لنگر اعتماد «کلید نشست» برای HIF در HKSB | پذیرفته | HIF روی ماشین مشتری ساخته می‌شود | ۰۱ | باز |
| 08:CR-MG07 | مهاجرت | کمینهٔ ویندوز ۱۰ یا Server 2016 برای عامل؛ `python-tds` (MIT)؛ CI ویندوز | `python-tds` و CI پذیرفته؛ کمینهٔ سیستم‌عامل به تعویق | بخشی از مشتریان هلو و سپیدار روی Windows 7 هستند. تصمیم محصولی است | ۰۱ / ۰۸ | پرسش صاحب محصول |
| 09:CR-PLT-03 | پلتفرم | HKSB نوع `state` با امضاکنندهٔ نصب | پذیرفته | زنجیرهٔ ریشه ← لایسنس ← `install_pubkey` | ۰۱ | باز |
| 09:CR-PLT-11 | پلتفرم | ابرمجموعهٔ قرارداد §۴-۸ | پذیرفته | اطلاعی | ۰۱ | انجام‌شده |
| 09:CR-PLT-12 | پلتفرم | مبدأهای `billing.` و `activate.` | پذیرفته | callback درگاه و فعال‌سازی On-prem به مبدأ عمومی نیاز دارند | ۰۱ | باز |
| 09:CR-PLT-15 | پلتفرم | صفحهٔ کنترل به Valkey نیاز ندارد | پذیرفته | اطلاعی | — | انجام‌شده |
| 10:C-AS-05 | دستیار | `assistant` در L8، `integrations.llm`، نقش فرایند `assistant`، `KeyPurpose.LLM_API_KEY`، stream روی POST، `contracts.ports.llm` | پذیرفته | R-AI. ردیف L8 با وابستگی به L0 تا L7 در `core.module_registry()` (پایه) آمده است | ۰۱ | باز (متن ۰۱) |
| 10:C-AS-06 | دستیار | به‌روزرسانی فرض‌های پیش از پاسخ Q-F در ۰۱ | پذیرفته | API قابل تنظیم و ابزار درون‌فرایند | ۰۱ | باز |
| 02:۱۳.۱۶ | هسته | هم‌راستایی با ۰۱ (ابرمجموعه، `lock_token`، `job_claim`، PIN برای هر عضویت) | پذیرفته | امنیت PIN برابر است و مدیریتش ساده‌تر. ۰۱ متن PIN و claim را به‌روز کند | ۰۱ | باز |
| 07:CR-CMP-10 | انطباق | `hk migrate` در هر ارتقا `deployment_info.app_version` را به‌روز کند و `rules.golden.rerun` را صف کند | پذیرفته | دروازهٔ طلایی به آن تکیه دارد | ۰۱ / ۰۲ | باز |

## ۴. هسته (`02-core-platform.md`، `10_core.sql`)

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 03:C-L03 | دفتر کل | رزرو `doc_type='ledger.journal.permanent'` | پذیرفته | شمارهٔ دائم بی‌فاصله و به ترتیب تاریخ با موتور core بیان‌پذیر نیست | ۰۲ | باز |
| 03:C-L13 | دفتر کل | `project` در `scope_dimensions` | پذیرفته | CHECK فعلی `core.permission` آن را ندارد | ۰۲ | باز |
| 03:C-L16 | دفتر کل | بازهٔ رزرو سمت سرور برای هر worker | پذیرفته برای v2 | فعلاً POS سند تجمیعی و مهاجرت اندازهٔ تکه | ۰۲ | به تعویق (v2) |
| 03:C-L17 | دفتر کل | تشخیص principal دستیار و سقف مجوز | پذیرفته | R-AI-PRINCIPAL | ۰۲ | باز (`actor_kind` هنوز `'assistant'` ندارد) |
| 10:C-AS-01 | دستیار | `Principal.delegation`، `actor_kind='assistant'`، حذف قالب `ai_assistant` | پذیرفته | R-AI-PRINCIPAL | ۰۲ | باز |
| 07:CR-CMP-18 | انطباق | مجوزهای critical و sensitive انطباق بیرون از سقف دستیار | پذیرفته | R-AI-PRINCIPAL | ۰۲ / ۱۰ | باز |
| 10:C-AS-02 | دستیار | `core.forbid_actor_via()` و تریگر `"0_actor_via_guard"` روی جدول‌های ثبت قطعی | پذیرفته | دفاع لایهٔ دوم پس از `READ ONLY` حالت مدل. تابع در 10_core؛ هر ماژول تریگر جدول‌های خودش را می‌گذارد | ۰۲، سپس ۰۳/۰۵/۰۶/۰۷ | باز |
| 10:C-AS-03 | دستیار | GUC `app.impersonation_session_id` | پذیرفته | R-GUC | ۰۲ | باز |
| 10:C-AS-04 | دستیار | فهرست اسکیمای `security_lint` از کاتالوگ | پذیرفته | اسکیمای `assistant` اکنون lint نمی‌شود. هارنس lint تکمیلی همهٔ اسکیماها را دارد | ۰۲ | باز (RV-IT-05) |
| 10:C-AS-18 | دستیار | نگهداری `assistant_conversation` با مبنای `created_at`؛ job نگهداری بدون `app.user_id` | پذیرفته | — | ۰۲ | باز (کلاس هست؛ مبنا بررسی شود) |
| 05:CR-C07 | تجارت | `core.number_issued` قرارداد خواندن منتشرشده | پذیرفته | تریگرهای deferred ۰۵ و ۰۷ آن را می‌خوانند | ۰۲ | باز (متن) |
| 05:CR-C12 | تجارت | `import_hook` هر ماژول پس از COPY | پذیرفته | R-IMPORT | ۰۲ | باز |
| 07:CR-CMP-06 | انطباق | `doc_type='tax.moadian_serial'`؛ `number_record_external`، `number_void` و `number_issued` قرارداد بمانند | پذیرفته | — | ۰۲ | باز |
| 07:CR-CMP-17 | انطباق | کلید `retention.accounting_records.years` در ۰۷ | پذیرفته | اطمینان پایین، تا پاسخ Q-CMP-13 | ۰۷ | انجام‌شده |
| 07:CR-CMP-20 | انطباق | بررسی‌های درون‌ریزی `.hkx` (بستهٔ قواعد، مهر دوبارهٔ کلید، کنترل دارایی) | پذیرفته | R-IMPORT | ۰۲ | باز |
| 08:CR-MG04 | مهاجرت | پیشوند `t/<tenant>/migration/` در پاک‌سازی و صدور؛ GUC `hk.migration_purge` | پذیرفته | سقف ۱ گیگابایتی پیوست برای بکاپ کافی نیست | ۰۲ | باز |
| 08:CR-MG05 | مهاجرت | رد صدور `.hkx` هنگام `committing` یا `rolling_back` | پذیرفته با سازوکار عمومی | core نمی‌تواند migration را بخواند (DAG). core رجیستری «مانع صدور» می‌سازد و migration در آن ثبت می‌کند | ۰۲ / ۰۸ | باز |
| 08:CR-MG08 | مهاجرت | `cell_cap` اختیاری روی `core.job_queue` | پذیرفته (v1.1) | تا آن زمان پیکربندی worker | ۰۲ | به تعویق |
| 06:CR-T03 | خزانه | `'edge'` در `core.device.kind` | پذیرفته برای v2 | تا آن زمان کلید خود `pos.edge_node` | ۰۲ | به تعویق (v2) |
| 06:CR-T05 | خزانه | بُعد دامنهٔ `bank_account` | پذیرفته برای v1.1 | تا آن زمان دامنهٔ شرکت و شعبه | ۰۲ | به تعویق (v1.1) |
| 09:CR-PLT-04 | پلتفرم | مجوز `core.billing.manage` و assertion پرتال صورتحساب | پذیرفته | — | ۰۲ | باز |
| 09:CR-PLT-05 | پلتفرم | رویدادهای uplink | پذیرفته | — | ۰۲ | باز |
| 09:CR-PLT-06 | پلتفرم | توقف پیامک خط پلتفرم در سقف اعتبار (OTP و امنیتی معاف) | سازوکار پذیرفته | سیاست قطع سرویس تصمیم محصولی است | ۰۲ | پرسش صاحب محصول |
| 02:۱۳.۱–۱۶ | هسته | (بندهای دیگر) | — | در جدول‌های ۱ و ۲ | — | — |
| RV-IT-15 | یکپارچه‌ساز | حذف `CREATE ROLE hk_dispatcher LOGIN PASSWORD 'hk_dispatcher'` و بلوک‌های نقش از 10_core | پذیرفته | R-ROLE | ۰۲ | باز |

## ۵. دفتر کل (`03-ledger.md`، `20_ledger.sql`)

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 03:C-L07 | دفتر کل | ترتیب فایل‌ها مطابق DAG؛ `name_search` مولد | ۱۰ پیش‌نیاز: پذیرفته؛ تغییر نام فایل: به تعویق | R-ORDER | ۰۳ | باز |
| 03:C-L09 | دفتر کل | نگهبان تغییر `core.company.base_currency` | پذیرفته؛ مالک اجرا ledger | نگهبانی که سال مالی را می‌خواند مال ledger است (جهت DAG). تریگر روی `core.company` در 20_ledger، با گریز `hk.redenomination` | ۰۳ | باز (RV-IT-03) |
| 03:C-L14 | دفتر کل | `reversed` مشتق است | پذیرفته | D-L04 | — | انجام‌شده |
| 03:C-L15 | دفتر کل | اسکیمای تسعیر در v1، فعال‌سازی v2 | پذیرفته (اسکیما) | فعال‌سازی زودتر برای واردکنندگان تصمیم محصولی است | ۰۳ | پرسش صاحب محصول |
| 04:CR-04 | دادهٔ پایه | `ensure_value` تنبل در همان تراکنش `ledger.post` | پذیرفته | فاکتور ثانیه‌ای پس از ساخت مشتری نباید شکست بخورد | ۰۳ | باز |
| 04:CR-05 | دادهٔ پایه | بُعد `party` به‌جای `employee` | پذیرفته | یک کارت برای هر شخص. 07:CR-CMP-03 هم موافق است. هنوز در `dimension_type_catalog` است | ۰۳ / ۰۷ | باز |
| 05:CR-C06 | تجارت | مالک اقلام باز فقط treasury؛ اصلاح متن §۲ ۰۳ | پذیرفته | — | ۰۳ | باز (متن) |
| 05:CR-C11 | تجارت | `v_journal_line` منتشرشده؛ `opening_import` موجودی؛ هشدار coverage؛ `BalanceQuery.party_balance` | پذیرفته | — | ۰۳ | باز |
| 05:CR-C13 | تجارت | ترتیب بستن سال ← تبدیل زیردفتر ← افتتاحیه | پذیرفته (v2) | حذف چهار صفر | ۰۳ | به تعویق (v2) |
| 06:CR-T02 | خزانه | حساب قالب و قاعدهٔ پیش‌فرض برای ده کلید ثبت | پذیرفته | بدون نگاشت، ثبت آن رویدادها شکست می‌خورد | ۰۳ | باز |
| 06:CR-T07 | خزانه | کلید `sales.service_charge` | پذیرفته | ۰۵ کلید را ثبت کند و ۰۳ حساب قالب بدهد | ۰۵ / ۰۳ | باز |
| 06:CR-T10 | خزانه | تغییر نام بُعد `pos_terminal` به `card_terminal` | پذیرفته | ابهام با بُعد دامنهٔ مجوز core. پیش از انجماد v1 | ۰۳ / ۰۶ | باز |
| 07:CR-CMP-03 | انطباق | `3205` و `4102` با بُعد `party`؛ ۱۸ کلید تازه در قالب | پذیرفته | همان CR-05 و CR-T02 | ۰۳ | باز |
| 07:CR-CMP-15 | انطباق | ضریب حذف صفر در قواعد | پذیرفته | — | ۰۷ | انجام‌شده |
| 07:CR-CMP-16 | انطباق | `ledger.eledger_export` قالب را نگه دارد | پذیرفته | ستون‌های `format_rule_key` و `format_version` موجودند | ۰۳ | انجام‌شده |
| 08:CR-MG03 | مهاجرت | ثبت `opening_import` و `history_import` مهاجرت روی حساب کنترل؛ `reset_opening`؛ `source_doc_type`ها | پذیرفته | — | ۰۳ | باز |
| 08:CR-MG18 | مهاجرت | مهاجرت تجمیع نمی‌کند | پذیرفته | با C-L16 تعارضی ندارد | — | انجام‌شده |
| 03:(مشاهده) | دفتر کل | ۳۹ یافتهٔ lint در `catalog` و `parties` | — | جدول ۶، RV-IT-01 | ۰۴ | — |
| RV-IT-16 | یکپارچه‌ساز | T00 آزمون ledger «۹ نوع بُعد» را سخت‌کد کرده است | پذیرفته | روی پایگاه یکپارچه ۱۰ نوع است (`payment_gateway` از ۰۶) | ۰۳ | باز |

## ۶. دادهٔ پایه (`04-masterdata.md`، `25_masterdata.sql`)

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 04:CR-03 | دادهٔ پایه | 10 پیش‌نیاز و حذف shim `core.fa_*` | پذیرفته | R-ORDER. یک مالک برای fa-norm | ۰۴ (+ هارنس) | باز |
| 04:CR-07 | دادهٔ پایه | تغییر نام به `15_masterdata.sql` | به تعویق | R-ORDER | ۰۴ | به تعویق |
| 04:CR-08 | دادهٔ پایه | کاتالوگ سراسری `rules.tax_category` | پذیرفته | ۰۷ ساخت (CR-CMP-13). سه FK در 99 | ۰۷ / یکپارچه‌ساز | انجام‌شده |
| 04:C-01 | دادهٔ پایه | سری کد شخص و کالا جدا از شماره‌گذاری اسناد | پذیرفته | دادهٔ پایه بی‌فاصله نیست | — | انجام‌شده |
| 05:CR-C14 | تجارت | ۳۹ جدول بیرون از `export_table_registry` | پذیرفته | R-EXPORT. INV-TEN-07 روی پایگاه یکپارچه نقض است | ۰۴ | باز (RV-IT-01) |
| 06:CR-T15 / 08:CR-MG20 | خزانه، مهاجرت | همان | پذیرفته | همان | ۰۴ | باز (RV-IT-01) |
| 05:CR-C08 | تجارت | `warranty_days` و `warranty_basis` در `catalog.v_sku` | پذیرفته | هنوز نیست | ۰۴ | باز |
| 05:CR-C10 | تجارت | تشخیص ویرایش کاربر با `content_sha256` | پذیرفته | `row_version` مثبت کاذب می‌دهد | ۰۴ | باز |
| 08:CR-MG09 | مهاجرت | `run_id` ← `job_id`؛ یک مفهوم برای `source_scope/source_db`؛ `deactivate_if_unused` | پذیرفته | R-GLOSSARY | ۰۴ | باز |
| 10:C-AS-10 | دستیار | مجوزهای parties و catalog در `core.permission` | پذیرفته | هیچ مجوز `parties.*` و `catalog.*` و هیچ `field_guard` آن‌ها ثبت نشده است | ۰۴ | باز (RV-IT-02) |
| RV-IT-CUSTOM | یکپارچه‌ساز | ثبت `custom_field_entity` و `core.attach_custom_fields` برای `parties.party` و `catalog.item` | پذیرفته | فعلاً در 99 (بند ۶) اجرا می‌شود. پس از R-ORDER به 25 منتقل شود | ۰۴ | باز |

## ۷. تجارت (`05-commerce.md`، `30_commerce.sql`)

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 04:CR-06 | دادهٔ پایه | `parties.child_party_guard` روی جدول‌های تغییرپذیر | پذیرفته | ۰۶ و ۰۷ گذاشته‌اند؛ 30_commerce هیچ‌کدام. فاکتور پیش‌نویس برای شخص ادغام‌شده پذیرفته می‌شود | ۰۵ | باز (RV-IT-04) |
| 05:CR-C01 | تجارت | جدول‌های بستهٔ صنفی در `rules` | پذیرفته | ۰۷ ساخت (CR-CMP-19) | ۰۷ | انجام‌شده |
| 05:CR-C05 | تجارت | `pos.ticket.sales_doc_id → sales.invoice`؛ گرد کردن قطع | پذیرفته | CR-T04. FK سه‌ستونی در 99 | ۰۶ / یکپارچه‌ساز | انجام‌شده |
| 05:CR-C09 | تجارت | قرارداد `TaxCalculator` و `TaxDocumentService` | پذیرفته | CR-CMP-04 | ۰۷ | انجام‌شده |
| 06:CR-T06 | خزانه | `post_shift_batch` برای `per_shift`؛ FK معکوس `pos.shift.gl_batch_id` | پذیرفته (v1.1) | — | ۰۵ / ۰۶ | به تعویق (v1.1) |
| 06:CR-T08 | خزانه | ثبت قلم باز در همان تراکنش | پذیرفته | — | ۰۵ / ۰۷ | انجام‌شده (۰۵ پذیرفته)؛ ۰۷ انجام‌شده |
| 06:CR-T16 | خزانه | یک نسخه از FKهای `pos → inventory/sales` | پذیرفته | R-XFK بند ۱: سه‌ستونی | یکپارچه‌ساز | انجام‌شده |
| 07:CR-CMP-04 | انطباق | `tax_snapshot` با شناسهٔ `calc_snapshot`؛ `update_moadian_match`؛ سطر دارایی به `assets.disposal_clearing` | پذیرفته | — | ۰۵ | باز |
| 08:CR-MG01 | مهاجرت | افتتاحیهٔ موجودی مهاجرت بی‌GL (`gl_effect='none'`)؛ کلید idempotency = lineage | پذیرفته | قاعدهٔ یکسان: افتتاحیهٔ زیردفترها از مهاجرت بی‌GL است و GL فقط از سند `opening_import` مهاجرت می‌آید (مانند ۰۶ D-T12) | ۰۵ | باز |
| 08:CR-MG15 | مهاجرت | `history` با `per_document` در دورهٔ باز گذشته؛ `cancel_history` | پذیرفته | — | ۰۵ | باز |
| 10:C-AS-12 | دستیار | ستون `origin` در `purchase."order"` و `PurchaseOrderService.validate/create_draft` | پذیرفته | هم‌شکل `ledger.journal_draft.created_via` و `treasury.money_document.origin` | ۰۵ | باز |
| 10:C-AS-19 | دستیار | بخش اختیاری `assistant` در `hkpack/1` | پذیرفته | فقط اعتبارسنج، بدون Applier | ۰۵ / ۰۷ | باز |
| RV-IT-SALESTAX | یکپارچه‌ساز | دو اشارهٔ مستقل `sales.invoice.tax_document_id` و `tax.invoice.sales_invoice_id` | پذیرفته | 99 FK سه‌ستونی دارد، ولی هم‌خوانی دوطرفه تضمین نمی‌شود. جدول ۹ | ۰۷ | باز |

## ۸. خزانه و صندوق (`06-treasury-pos.md`، `40_treasury_pos.sql`)

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 06:CR-T01 | خزانه | `ecdsa_p256` در کنار `ed25519` | پذیرفته | اطلاعی؛ WebCrypto | — | انجام‌شده |
| 06:CR-T04 | خزانه | `line_rounding='truncate'` و FK سه‌ستونی | پذیرفته | پاسخ CR-C05 | ۰۶ | انجام‌شده |
| 06:CR-T09 | خزانه | نام‌های `tax.memory` و `tax.invoice`، `TaxOfflineService`، پارامتر مهلت | پذیرفته؛ نام پارامتر = `tax.moadian.send_deadline_days` | ۰۷ مالک پارامترهای مؤدیان است (CR-CMP-05). 06:450 هنوز نام قدیمی دارد | ۰۶ | باز (RV-IT-11) |
| 06:CR-T13 | خزانه | یکتایی `(provider, provider_ref)` در هر مستأجر | پذیرفته | یکتایی سراسری با RLS نشت‌زاست | — | انجام‌شده |
| 06:CR-T14 | خزانه | ۵۱ ردیف کاتالوگ گذار چک | پذیرفته | اطلاعی، مطابق پژوهش ۰۵ | — | انجام‌شده |
| 07:CR-CMP-05 | انطباق | FKهای سه‌ستونی `pos → tax` | پذیرفته | R-XFK بند ۱ | یکپارچه‌ساز | انجام‌شده |
| 07:CR-CMP-12 | انطباق | قلم باز خالص حقوق | پذیرفته | — | ۰۷ | انجام‌شده |
| 08:CR-MG02 | مهاجرت | `source_module='migration'` بی‌سند؛ `TreasuryImportService.*`؛ `import_cheque_history` | پذیرفته (`import_cheque_history` در v2) | CHECK `source_module` الگوی آزاد دارد و `migration` را می‌پذیرد | ۰۶ | باز (سرویس‌ها) |
| 10:C-AS-09 | دستیار | `PartyReminderService` و مجوز `treasury.reminder.send` | پذیرفته | فقط با رضایت ثبت‌شدهٔ شخص | ۰۶ | باز |
| 10:C-AS-17 | دستیار | تغییر نام `INV-SEC-*` و `INV-EDGE-*` در ۰۶ | پذیرفته | R-INV: `INV-POSSEC-*` و `INV-POSEDGE-*` | ۰۶ | باز (RV-IT-09) |
| RV-ARCH-08 | بازبینی | FK `pos.cash_movement.posting_key → ledger.posting_key` با «pos در DAG به ledger وابسته نیست» (06:41) نمی‌خواند | FK می‌ماند و استثنای برچسب‌دار R-XFK بند ۵ شد. `ledger` به `pos.depends_on` افزوده **نمی‌شود** | فقط وجود کد در کاتالوگ سراسری تضمین می‌شود؛ تضمین import (INV-POS-14) سالم می‌ماند. 99 قید موجود را با `hk_add_fk` («هم‌ارز») برچسب می‌زند | ۰۶ | انجام‌شده (99)؛ باز (متن ۰۶: سطر ۴۱ و §۱۲؛ اختیاری: نام R-XFK-3 `fk_cash_movement__ledger_posting_key` در 40) |

## ۹. انطباق (`07-compliance.md`، `50_compliance.sql`)

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 07:CR-CMP-13 | انطباق | شکل `rules.tax_category` با تفاوت (اعتبار روی مقدار نرخ) | پذیرفته | اعتبار و منبع مال مقدار نرخ است | ۰۷ | انجام‌شده |
| 07:CR-CMP-14 | انطباق | صندوق ورودی Excel کارپوشه در ۰۵ | پذیرفته | — | ۰۵ | انجام‌شده |
| 07:CR-CMP-19 | انطباق | جدول‌های بستهٔ صنفی ساخته شد | پذیرفته | — | ۰۷ | انجام‌شده |
| 08:CR-MG11 | مهاجرت | `TaxImportService` (`set_continuity`، `import_invoice_history`، `revert_continuity`) | پذیرفته | — | ۰۷ | باز |
| 08:CR-MG12 | مهاجرت | `PayrollImportService` | پذیرفته | — | ۰۷ | باز |
| 08:CR-MG13 | مهاجرت | `AssetImportService(gl_effect='none')` | پذیرفته | قاعدهٔ CR-MG01 | ۰۷ | باز |
| 08:CR-MG22 | مهاجرت | `lpad` در `tax.taxid_control_string` رقم را کوتاه می‌کند؛ ادغام فایل بردار | پذیرفته | روی پایگاه یکپارچه بازتولید شد | ۰۷ | باز (RV-IT-12) |
| 09:CR-PLT-08 | پلتفرم | `support_until ≥ published_at` برای `.hkrules` با `distribution='support_required'` | به تعویق | گره زدن به‌روزرسانی پارامتر قانونی به پشتیبانی پولی تصمیم محصولی و حقوقی است | ۰۷ / ۰۹ | پرسش صاحب محصول |
| 09:CR-PLT-09 | پلتفرم | کلید نشانگر `ref.<table>.snapshot` در `rules.param_def` | پذیرفته | دروازهٔ یکسان برای بستهٔ مرجع | ۰۷ | باز |
| 10:C-AS-08 | دستیار | `payroll.report.read` و `PayrollQuery.cost_summary` تجمیعی | پذیرفته | بدون دادهٔ فردی | ۰۷ | باز |
| 10:C-AS-19 | دستیار | `rules.PackQuery.active_packs/manifest_section` | پذیرفته | فقط‌خواندنی | ۰۷ | باز |
| RV-IT-SALESTAX | یکپارچه‌ساز | `UNIQUE (tenant_id, company_id, id, sales_invoice_id)` روی `tax.invoice` تا 99 اشارهٔ دوطرفه را با FK چهارستونی ببندد | پذیرفته | اکنون فاکتور فروش A می‌تواند به سند مالیاتی فاکتور B اشاره کند | ۰۷ (+ یکپارچه‌ساز) | باز |

## ۱۰. مهاجرت (`08-migration.md`، `60_migration.sql`)

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 08:§۱۲ (اختیاری) | مهاجرت | ستون‌های تایپ‌شدهٔ `stock_doc_id`، `cheque_id` و `open_item_id` در `migration.posting` با FK | رد | ارجاع چندریختی با `doc_count` و lineage تطبیق می‌شود. 99 ستون نمی‌سازد | — | انجام‌شده (رد) |
| 09:CR-PLT-07 | پلتفرم | مسیر `/api/v1/migration/*` روی مبدأ admin؛ `assisted_migration_order` = `service_order` | پذیرفته | قرارداد `/api/v1` | ۰۸ | باز (متن) |
| 10:C-AS-14 | دستیار | پیشنهاد نگاشت از `LlmCompletionPort` | پذیرفته | R-AI بند ۲ | ۰۸ | باز |

## ۱۱. پلتفرم مالک (`09-owner-platform.md`، `70_platform.sql`)

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 07:CR-CMP-11 | انطباق | الزامات تألیف بستهٔ قواعد | پذیرفته | — | ۰۹ | باز (تأیید پوشش) |
| 07:CR-CMP-21 | انطباق | هشدار استفادهٔ یک حافظهٔ مؤدیان در دو مستأجر با hash شناسه | پذیرفته | فقط hash، بدون دادهٔ شخصی | ۰۹ / ۰۲ | باز |
| 08:CR-MG10 | مهاجرت | جدول‌های مهاجرت در صفحهٔ کنترل، اشتراک uplink، مجوز و payload | پذیرفته با نگاشت CR-PLT-07 | `assisted_migration_order` همان `service_order` است | ۰۹ | باز |
| 10:C-AS-07 | دستیار | گسترش `ai_provider` و جدول‌های AI | پذیرفته | CR-PLT-10 | ۰۹ | انجام‌شده |
| RV-IT-14 | یکپارچه‌ساز | نقش‌های `hk_platform_*` با `LOGIN PASSWORD` ثابت | پذیرفته | R-ROLE | ۰۹ | باز |
| RV-IT-08 | یکپارچه‌ساز | `key_reused` ← ۴۲۲ | پذیرفته | R-IDEM | ۰۹ | باز |

## ۱۲. دستیار (`10-assistant.md`، `80_assistant.sql`)

| شناسه | از بخش | درخواست | تصمیم | دلیل | مسئول اجرا | وضعیت |
|---|---|---|---|---|---|---|
| 09:CR-PLT-10 | پلتفرم | `CellAssistantPolicy` بلوکی از `hkcellstate/1`؛ «خاموش آزاد، روشن با تأیید» | پذیرفته | یک امضا و یک pull | ۱۰ | باز (متن ۱۰) |
| RV-IT-10 | یکپارچه‌ساز | `INV-AST-*` ← `INV-AI-*` | پذیرفته | R-INV | ۱۰ | باز |

---

## پرسش‌های صاحب محصول (تصمیم محصولی؛ تصمیم‌گیری نشد)

1. **کمینهٔ ویندوز عامل مهاجرت (08:CR-MG07).**
   - عامل انتقال داده روی ماشینی اجرا می‌شود که نرم‌افزار قبلی (هلو، سپیدار، …) روی آن است. Python 3.13 روی Windows 7 اجرا نمی‌شود.
   - آیا کمینهٔ «Windows 10 یا Server 2016» پذیرفته است، با این راه جایگزین برای ماشین‌های قدیمی‌تر: «بارگذاری دستی فایل بکاپ»؟
2. **به‌روزرسانی قواعد قانونی در نسخهٔ نصبی (09:CR-PLT-08).**
   - آیا بستهٔ قواعد قانونی (نرخ‌ها و پارامترهای مالیات، بیمه و حقوق) برای مشتری On-prem فقط با پشتیبانی فعال ارائه شود؟
   - در آن صورت، مشتری بدون تمدید با پارامتر قدیمی محاسبه می‌کند.
3. **شرکت تمرینی برای تمرین بی‌اثر مهاجرت (08:CR-MG14).**
   - آیا چنین شرکتی در شمار شرکت‌های پلن حساب شود؟
   - مستثنا شدن آن از ارسال مؤدیان و دفاتر الکترونیکی در هر حال الزامی است.
4. **زمان فعال‌سازی تسعیر ارز (03:C-L15).** آیا تسعیر ارز برای واردکنندگان (مثلاً کالای برق) در نسخهٔ ۱ فعال شود، یا مطابق پژوهش در نسخهٔ ۲؟ اسکیما آماده است.
5. **سقف اعتبار پیامک (09:CR-PLT-06).** آیا ارسال پیامک خط پلتفرم با تمام شدن اعتبار خریداری‌شده قطع شود؟ OTP و پیام‌های امنیتی معاف‌اند.

---

## نتیجهٔ هارنس (`PREFIX=fx_integration docs/design/sql/run_all.sh`، پس از رفع RV-ARCH-08)

- **(a) زنجیرهٔ مستقل هر بخش:** هر ۹ بخش دارای SQL زنجیره و آزمونشان سبز است. اعمال دوبارهٔ `70_platform.sql` هم سبز است. جمع: `PASS=72 FAIL=4 SKIP=0`. هر چهار FAIL یافتهٔ باز بخش‌های دیگرند (پایین).
- **(b) پایگاه یکپارچه:**
  - زنجیرهٔ 00 تا 80 و `99_cross_fk.sql` سبز است:
    - ۵۴ FK افزوده شد؛
    - ۹ FK برچسب استثنای DAG دارند: ۸ مورد پیشین به‌اضافهٔ `pos.cash_movement → ledger.posting_key`؛
    - خودآزمایی `HK_XFK_DAG` بر پایهٔ `core.xfk_dag_violations()` صفر مورد دارد.
  - `core.security_lint()` قرمز است: ۳۹ ردیف `tenant_table_not_in_export_registry` در `catalog` و `parties` (RV-IT-01، مسئول ۰۴). این ردیف‌ها عمداً در allowlist نیامده‌اند.
  - lint تکمیلی هارنس روی همهٔ اسکیماها صفر است.
  - `tests/99_integration_test.sql`: ۱۰۳ از ۱۲۹ بررسی سبز است. پنج بررسی DAG تازه (`A2.cross_schema_fks_follow_dag`، `A2.dag_registry_matches_schemas`، `A2.dag_registry_is_layered_dag`، `A2.dag_exceptions_match_rulings`، `A2.dag_lint_flags_same_layer_upward_and_undeclared`) سبزند. روی 99 پیش از رفع، دو بررسی اول و چهارم قرمز می‌شوند. ۲۶ بررسی قرمز همه یافته‌های باز بخش‌های دیگرند، با شناسه و مسئول در گزارش:
    - RV-IT-01 (۰۴)؛
    - RV-IT-05، RV-IT2-07، RV-IT2-08، RV-IT2-12 (۰۲)؛
    - RV-IT2-03 (۰۳)؛
    - RV-IT2-01، RV-IT2-06، RV-IT2-09 (۰۵)؛
    - RV-IT2-04، RV-IT2-05، RV-IT2-10، RV-IT2-11 (۰۶)؛
    - RV-IT-SALESTAX (۰۷).
- **(c) ترتیب دوم:** ترتیب `00,10,25,20,…,99` سبز است، جز همان lint.
- **(d) idempotency:** اعمال دوبارهٔ همهٔ فایل‌ها روی پایگاه یکپارچه سبز است. 99 در هر سه اجرا همان قید موجود 40 را با برچسب `fk_cash_movement__ledger_posting_key` («هم‌ارز») پذیرفت.
- **اختیاری `INTEGRATED_TESTS=1`** (اجرای پیشین `it_`؛ این بار اجرا نشد): آزمون هر بخش روی کپی پایگاه یکپارچهٔ دارای 99.
  - masterdata، commerce، migration و assistant سبز بودند.
  - core قرمز بود: `security_lint is empty`، به‌خاطر RV-IT-01.
  - ledger قرمز بود: RV-IT-16.
  - treasury_pos و compliance قرمز بودند، چون fixtureهایشان شناسهٔ ساختگی بین‌ماژولی دارند: `sales_doc_id = uuidv7()` و `workshop_ref` ساختگی. FKهای 99 درست همین را رد می‌کنند. پوشش بین‌ماژولی کار `tests/99_integration_test.sql` است.
