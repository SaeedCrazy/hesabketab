-- =====================================================================
-- حساب‌کتاب — 30_commerce.sql   (سند طراحی: docs/design/05-commerce.md)
-- بازرگانی: انبار و ارزیابی (inventory)، فروش (sales)، خرید (purchase).
--
-- پیش‌نیاز (به همین ترتیب): 00_foundation.sql → 10_core.sql → 20_ledger.sql → 25_masterdata.sql.
-- اجرا با نقش migrator/superuser روی پایگاه دادهٔ UTF8.
-- قواعد مشترک: PK = id uuid DEFAULT uuidv7()؛ هر جدول مستأجری tenant_id NOT NULL،
-- UNIQUE (tenant_id, id) و core.enable_tenant_rls؛ ارجاع بین جدول‌های مستأجری همیشه FK ترکیبی
-- (tenant_id, x_id). ارجاع به ماژول‌های بیرون از وابستگی‌ها (treasury، tax، rules، pos) فقط ستون uuid
-- است و FKهایشان در سند §۱۲ آمده‌اند (99_cross_fk.sql).
--
-- موتور ارزیابی (inventory) در پایگاه داده است: درج stock_move با تریگر ارزیابی می‌شود؛ لایه‌های
-- ارزش (valuation_layer) و وضعیت‌های مشتق (cost_pool، fifo_layer، stock_balance، pool_checkpoint)
-- فقط با توابع SECURITY DEFINER مالکِ hk_inventory_definer نوشته می‌شوند. hk_app روی آن‌ها فقط SELECT دارد.
-- =====================================================================

-- ---------- پیش‌شرط‌ها ----------
DO $$
BEGIN
  IF current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'HK_ENCODING: data-plane database must be UTF8 (found %)', current_setting('server_encoding');
  END IF;
  IF to_regprocedure('core.number_next(uuid,text,text,text,uuid)') IS NULL
     OR to_regclass('ledger.journal') IS NULL OR to_regclass('catalog.item_variant') IS NULL THEN
    RAISE EXCEPTION 'HK_PREREQ: apply 10_core.sql, 20_ledger.sql and 25_masterdata.sql first';
  END IF;
END $$;

-- ---------- نقش مالک توابع definer موتور ارزیابی (NOLOGIN، NOBYPASSRLS؛ درخواست انتقال به foundation در §۱۳) ----------
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_inventory_definer') THEN
    CREATE ROLE hk_inventory_definer NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
END $$;
GRANT USAGE ON SCHEMA core, ref, ledger, catalog, parties, inventory TO hk_inventory_definer;

-- ترتیب سراسری حرکت‌های انبار (فقط ترتیب؛ پس از درون‌ریزی .hkx با setval هم‌تراز می‌شود)
CREATE SEQUENCE IF NOT EXISTS inventory.posting_seq AS bigint;

-- =====================================================================
-- ۱. inventory — پیکربندی
-- =====================================================================

-- سیاست موجودی شرکت (تاریخ‌دار). v1: روش ارزیابی و دامنهٔ استخر پس از اولین حرکت ثابت‌اند؛
-- فقط حالت دائمی/ادواری می‌تواند در ردیف تازه از آغاز سال مالی بعد عوض شود.
CREATE TABLE IF NOT EXISTS inventory.company_policy (
  tenant_id                uuid NOT NULL REFERENCES core.tenant(id),
  id                       uuid NOT NULL DEFAULT uuidv7(),
  company_id               uuid NOT NULL,
  effective_from           date NOT NULL,
  valuation_method         text NOT NULL DEFAULT 'moving_average' CHECK (valuation_method IN ('moving_average','fifo')),
  inventory_mode           text NOT NULL DEFAULT 'perpetual' CHECK (inventory_mode IN ('perpetual','periodic')),
  cost_pool_scope          text NOT NULL DEFAULT 'company' CHECK (cost_pool_scope IN ('company','warehouse')),
  negative_stock_default   text NOT NULL DEFAULT 'allow_warn' CHECK (negative_stock_default IN ('allow','allow_warn','block')),
  price_difference_policy  text NOT NULL DEFAULT 'revalue_stock' CHECK (price_difference_policy IN ('revalue_stock','price_difference_account')),
  source_pack              text,
  source_pack_version      text,
  created_by               uuid,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  row_version              integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, effective_from),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((source_pack IS NULL) = (source_pack_version IS NULL))
);
SELECT core.enable_tenant_rls('inventory.company_policy');

CREATE TABLE IF NOT EXISTS inventory.warehouse (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid NOT NULL,
  branch_id            uuid,
  code                 text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'),
  name                 text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  name_search          text GENERATED ALWAYS AS (core.fa_search_key(name)) STORED,
  kind                 text NOT NULL DEFAULT 'standard' CHECK (kind IN ('standard','transit')),
  negative_policy      text NOT NULL DEFAULT 'inherit' CHECK (negative_policy IN ('inherit','allow','allow_warn','block')),
  is_default_transit   boolean NOT NULL DEFAULT false,
  is_active            boolean NOT NULL DEFAULT true,
  address              text CHECK (address = core.fa_normalize_text(address)),
  source_pack          text,
  source_pack_version  text,
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
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT warehouse_branch_required CHECK (kind = 'transit' OR branch_id IS NOT NULL),
  CONSTRAINT warehouse_transit_blocks_negative CHECK (kind <> 'transit' OR negative_policy = 'block'),
  CONSTRAINT warehouse_default_transit_kind CHECK (NOT is_default_transit OR kind = 'transit'),
  CHECK ((source_pack IS NULL) = (source_pack_version IS NULL))
);
SELECT core.enable_tenant_rls('inventory.warehouse');
CREATE UNIQUE INDEX IF NOT EXISTS warehouse_one_default_transit ON inventory.warehouse (tenant_id, company_id)
  WHERE is_default_transit AND is_active;

-- مکان/قفسه (v2؛ مدل داده آماده)
CREATE TABLE IF NOT EXISTS inventory.location (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  company_id    uuid NOT NULL,
  warehouse_id  uuid NOT NULL,
  parent_id     uuid,
  code          text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'),
  name          text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 120),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, warehouse_id, id),
  UNIQUE (tenant_id, warehouse_id, code),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, warehouse_id, parent_id) REFERENCES inventory.location(tenant_id, warehouse_id, id),
  CHECK (parent_id IS NULL OR parent_id <> id)
);
SELECT core.enable_tenant_rls('inventory.location');

-- انبار پیش‌فرض هر شعبه (فروش، دریافت، مصرف دستور پخت)
CREATE TABLE IF NOT EXISTS inventory.branch_default (
  tenant_id                 uuid NOT NULL REFERENCES core.tenant(id),
  id                        uuid NOT NULL DEFAULT uuidv7(),
  company_id                uuid NOT NULL,
  branch_id                 uuid NOT NULL,
  sales_warehouse_id        uuid,
  receipt_warehouse_id      uuid,
  consumption_warehouse_id  uuid,
  updated_at                timestamptz NOT NULL DEFAULT now(),
  row_version               integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, branch_id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, sales_warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, receipt_warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, consumption_warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id)
);
SELECT core.enable_tenant_rls('inventory.branch_default');

-- حداقل/حداکثر موجودی (v1 هشدار؛ v2 پیشنهاد سفارش)
CREATE TABLE IF NOT EXISTS inventory.reorder_rule (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  company_id    uuid NOT NULL,
  warehouse_id  uuid NOT NULL,
  item_id       uuid NOT NULL,
  variant_id    uuid NOT NULL,
  min_qty       core.qty NOT NULL CHECK (min_qty >= 0),
  max_qty       core.qty,
  reorder_qty   core.qty CHECK (reorder_qty > 0),
  is_active     boolean NOT NULL DEFAULT true,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, warehouse_id, variant_id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  CHECK (max_qty IS NULL OR max_qty >= min_qty)
);
SELECT core.enable_tenant_rls('inventory.reorder_rule');

-- =====================================================================
-- ۲. inventory — بچ، سریال، bundle ردیابی
-- =====================================================================
CREATE TABLE IF NOT EXISTS inventory.batch (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  item_id            uuid NOT NULL,
  variant_id         uuid,
  batch_no           text NOT NULL CHECK (batch_no = core.fa_normalize_ident(batch_no) AND char_length(batch_no) BETWEEN 1 AND 60),
  mfg_date           date,
  expiry_date        date,
  supplier_party_id  uuid,
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','blocked','recalled')),
  notes              text CHECK (notes = core.fa_normalize_text(notes)),
  created_by         uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, item_id, id),
  UNIQUE (tenant_id, item_id, batch_no),
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, supplier_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (expiry_date IS NULL OR mfg_date IS NULL OR expiry_date >= mfg_date)
);
SELECT core.enable_tenant_rls('inventory.batch');
CREATE INDEX IF NOT EXISTS batch_expiry_idx ON inventory.batch (tenant_id, item_id, expiry_date) WHERE status = 'active';

-- سریال: وضعیت جاری فقط با تریگر serial_move (definer) تغییر می‌کند.
CREATE TABLE IF NOT EXISTS inventory.serial (
  tenant_id                   uuid NOT NULL REFERENCES core.tenant(id),
  id                          uuid NOT NULL DEFAULT uuidv7(),
  item_id                     uuid NOT NULL,
  variant_id                  uuid NOT NULL,
  serial_no                   text NOT NULL CHECK (serial_no = core.fa_normalize_ident(serial_no) AND char_length(serial_no) BETWEEN 1 AND 80),
  batch_id                    uuid,
  status                      text NOT NULL DEFAULT 'registered' CHECK (status IN ('registered','in_stock','out')),
  company_id                  uuid,
  warehouse_id                uuid,
  last_move_id                uuid,
  last_move_kind              text,
  warranty_start              date,
  warranty_end                date,
  warranty_provider_party_id  uuid,
  sold_to_party_id            uuid,
  notes                       text CHECK (notes = core.fa_normalize_text(notes)),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  row_version                 integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, item_id, id),
  UNIQUE (tenant_id, item_id, serial_no),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, batch_id) REFERENCES inventory.batch(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, warranty_provider_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, sold_to_party_id) REFERENCES parties.party(tenant_id, id),
  CONSTRAINT serial_location_shape CHECK ((status = 'in_stock') = (warehouse_id IS NOT NULL)),
  CONSTRAINT serial_company_shape CHECK (warehouse_id IS NULL OR company_id IS NOT NULL),
  CONSTRAINT serial_warranty_shape CHECK (warranty_end IS NULL OR (warranty_start IS NOT NULL AND warranty_end >= warranty_start))
);
SELECT core.enable_tenant_rls('inventory.serial');
CREATE INDEX IF NOT EXISTS serial_location_idx ON inventory.serial (tenant_id, warehouse_id, variant_id) WHERE status = 'in_stock';

-- bundle ردیابی (سریال/بچ جدا از سطر سند؛ الگوی Serial and Batch Bundle)
CREATE TABLE IF NOT EXISTS inventory.tracking_bundle (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  item_id          uuid NOT NULL,
  variant_id       uuid NOT NULL,
  warehouse_id     uuid NOT NULL,
  direction        text NOT NULL CHECK (direction IN ('in','out')),
  total_qty_base   core.qty NOT NULL CHECK (total_qty_base > 0),
  status           text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','cancelled')),
  source_module    text CHECK (source_module ~ '^[a-z][a-z0-9_]{1,30}$'),
  source_doc_type  text CHECK (source_doc_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  source_doc_id    uuid,
  source_line_id   uuid,
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((source_doc_type IS NULL) = (source_doc_id IS NULL)),
  CHECK (status = 'draft' OR source_doc_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('inventory.tracking_bundle');

CREATE TABLE IF NOT EXISTS inventory.tracking_bundle_entry (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  bundle_id         uuid NOT NULL,
  serial_id         uuid,
  serial_no         text CHECK (serial_no = core.fa_normalize_ident(serial_no) AND char_length(serial_no) BETWEEN 1 AND 80),
  batch_id          uuid,
  new_batch_no      text CHECK (new_batch_no = core.fa_normalize_ident(new_batch_no) AND char_length(new_batch_no) BETWEEN 1 AND 60),
  new_batch_mfg     date,
  new_batch_expiry  date,
  qty_base          core.qty NOT NULL CHECK (qty_base > 0),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, bundle_id, serial_id),
  UNIQUE (tenant_id, bundle_id, serial_no),
  FOREIGN KEY (tenant_id, bundle_id) REFERENCES inventory.tracking_bundle(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, serial_id) REFERENCES inventory.serial(tenant_id, id),
  FOREIGN KEY (tenant_id, batch_id) REFERENCES inventory.batch(tenant_id, id),
  CONSTRAINT bundle_entry_one_serial CHECK (num_nonnulls(serial_id, serial_no) <= 1),
  CONSTRAINT bundle_entry_one_batch CHECK (num_nonnulls(batch_id, new_batch_no) <= 1),
  CONSTRAINT bundle_entry_serial_qty CHECK ((serial_id IS NULL AND serial_no IS NULL) OR qty_base = 1),
  CONSTRAINT bundle_entry_new_batch_dates CHECK (new_batch_no IS NOT NULL OR (new_batch_mfg IS NULL AND new_batch_expiry IS NULL)),
  CONSTRAINT bundle_entry_not_empty CHECK (num_nonnulls(serial_id, serial_no, batch_id, new_batch_no) >= 1)
);
SELECT core.enable_tenant_rls('inventory.tracking_bundle_entry');

-- =====================================================================
-- ۳. inventory — اسناد انبار (انتقال، تعدیل/ضایعات/مصرف، تولید داخلی، افتتاحیه)
-- =====================================================================
CREATE TABLE IF NOT EXISTS inventory.stock_doc (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  company_id             uuid NOT NULL,
  branch_id              uuid,
  doc_type               text NOT NULL CHECK (doc_type IN ('transfer','adjustment','production','opening')),
  status                 text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','in_transit','posted','cancelled')),
  doc_date               date NOT NULL,
  received_date          date,
  number_issued_id       uuid,
  doc_no                 text CHECK (char_length(doc_no) BETWEEN 1 AND 100),
  warehouse_id           uuid NOT NULL,
  to_warehouse_id        uuid,
  transit_warehouse_id   uuid,
  two_step               boolean NOT NULL DEFAULT false,
  count_session_id       uuid,
  bom_id                 uuid,
  reason_code            text CHECK (reason_code ~ '^[a-z][a-z0-9_]{1,40}$'),
  amount_unit            core.amount_unit,
  origin                 text NOT NULL DEFAULT 'online' CHECK (origin IN ('online','offline_device','migration','system')),
  description            text CHECK (description = core.fa_normalize_text(description)),
  gl_status              text NOT NULL DEFAULT 'pending' CHECK (gl_status IN ('pending','posted','not_required','deferred')),
  gl_journal_id          uuid,
  gl_receive_journal_id  uuid,
  cancel_journal_id      uuid,
  approval_request_id    uuid,
  posted_by              uuid,
  posted_at              timestamptz,
  received_by            uuid,
  received_at            timestamptz,
  cancelled_by           uuid,
  cancelled_at           timestamptz,
  cancel_reason          text,
  created_by             uuid,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, number_issued_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, to_warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, transit_warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, bom_id) REFERENCES catalog.bom(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_receive_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, cancel_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, approval_request_id) REFERENCES core.approval_request(tenant_id, id),
  FOREIGN KEY (tenant_id, posted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, received_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, cancelled_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT stock_doc_number_when_issued CHECK ((status <> 'draft') = (number_issued_id IS NOT NULL AND doc_no IS NOT NULL)),
  CONSTRAINT stock_doc_posted_meta CHECK (status = 'draft' OR posted_at IS NOT NULL),
  CONSTRAINT stock_doc_cancel_meta CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)),
  CONSTRAINT stock_doc_transfer_shape CHECK (
        (doc_type = 'transfer' AND to_warehouse_id IS NOT NULL AND warehouse_id <> to_warehouse_id
           AND (two_step = (transit_warehouse_id IS NOT NULL)))
     OR (doc_type <> 'transfer' AND transit_warehouse_id IS NULL AND NOT two_step AND to_warehouse_id IS NULL)),
  CONSTRAINT stock_doc_in_transit_shape CHECK (status <> 'in_transit' OR two_step),
  CONSTRAINT stock_doc_received_shape CHECK (received_date IS NULL OR two_step),
  CONSTRAINT stock_doc_received_meta CHECK ((received_at IS NULL) = (received_date IS NULL)),
  CONSTRAINT stock_doc_two_step_posted CHECK (NOT (two_step AND status = 'posted') OR received_date IS NOT NULL),
  CONSTRAINT stock_doc_received_after CHECK (received_date IS NULL OR received_date >= doc_date),
  CONSTRAINT stock_doc_opening_unit CHECK (doc_type <> 'opening' OR amount_unit IS NOT NULL),
  CONSTRAINT stock_doc_gl_link CHECK ((gl_status = 'posted') = (gl_journal_id IS NOT NULL)),
  CONSTRAINT stock_doc_gl_when_posted CHECK (status = 'draft' OR gl_status <> 'pending')
);
SELECT core.enable_tenant_rls('inventory.stock_doc');
CREATE INDEX IF NOT EXISTS stock_doc_date_idx ON inventory.stock_doc (tenant_id, company_id, doc_type, doc_date);

CREATE TABLE IF NOT EXISTS inventory.stock_doc_line (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  doc_id              uuid NOT NULL,
  line_no             integer NOT NULL CHECK (line_no BETWEEN 1 AND 100000),
  item_id             uuid NOT NULL,
  variant_id          uuid NOT NULL,
  uom_id              uuid NOT NULL,
  qty                 core.qty NOT NULL CHECK (qty > 0),
  qty_base            core.qty NOT NULL CHECK (qty_base > 0),
  direction           text NOT NULL CHECK (direction IN ('in','out')),
  role                text NOT NULL DEFAULT 'normal' CHECK (role IN ('normal','output','component')),
  cost_group_id       uuid,
  batch_id            uuid,
  bundle_id           uuid,
  input_unit_cost     core.rate CHECK (input_unit_cost >= 0),
  input_value         core.amount CHECK (input_value >= 0),
  input_cost_status   text NOT NULL DEFAULT 'known' CHECK (input_cost_status IN ('known','unknown')),
  received_qty_base   core.qty,
  reason_code         text CHECK (reason_code ~ '^[a-z][a-z0-9_]{1,40}$'),
  description         text CHECK (description = core.fa_normalize_text(description)),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, doc_id, line_no),
  FOREIGN KEY (tenant_id, doc_id) REFERENCES inventory.stock_doc(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, item_id, batch_id) REFERENCES inventory.batch(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, bundle_id) REFERENCES inventory.tracking_bundle(tenant_id, id),
  CONSTRAINT stock_doc_line_unknown_cost CHECK (input_cost_status = 'known' OR (input_value IS NULL AND input_unit_cost IS NULL)),
  CONSTRAINT stock_doc_line_received CHECK (received_qty_base IS NULL OR (received_qty_base >= 0 AND received_qty_base <= qty_base)),
  CONSTRAINT stock_doc_line_role_group CHECK ((role = 'normal') = (cost_group_id IS NULL)),
  CONSTRAINT stock_doc_line_role_direction CHECK (role = 'normal' OR (role = 'output') = (direction = 'in'))
);
SELECT core.enable_tenant_rls('inventory.stock_doc_line');

-- =====================================================================
-- ۴. inventory — دفتر موجودی و ارزیابی
-- =====================================================================

-- استخر بها (مشتق؛ فقط موتور definer می‌نویسد). کلید: (شرکت، SKU) یا (شرکت، SKU، انبار) طبق cost_pool_scope.
CREATE TABLE IF NOT EXISTS inventory.cost_pool (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  item_id          uuid NOT NULL,
  variant_id       uuid NOT NULL,
  warehouse_id     uuid,                       -- NULL = دامنهٔ شرکت
  method           text NOT NULL CHECK (method IN ('moving_average','fifo')),
  minor_unit       smallint NOT NULL CHECK (minor_unit BETWEEN 0 AND 4),
  qty              core.qty NOT NULL DEFAULT 0,
  value            core.amount NOT NULL DEFAULT 0,
  deficit_qty      core.qty NOT NULL DEFAULT 0 CHECK (deficit_qty >= 0),       -- فقط FIFO: مقدار صادرشده بیش از موجودی
  deficit_value    core.amount NOT NULL DEFAULT 0 CHECK (deficit_value >= 0),  -- ارزش برآوردی همان مقدار
  last_unit_cost   core.rate,
  last_date        date,
  last_seq         bigint,
  dirty_from_date  date,
  dirty_from_seq   bigint,
  dirty_since      timestamptz,
  move_count       bigint NOT NULL DEFAULT 0,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, company_id, variant_id, warehouse_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  CHECK ((dirty_from_date IS NULL) = (dirty_from_seq IS NULL)),
  CHECK ((dirty_from_date IS NULL) = (dirty_since IS NULL)),
  CHECK (method = 'fifo' OR (deficit_qty = 0 AND deficit_value = 0))
);
SELECT core.enable_tenant_rls('inventory.cost_pool');
CREATE INDEX IF NOT EXISTS cost_pool_dirty_idx ON inventory.cost_pool (tenant_id, company_id, dirty_from_date) WHERE dirty_from_date IS NOT NULL;

CREATE TABLE IF NOT EXISTS inventory.repost_run (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  trigger_reason   text NOT NULL CHECK (trigger_reason IN ('backdated','cost_adjustment','cascade','manual','integrity')),
  status           text NOT NULL DEFAULT 'running' CHECK (status IN ('running','completed','failed')),
  gl_floor_date    date NOT NULL,
  pools_processed  integer NOT NULL DEFAULT 0 CHECK (pools_processed >= 0),
  moves_scanned    integer NOT NULL DEFAULT 0 CHECK (moves_scanned >= 0),
  layers_added     integer NOT NULL DEFAULT 0 CHECK (layers_added >= 0),
  total_delta      core.amount NOT NULL DEFAULT 0,
  journal_count    integer NOT NULL DEFAULT 0 CHECK (journal_count >= 0),
  error            text,
  requested_by     uuid,
  started_at       timestamptz NOT NULL DEFAULT now(),
  finished_at      timestamptz,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, requested_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((status = 'running') = (finished_at IS NULL)),
  CHECK (status <> 'failed' OR error IS NOT NULL)
);
SELECT core.enable_tenant_rls('inventory.repost_run');

-- حرکت انبار: فقط‌افزودنی؛ یک سطر برای هر (سطر سند، انبار، SKU، بچ). سریال‌ها در serial_move.
CREATE TABLE IF NOT EXISTS inventory.stock_move (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid NOT NULL,
  branch_id            uuid,
  warehouse_id         uuid NOT NULL,
  location_id          uuid,
  item_id              uuid NOT NULL,
  variant_id           uuid NOT NULL,
  batch_id             uuid,
  move_date            date NOT NULL,
  posting_seq          bigint NOT NULL,
  move_kind            text NOT NULL CHECK (move_kind IN (
                         'receipt','purchase_return','sale_issue','sale_return','transfer_out','transfer_in',
                         'adjust_in','adjust_out','production_in','production_out','backflush','consumption','waste','opening')),
  qty_base             core.qty NOT NULL CHECK (qty_base <> 0),
  uom_id               uuid NOT NULL,
  qty_uom              core.qty NOT NULL CHECK (qty_uom > 0),
  valuation_rule       text NOT NULL CHECK (valuation_rule IN ('input','pool_out','pool_in','source','reverse','components')),
  input_value          core.amount CHECK (input_value >= 0),
  input_unit_cost      core.rate CHECK (input_unit_cost >= 0),
  input_cost_status    text NOT NULL DEFAULT 'known' CHECK (input_cost_status IN ('known','unknown')),
  cost_source_move_id  uuid,
  reversal_of_move_id  uuid,
  cost_group_id        uuid,
  pool_id              uuid NOT NULL,
  party_id             uuid,
  bom_id               uuid,
  bundle_id            uuid,
  asset_account_id     uuid,                -- حساب موجودی ثبت‌شده در GL (حالت دائمی)؛ مبنای تطبیق زیردفتر
  contra_posting_key   text,
  source_module        text NOT NULL CHECK (source_module ~ '^[a-z][a-z0-9_]{1,30}$'),
  source_doc_type      text NOT NULL CHECK (source_doc_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  source_doc_id        uuid NOT NULL,
  source_line_id       uuid,
  origin               text NOT NULL DEFAULT 'online' CHECK (origin IN ('online','offline_device','migration','system')),
  created_by           uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, warehouse_id, location_id) REFERENCES inventory.location(tenant_id, warehouse_id, id),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, item_id, batch_id) REFERENCES inventory.batch(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, company_id, cost_source_move_id) REFERENCES inventory.stock_move(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, reversal_of_move_id) REFERENCES inventory.stock_move(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, pool_id) REFERENCES inventory.cost_pool(tenant_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, bom_id) REFERENCES catalog.bom(tenant_id, id),
  FOREIGN KEY (tenant_id, bundle_id) REFERENCES inventory.tracking_bundle(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, asset_account_id) REFERENCES ledger.account(tenant_id, company_id, id),
  FOREIGN KEY (contra_posting_key) REFERENCES ledger.posting_key(key),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT stock_move_input_shape CHECK (valuation_rule <> 'input' OR input_cost_status = 'unknown'
                                           OR num_nonnulls(input_value, input_unit_cost) >= 1),
  CONSTRAINT stock_move_input_only CHECK (valuation_rule = 'input'
                                          OR (input_value IS NULL AND input_unit_cost IS NULL AND input_cost_status = 'known')),
  CONSTRAINT stock_move_unknown_cost CHECK (input_cost_status = 'known' OR (input_value IS NULL AND input_unit_cost IS NULL)),
  CONSTRAINT stock_move_source_shape CHECK ((valuation_rule = 'source') = (cost_source_move_id IS NOT NULL AND reversal_of_move_id IS NULL)),
  CONSTRAINT stock_move_reverse_shape CHECK ((valuation_rule = 'reverse') = (reversal_of_move_id IS NOT NULL)),
  CONSTRAINT stock_move_reverse_source CHECK (reversal_of_move_id IS NULL OR cost_source_move_id IS NULL),
  CONSTRAINT stock_move_components_shape CHECK (valuation_rule <> 'components' OR cost_group_id IS NOT NULL),
  CONSTRAINT stock_move_production_group CHECK (move_kind NOT IN ('production_in','production_out') OR cost_group_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('inventory.stock_move');
CREATE UNIQUE INDEX IF NOT EXISTS stock_move_seq_uq ON inventory.stock_move (tenant_id, posting_seq);
CREATE UNIQUE INDEX IF NOT EXISTS stock_move_one_reversal ON inventory.stock_move (tenant_id, reversal_of_move_id) WHERE reversal_of_move_id IS NOT NULL;
-- تلهٔ «تکرار افتتاحیهٔ انبار» (پژوهش ۰۱): یک حرکت افتتاحیه برای هر (شرکت، انبار، SKU، بچ)
CREATE UNIQUE INDEX IF NOT EXISTS stock_move_one_opening ON inventory.stock_move (tenant_id, company_id, warehouse_id, variant_id, batch_id)
  NULLS NOT DISTINCT WHERE move_kind = 'opening' AND reversal_of_move_id IS NULL;
CREATE INDEX IF NOT EXISTS stock_move_pool_point ON inventory.stock_move (tenant_id, pool_id, move_date, posting_seq);
CREATE INDEX IF NOT EXISTS stock_move_wh_point ON inventory.stock_move (tenant_id, warehouse_id, variant_id, move_date, posting_seq);
CREATE INDEX IF NOT EXISTS stock_move_source_idx ON inventory.stock_move (tenant_id, source_doc_id);
CREATE INDEX IF NOT EXISTS stock_move_cost_source_idx ON inventory.stock_move (tenant_id, cost_source_move_id) WHERE cost_source_move_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS stock_move_group_idx ON inventory.stock_move (tenant_id, cost_group_id) WHERE cost_group_id IS NOT NULL;

ALTER TABLE inventory.serial DROP CONSTRAINT IF EXISTS serial_last_move_fk;
ALTER TABLE inventory.serial ADD CONSTRAINT serial_last_move_fk
  FOREIGN KEY (tenant_id, last_move_id) REFERENCES inventory.stock_move(tenant_id, id);

-- حرکت سریال (bundle حرکت): فقط‌افزودنی
CREATE TABLE IF NOT EXISTS inventory.serial_move (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  company_id    uuid NOT NULL,
  move_id       uuid NOT NULL,
  serial_id     uuid NOT NULL,
  qty_sign      smallint NOT NULL CHECK (qty_sign IN (1,-1)),
  warehouse_id  uuid NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, move_id, serial_id),
  FOREIGN KEY (tenant_id, company_id, move_id) REFERENCES inventory.stock_move(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, serial_id) REFERENCES inventory.serial(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id)
);
SELECT core.enable_tenant_rls('inventory.serial_move');
CREATE INDEX IF NOT EXISTS serial_move_serial_idx ON inventory.serial_move (tenant_id, serial_id, created_at);

-- لایهٔ ارزش: فقط‌افزودنی؛ ارزش حرکت = Σ لایه‌ها. ثابت (is_derived=false) = ورودی بیرونی؛ مشتق = محاسبهٔ موتور.
CREATE TABLE IF NOT EXISTS inventory.valuation_layer (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  pool_id          uuid NOT NULL,
  move_id          uuid NOT NULL,
  layer_kind       text NOT NULL CHECK (layer_kind IN ('initial','settlement','adjustment')),
  is_derived       boolean NOT NULL,
  reason           text NOT NULL CHECK (reason IN ('move','negative_settlement','repost','landed_cost','price_difference',
                                                   'cost_resolution','redenomination','manual_revaluation')),
  value            core.amount NOT NULL,
  cost_status      text NOT NULL CHECK (cost_status IN ('known','estimated','unknown')),
  unit_cost        core.rate,
  gl_date          date NOT NULL,
  fifo_detail      jsonb CHECK (fifo_detail IS NULL OR jsonb_typeof(fifo_detail) = 'array'),
  repost_run_id    uuid,
  source_module    text CHECK (source_module ~ '^[a-z][a-z0-9_]{1,30}$'),
  source_doc_type  text CHECK (source_doc_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  source_doc_id    uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, move_id) REFERENCES inventory.stock_move(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, pool_id) REFERENCES inventory.cost_pool(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, repost_run_id) REFERENCES inventory.repost_run(tenant_id, company_id, id),
  CONSTRAINT layer_initial_reason CHECK ((layer_kind = 'initial') = (reason = 'move')),
  CONSTRAINT layer_settlement_shape CHECK ((layer_kind = 'settlement') = (reason = 'negative_settlement')),
  CONSTRAINT layer_nonzero CHECK (layer_kind = 'initial' OR value <> 0),
  CONSTRAINT layer_derived_reasons CHECK (is_derived = (reason IN ('negative_settlement','repost')) OR reason = 'move'),
  CONSTRAINT layer_repost_run CHECK ((reason = 'repost') = (repost_run_id IS NOT NULL)),
  CONSTRAINT layer_fixed_source CHECK ((reason IN ('landed_cost','price_difference','cost_resolution','manual_revaluation'))
                                       = (source_doc_id IS NOT NULL AND source_doc_type IS NOT NULL AND source_module IS NOT NULL))
);
SELECT core.enable_tenant_rls('inventory.valuation_layer');
CREATE UNIQUE INDEX IF NOT EXISTS valuation_layer_one_initial ON inventory.valuation_layer (tenant_id, move_id) WHERE layer_kind = 'initial';
CREATE INDEX IF NOT EXISTS valuation_layer_move_idx ON inventory.valuation_layer (tenant_id, move_id);
CREATE INDEX IF NOT EXISTS valuation_layer_gl_idx ON inventory.valuation_layer (tenant_id, company_id, gl_date);
CREATE INDEX IF NOT EXISTS valuation_layer_run_idx ON inventory.valuation_layer (tenant_id, repost_run_id) WHERE repost_run_id IS NOT NULL;

-- صف FIFO (مشتق): باقی‌ماندهٔ هر لایهٔ ورودی
CREATE TABLE IF NOT EXISTS inventory.fifo_layer (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  pool_id          uuid NOT NULL,
  move_id          uuid NOT NULL,
  point_date       date NOT NULL,
  point_seq        bigint NOT NULL,
  qty_in           core.qty NOT NULL CHECK (qty_in > 0),
  qty_remaining    core.qty NOT NULL CHECK (qty_remaining >= 0),
  value_remaining  core.amount NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, pool_id, move_id),
  FOREIGN KEY (tenant_id, pool_id) REFERENCES inventory.cost_pool(tenant_id, id),
  FOREIGN KEY (tenant_id, move_id) REFERENCES inventory.stock_move(tenant_id, id),
  CHECK (qty_remaining <= qty_in),
  CHECK (qty_remaining > 0 OR value_remaining = 0)
);
SELECT core.enable_tenant_rls('inventory.fifo_layer');
CREATE INDEX IF NOT EXISTS fifo_layer_head ON inventory.fifo_layer (tenant_id, pool_id, point_date, point_seq) WHERE qty_remaining > 0;

-- نقطهٔ بازیابی استخر (مشتق؛ برای کوتاه کردن بازپخش)
CREATE TABLE IF NOT EXISTS inventory.pool_checkpoint (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  pool_id         uuid NOT NULL,
  point_date      date NOT NULL,
  point_seq       bigint NOT NULL,
  qty             core.qty NOT NULL,
  value           core.amount NOT NULL,
  deficit_qty     core.qty NOT NULL,
  deficit_value   core.amount NOT NULL,
  last_unit_cost  core.rate,
  fifo_state      jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(fifo_state) = 'array'),
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, pool_id, point_date, point_seq),
  FOREIGN KEY (tenant_id, pool_id) REFERENCES inventory.cost_pool(tenant_id, id)
);
SELECT core.enable_tenant_rls('inventory.pool_checkpoint');

-- موجودی جاری (مشتق) برای (انبار، SKU، بچ)
CREATE TABLE IF NOT EXISTS inventory.stock_balance (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  company_id      uuid NOT NULL,
  warehouse_id    uuid NOT NULL,
  item_id         uuid NOT NULL,
  variant_id      uuid NOT NULL,
  batch_id        uuid,
  qty             core.qty NOT NULL DEFAULT 0,
  last_move_date  date,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, warehouse_id, variant_id, batch_id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, batch_id) REFERENCES inventory.batch(tenant_id, item_id, id)
);
SELECT core.enable_tenant_rls('inventory.stock_balance');

-- استثنای انبار (موجودی منفی، تعارض سریال، فروش بچ منقضی، بهای نامعلوم) — درج فقط موتور؛ رسیدگی با برنامه
CREATE TABLE IF NOT EXISTS inventory.stock_exception (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  kind             text NOT NULL CHECK (kind IN ('negative_stock','serial_conflict','expired_batch','unknown_cost')),
  move_id          uuid NOT NULL,
  warehouse_id     uuid NOT NULL,
  variant_id       uuid NOT NULL,
  serial_id        uuid,
  qty_after        core.qty,
  detail           jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(detail) = 'object'),
  status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open','acknowledged','resolved')),
  resolved_by      uuid,
  resolved_at      timestamptz,
  resolution_note  text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, move_id) REFERENCES inventory.stock_move(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, serial_id) REFERENCES inventory.serial(tenant_id, id),
  FOREIGN KEY (tenant_id, resolved_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((status = 'resolved') = (resolved_at IS NOT NULL AND resolution_note IS NOT NULL))
);
SELECT core.enable_tenant_rls('inventory.stock_exception');
CREATE INDEX IF NOT EXISTS stock_exception_open ON inventory.stock_exception (tenant_id, company_id, kind) WHERE status <> 'resolved';

-- =====================================================================
-- ۵. inventory — انبارگردانی و بستن ادواری
-- =====================================================================
CREATE TABLE IF NOT EXISTS inventory.count_session (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  company_id          uuid NOT NULL,
  branch_id           uuid,
  warehouse_id        uuid NOT NULL,
  count_date          date NOT NULL,
  status              text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','counting','reviewing','posted','cancelled')),
  scope               text NOT NULL DEFAULT 'full' CHECK (scope IN ('full','category','selected')),
  category_id         uuid,
  blind               boolean NOT NULL DEFAULT true,
  rounds              smallint NOT NULL DEFAULT 1 CHECK (rounds IN (1,2)),
  number_issued_id    uuid,
  doc_no              text,
  adjustment_doc_id   uuid,
  started_at          timestamptz,
  reviewed_at         timestamptz,
  posted_at           timestamptz,
  posted_by           uuid,
  cancelled_at        timestamptz,
  cancel_reason       text,
  created_by          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, number_issued_id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, category_id) REFERENCES catalog.item_category(tenant_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, adjustment_doc_id) REFERENCES inventory.stock_doc(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, posted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((scope = 'category') = (category_id IS NOT NULL)),
  CHECK ((status = 'posted') = (posted_at IS NOT NULL AND number_issued_id IS NOT NULL)),
  CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)),
  CHECK (status IN ('draft','cancelled') OR started_at IS NOT NULL),
  CHECK (status NOT IN ('reviewing','posted') OR reviewed_at IS NOT NULL)
);
SELECT core.enable_tenant_rls('inventory.count_session');
-- یک انبارگردانی باز برای هر انبار
CREATE UNIQUE INDEX IF NOT EXISTS count_session_one_open ON inventory.count_session (tenant_id, warehouse_id)
  WHERE status IN ('counting','reviewing');

ALTER TABLE inventory.stock_doc DROP CONSTRAINT IF EXISTS stock_doc_count_session_fk;
ALTER TABLE inventory.stock_doc ADD CONSTRAINT stock_doc_count_session_fk
  FOREIGN KEY (tenant_id, company_id, count_session_id) REFERENCES inventory.count_session(tenant_id, company_id, id);

CREATE TABLE IF NOT EXISTS inventory.count_line (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  session_id          uuid NOT NULL,
  line_no             integer NOT NULL CHECK (line_no BETWEEN 1 AND 1000000),
  item_id             uuid NOT NULL,
  variant_id          uuid NOT NULL,
  batch_id            uuid,
  uom_id              uuid NOT NULL,
  system_qty_base     core.qty,                 -- تصویر موجودی سیستم در پایان روز شمارش (هنگام ورود به reviewing)
  counted_qty_base    core.qty CHECK (counted_qty_base >= 0),   -- مقدار پذیرفته‌شدهٔ نهایی
  unit_cost_snapshot  core.rate,
  note                text CHECK (note = core.fa_normalize_text(note)),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, session_id, line_no),
  UNIQUE NULLS NOT DISTINCT (tenant_id, session_id, variant_id, batch_id),
  FOREIGN KEY (tenant_id, session_id) REFERENCES inventory.count_session(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, item_id, batch_id) REFERENCES inventory.batch(tenant_id, item_id, id)
);
SELECT core.enable_tenant_rls('inventory.count_line');

-- شمارش‌های تکی (دو دور، شمارندهٔ متفاوت)؛ فقط‌افزودنی
CREATE TABLE IF NOT EXISTS inventory.count_entry (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  line_id       uuid NOT NULL,
  round_no      smallint NOT NULL CHECK (round_no IN (1,2)),
  qty           core.qty NOT NULL CHECK (qty >= 0),
  qty_base      core.qty NOT NULL CHECK (qty_base >= 0),
  counted_by    uuid NOT NULL,
  device_id     uuid,
  counted_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, line_id) REFERENCES inventory.count_line(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, counted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id)
);
SELECT core.enable_tenant_rls('inventory.count_entry');

-- بستن ادواری: بهای تمام‌شده = موجودی ابتدا + خرید − برگشت از خرید − موجودی پایان
CREATE TABLE IF NOT EXISTS inventory.periodic_close (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL DEFAULT uuidv7(),
  company_id              uuid NOT NULL,
  fiscal_year_id          uuid NOT NULL,
  period_from             date NOT NULL,
  period_to               date NOT NULL,
  basis                   text NOT NULL CHECK (basis IN ('valuation','count','manual')),
  status                  text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','reversed')),
  opening_value           core.amount NOT NULL DEFAULT 0 CHECK (opening_value >= 0),
  purchases_value         core.amount NOT NULL DEFAULT 0 CHECK (purchases_value >= 0),
  purchase_returns_value  core.amount NOT NULL DEFAULT 0 CHECK (purchase_returns_value >= 0),
  closing_value           core.amount NOT NULL DEFAULT 0 CHECK (closing_value >= 0),
  cogs_value              core.amount NOT NULL,
  count_session_id        uuid,
  gl_journal_id           uuid,
  reversal_journal_id     uuid,
  posted_by               uuid,
  posted_at               timestamptz,
  created_by              uuid,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  row_version             integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, fiscal_year_id) REFERENCES ledger.fiscal_year(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, count_session_id) REFERENCES inventory.count_session(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, reversal_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, posted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT periodic_close_cogs CHECK (cogs_value = opening_value + purchases_value - purchase_returns_value - closing_value),
  CONSTRAINT periodic_close_range CHECK (period_to >= period_from),
  CONSTRAINT periodic_close_posted CHECK ((status <> 'draft') = (gl_journal_id IS NOT NULL AND posted_at IS NOT NULL)),
  CONSTRAINT periodic_close_reversed CHECK ((status = 'reversed') = (reversal_journal_id IS NOT NULL)),
  CONSTRAINT periodic_close_count_basis CHECK ((basis = 'count') = (count_session_id IS NOT NULL))
);
SELECT core.enable_tenant_rls('inventory.periodic_close');
CREATE UNIQUE INDEX IF NOT EXISTS periodic_close_one_posted ON inventory.periodic_close (tenant_id, company_id, period_to) WHERE status = 'posted';

CREATE TABLE IF NOT EXISTS inventory.periodic_close_line (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  close_id            uuid NOT NULL,
  company_id          uuid NOT NULL,
  asset_account_id    uuid NOT NULL,
  posting_group_code  text,
  opening_value       core.amount NOT NULL CHECK (opening_value >= 0),
  closing_value       core.amount NOT NULL CHECK (closing_value >= 0),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, close_id, asset_account_id, posting_group_code),
  FOREIGN KEY (tenant_id, close_id) REFERENCES inventory.periodic_close(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, company_id, asset_account_id) REFERENCES ledger.account(tenant_id, company_id, id)
);
SELECT core.enable_tenant_rls('inventory.periodic_close_line');

-- =====================================================================
-- ۶. inventory — توابع کمکی
-- =====================================================================
CREATE OR REPLACE FUNCTION inventory.require_tenant() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v uuid := core.current_tenant_id();
BEGIN
  IF v IS NULL THEN
    RAISE EXCEPTION 'HK_TENANT_CONTEXT_MISSING: app.tenant_id is not set' USING ERRCODE = 'P0001';
  END IF;
  RETURN v;
END $$;

-- رقم اعشار ارز پایهٔ شرکت (IRR = 0)
CREATE OR REPLACE FUNCTION inventory.company_minor(p_company_id uuid) RETURNS smallint
LANGUAGE sql STABLE AS $$
  SELECT c.minor_unit FROM core.company co JOIN ref.currency c ON c.code = co.base_currency WHERE co.id = p_company_id
$$;

-- علامت طبیعی هر نوع حرکت: +۱ ورود، −۱ خروج
CREATE OR REPLACE FUNCTION inventory.kind_sign(p_kind text) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_kind IN ('receipt','sale_return','transfer_in','adjust_in','production_in','opening') THEN 1::smallint
              WHEN p_kind IN ('purchase_return','sale_issue','transfer_out','adjust_out','production_out','backflush','consumption','waste') THEN -1::smallint
         END
$$;

-- قاعدهٔ ارزیابی مجاز برای هر نوع حرکت (reverse برای همه)
CREATE OR REPLACE FUNCTION inventory.rule_allowed(p_kind text, p_rule text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT p_rule = 'reverse' OR CASE p_kind
    WHEN 'receipt'         THEN p_rule = 'input'
    WHEN 'opening'         THEN p_rule = 'input'
    WHEN 'adjust_in'       THEN p_rule IN ('input','pool_in')
    WHEN 'production_in'   THEN p_rule IN ('components','input')
    WHEN 'sale_return'     THEN p_rule IN ('source','pool_in')
    WHEN 'transfer_in'     THEN p_rule = 'source'
    WHEN 'purchase_return' THEN p_rule IN ('source','pool_out')
    ELSE p_rule = 'pool_out' END
$$;

-- سیاست مؤثر شرکت در یک تاریخ
CREATE OR REPLACE FUNCTION inventory.policy_on(p_company_id uuid, p_date date) RETURNS inventory.company_policy
LANGUAGE plpgsql STABLE AS $$
DECLARE r inventory.company_policy;
BEGIN
  SELECT * INTO r FROM inventory.company_policy p
   WHERE p.company_id = p_company_id AND p.effective_from <= p_date
   ORDER BY p.effective_from DESC LIMIT 1;
  IF NOT FOUND THEN
    PERFORM core.raise_hk('HK_INV_POLICY_MISSING', format('no inventory policy for company %s on %s', p_company_id, p_date));
  END IF;
  RETURN r;
END $$;

-- ستون‌های تغییرکرده بین دو نسخهٔ ردیف (برای نگهبان‌های تغییرناپذیری)
CREATE OR REPLACE FUNCTION inventory.changed_columns(p_old jsonb, p_new jsonb) RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(array_agg(k ORDER BY k), '{}') FROM jsonb_object_keys(p_new) k
   WHERE p_new -> k IS DISTINCT FROM p_old -> k
$$;

-- بدترین وضعیت بها
CREATE OR REPLACE FUNCTION inventory.worse_status(a text, b text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN 'unknown' IN (a, b) THEN 'unknown' WHEN 'estimated' IN (a, b) THEN 'estimated' ELSE 'known' END
$$;

-- ارزش کل یک حرکت (Σ لایه‌ها) و بدترین وضعیت
CREATE OR REPLACE FUNCTION inventory.move_value(p_move_id uuid) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(l.value), 0) FROM inventory.valuation_layer l WHERE l.move_id = p_move_id
$$;

-- =====================================================================
-- ۷. inventory — موتور ارزیابی (SECURITY DEFINER؛ مالک hk_inventory_definer؛ فهرست مجاز D-32)
-- =====================================================================

-- استخر بهای حرکت را می‌یابد/می‌سازد و قفل می‌کند (FOR UPDATE تا پایان تراکنش).
CREATE OR REPLACE FUNCTION inventory.pool_acquire(p_company_id uuid, p_item_id uuid, p_variant_id uuid, p_warehouse_id uuid, p_date date)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_t uuid := inventory.require_tenant(); pol inventory.company_policy; v_wh uuid; v_id uuid;
BEGIN
  pol := inventory.policy_on(p_company_id, p_date);
  v_wh := CASE WHEN pol.cost_pool_scope = 'warehouse' THEN p_warehouse_id END;
  INSERT INTO inventory.cost_pool (tenant_id, company_id, item_id, variant_id, warehouse_id, method, minor_unit)
  VALUES (v_t, p_company_id, p_item_id, p_variant_id, v_wh, pol.valuation_method, inventory.company_minor(p_company_id))
  ON CONFLICT (tenant_id, company_id, variant_id, warehouse_id) DO NOTHING;
  SELECT c.id INTO v_id FROM inventory.cost_pool c
   WHERE c.tenant_id = v_t AND c.company_id = p_company_id AND c.variant_id = p_variant_id
     AND c.warehouse_id IS NOT DISTINCT FROM v_wh
   FOR UPDATE;
  RETURN v_id;
END $$;

-- مصرف از صف FIFO (اول لایهٔ ترجیحی، سپس سر صف؛ کسری با بهای برآوردی). استخر قفل است؛
-- خروجی: ارزش کل، وضعیت، جزئیات، و مقدار/ارزش کسری تازه (که فراخوان روی استخر اعمال می‌کند).
CREATE OR REPLACE FUNCTION inventory.fifo_take(p_tenant uuid, p_pool_id uuid, p_qty numeric, p_prefer_move uuid,
                                               p_minor smallint, p_last_unit_cost numeric)
RETURNS TABLE (total numeric, status text, detail jsonb, deficit_qty numeric, deficit_value numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE need numeric := p_qty; f record; take numeric; portion numeric; est numeric;
BEGIN
  total := 0; status := 'known'; detail := '[]'::jsonb; deficit_qty := 0; deficit_value := 0;
  FOR f IN SELECT * FROM inventory.fifo_layer l
            WHERE l.tenant_id = p_tenant AND l.pool_id = p_pool_id AND l.qty_remaining > 0
            ORDER BY (l.move_id = p_prefer_move) DESC NULLS LAST, l.point_date, l.point_seq, l.id
            FOR UPDATE LOOP
    EXIT WHEN need <= 0;
    take := least(need, f.qty_remaining);
    portion := CASE WHEN take = f.qty_remaining THEN f.value_remaining
                    ELSE round(f.value_remaining * take / f.qty_remaining, p_minor) END;
    UPDATE inventory.fifo_layer SET qty_remaining = qty_remaining - take, value_remaining = value_remaining - portion
     WHERE id = f.id;
    total := total + portion; need := need - take;
    detail := detail || jsonb_build_object('move_id', f.move_id, 'qty', take, 'value', portion);
  END LOOP;
  IF need > 0 THEN
    est := round(coalesce(p_last_unit_cost, 0) * need, p_minor);
    deficit_qty := need; deficit_value := est;
    total := total + est;
    status := CASE WHEN p_last_unit_cost IS NULL THEN 'unknown' ELSE 'estimated' END;
    detail := detail || jsonb_build_object('deficit_qty', need, 'value', est);
  END IF;
  RETURN NEXT;
END $$;

-- یک گام ارزیابی برای یک حرکت روی استخر قفل‌شده.
--   p_mode = 'initial': لایهٔ اولیه (و تسویهٔ کسری) را درج می‌کند.
--   p_mode = 'replay' : ارزش مشتق مورد انتظار را با Σ لایه‌های مشتق مقایسه و فقط تفاوت را با لایهٔ repost درج می‌کند.
-- خروجی: تعداد لایه‌های درج‌شده.
CREATE OR REPLACE FUNCTION inventory.valuate(p_move inventory.stock_move, p_mode text, p_run uuid, p_gl_floor date)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  p inventory.cost_pool; q numeric := p_move.qty_base; m smallint;
  fixed_total numeric := 0; in_val numeric; dv numeric := 0; sv numeric := 0; st text := 'known';
  detail jsonb; src inventory.stock_move; src_total numeric; src_st text; avg numeric;
  cover numeric; est numeric; actual numeric; remaining numeric; rem_val numeric; outq numeric; val numeric;
  cur_derived numeric; delta numeric; n integer := 0; ft record; prefer uuid;
BEGIN
  SELECT * INTO p FROM inventory.cost_pool c WHERE c.id = p_move.pool_id;
  m := p.minor_unit;
  IF p_move.valuation_rule = 'input' THEN
    IF p_mode = 'initial' THEN
      fixed_total := CASE WHEN p_move.input_cost_status = 'unknown' THEN 0
                          ELSE coalesce(p_move.input_value, round(abs(q) * p_move.input_unit_cost, m)) END;
    ELSE
      SELECT coalesce(sum(l.value), 0) INTO fixed_total FROM inventory.valuation_layer l
       WHERE l.tenant_id = p_move.tenant_id AND l.move_id = p_move.id AND NOT l.is_derived;
    END IF;
    st := CASE WHEN p_move.input_cost_status = 'unknown' AND fixed_total = 0 THEN 'unknown' ELSE 'known' END;
  END IF;

  IF q > 0 THEN
    -- ---------- ورود ----------
    IF p_move.valuation_rule = 'input' THEN
      in_val := fixed_total;
    ELSIF p_move.valuation_rule IN ('source','reverse') THEN
      SELECT * INTO src FROM inventory.stock_move s
       WHERE s.tenant_id = p_move.tenant_id AND s.id = coalesce(p_move.reversal_of_move_id, p_move.cost_source_move_id);
      SELECT coalesce(sum(l.value), 0),
             CASE WHEN bool_or(l.cost_status = 'unknown') THEN 'unknown' WHEN bool_or(l.cost_status = 'estimated') THEN 'estimated' ELSE 'known' END
        INTO src_total, src_st
        FROM inventory.valuation_layer l WHERE l.tenant_id = p_move.tenant_id AND l.move_id = src.id;
      in_val := CASE WHEN p_move.valuation_rule = 'reverse' OR q = abs(src.qty_base) THEN -src_total
                     ELSE round(-src_total * q / abs(src.qty_base), m) END;
      st := coalesce(src_st, 'known'); dv := in_val;
    ELSIF p_move.valuation_rule = 'components' THEN
      SELECT coalesce(-sum(l.value), 0),
             CASE WHEN bool_or(l.cost_status = 'unknown') THEN 'unknown' WHEN bool_or(l.cost_status = 'estimated') THEN 'estimated' ELSE 'known' END
        INTO in_val, src_st
        FROM inventory.stock_move s JOIN inventory.valuation_layer l ON l.tenant_id = s.tenant_id AND l.move_id = s.id
       WHERE s.tenant_id = p_move.tenant_id AND s.cost_group_id = p_move.cost_group_id
         AND s.source_doc_id = p_move.source_doc_id AND s.qty_base < 0;
      st := coalesce(src_st, 'known'); dv := in_val;
    ELSE -- pool_in: به بهای جاری استخر
      avg := CASE WHEN p.qty > 0 THEN p.value / p.qty ELSE p.last_unit_cost END;
      in_val := round(coalesce(avg, 0) * q, m);
      st := CASE WHEN p.qty > 0 THEN 'known' WHEN p.last_unit_cost IS NOT NULL THEN 'estimated' ELSE 'unknown' END;
      dv := in_val;
    END IF;
    -- تسویهٔ کسری (ورود پس از موجودی منفی)
    IF p.method = 'moving_average' THEN
      IF p.qty < 0 THEN
        cover := least(q, -p.qty);
        est := CASE WHEN cover = -p.qty THEN -p.value ELSE round(p.value * cover / p.qty, m) END;
        actual := CASE WHEN cover = q THEN in_val ELSE round(in_val * cover / q, m) END;
        sv := est - actual;
      END IF;
    ELSE
      remaining := q; rem_val := in_val;
      IF p.deficit_qty > 0 THEN
        cover := least(q, p.deficit_qty);
        est := CASE WHEN cover = p.deficit_qty THEN p.deficit_value ELSE round(p.deficit_value * cover / p.deficit_qty, m) END;
        actual := CASE WHEN cover = q THEN in_val ELSE round(in_val * cover / q, m) END;
        sv := est - actual;
        p.deficit_qty := p.deficit_qty - cover; p.deficit_value := p.deficit_value - est;
        remaining := q - cover; rem_val := in_val - actual;
      END IF;
      IF remaining > 0 THEN
        INSERT INTO inventory.fifo_layer (tenant_id, pool_id, move_id, point_date, point_seq, qty_in, qty_remaining, value_remaining)
        VALUES (p.tenant_id, p.id, p_move.id, p_move.move_date, p_move.posting_seq, q, remaining, rem_val);
      END IF;
    END IF;
    p.qty := p.qty + q;
    p.value := p.value + in_val + sv;
    IF in_val > 0 AND st = 'known' THEN p.last_unit_cost := round(in_val / q, 12); END IF;
  ELSE
    -- ---------- خروج ----------
    outq := -q;
    IF p_move.valuation_rule IN ('source','reverse') THEN
      SELECT * INTO src FROM inventory.stock_move s
       WHERE s.tenant_id = p_move.tenant_id AND s.id = coalesce(p_move.reversal_of_move_id, p_move.cost_source_move_id);
      prefer := src.id;
    END IF;
    IF p.method = 'fifo' THEN
      SELECT x.total, x.status, x.detail, x.deficit_qty, x.deficit_value INTO val, st, detail, cover, est
        FROM inventory.fifo_take(p.tenant_id, p.id, outq, prefer, m, p.last_unit_cost) x;
      p.deficit_qty := p.deficit_qty + cover; p.deficit_value := p.deficit_value + est;
    ELSIF p_move.valuation_rule IN ('source','reverse') THEN
      src_total := inventory.move_value(src.id);
      val := CASE WHEN p_move.valuation_rule = 'reverse' OR outq = abs(src.qty_base) THEN src_total
                  ELSE round(src_total * outq / abs(src.qty_base), m) END;
      st := 'known';
    ELSIF p.qty > 0 THEN
      val := CASE WHEN outq = p.qty THEN p.value ELSE round(p.value * outq / p.qty, m) END;
      st := CASE WHEN outq > p.qty THEN 'estimated' ELSE 'known' END;
    ELSE
      val := round(coalesce(p.last_unit_cost, 0) * outq, m);
      st := CASE WHEN p.last_unit_cost IS NULL THEN 'unknown' ELSE 'estimated' END;
    END IF;
    dv := -val;
    p.qty := p.qty - outq;
    p.value := p.value - val;
  END IF;

  IF p_mode = 'initial' THEN
    INSERT INTO inventory.valuation_layer (tenant_id, company_id, pool_id, move_id, layer_kind, is_derived, reason, value,
                                           cost_status, unit_cost, gl_date, fifo_detail)
    VALUES (p_move.tenant_id, p_move.company_id, p.id, p_move.id, 'initial', p_move.valuation_rule <> 'input', 'move',
            CASE WHEN p_move.valuation_rule = 'input' THEN fixed_total ELSE dv END, st,
            round(abs(CASE WHEN p_move.valuation_rule = 'input' THEN fixed_total ELSE dv END) / abs(q), 12),
            p_move.move_date, CASE WHEN detail IS NOT NULL AND detail <> '[]'::jsonb THEN detail END);
    n := 1;
    IF sv <> 0 THEN
      INSERT INTO inventory.valuation_layer (tenant_id, company_id, pool_id, move_id, layer_kind, is_derived, reason, value,
                                             cost_status, gl_date)
      VALUES (p_move.tenant_id, p_move.company_id, p.id, p_move.id, 'settlement', true, 'negative_settlement', sv, st, p_move.move_date);
      n := 2;
    END IF;
  ELSE
    SELECT coalesce(sum(l.value), 0) INTO cur_derived FROM inventory.valuation_layer l
     WHERE l.tenant_id = p_move.tenant_id AND l.move_id = p_move.id AND l.is_derived;
    delta := (dv + sv) - cur_derived;
    IF delta <> 0 THEN
      INSERT INTO inventory.valuation_layer (tenant_id, company_id, pool_id, move_id, layer_kind, is_derived, reason, value,
                                             cost_status, gl_date, fifo_detail, repost_run_id)
      VALUES (p_move.tenant_id, p_move.company_id, p.id, p_move.id, 'adjustment', true, 'repost', delta, st,
              greatest(p_move.move_date, coalesce(p_gl_floor, p_move.move_date)),
              CASE WHEN detail IS NOT NULL AND detail <> '[]'::jsonb THEN detail END, p_run);
      n := 1;
      -- وابسته‌ها در استخرهای دیگر (بازگشت فروش، ورود انتقال، خروجی تولید، برگشت حرکت) کثیف می‌شوند
      UPDATE inventory.cost_pool c
         SET dirty_from_date = d.move_date, dirty_from_seq = d.posting_seq, dirty_since = coalesce(c.dirty_since, now())
        FROM (SELECT DISTINCT ON (s.pool_id) s.pool_id, s.move_date, s.posting_seq
                FROM inventory.stock_move s
               WHERE s.tenant_id = p_move.tenant_id AND s.pool_id <> p.id
                 AND (s.cost_source_move_id = p_move.id OR s.reversal_of_move_id = p_move.id
                      OR (p_move.cost_group_id IS NOT NULL AND s.cost_group_id = p_move.cost_group_id
                          AND s.valuation_rule = 'components'))
               ORDER BY s.pool_id, s.move_date, s.posting_seq) d
       WHERE c.tenant_id = p_move.tenant_id AND c.id = d.pool_id
         AND (c.dirty_from_date IS NULL OR (d.move_date, d.posting_seq) < (c.dirty_from_date, c.dirty_from_seq));
    END IF;
  END IF;

  UPDATE inventory.cost_pool c
     SET qty = p.qty, value = p.value, deficit_qty = p.deficit_qty, deficit_value = p.deficit_value,
         last_unit_cost = p.last_unit_cost, updated_at = now()
   WHERE c.id = p.id;
  RETURN n;
END $$;

-- ---------- تریگر BEFORE INSERT روی stock_move (invoker): اعتبارسنجی، استخر، ترتیب ----------
CREATE OR REPLACE FUNCTION inventory.stock_move_before() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_t uuid := inventory.require_tenant(); sku record; wh inventory.warehouse; src inventory.stock_move;
  v_expect smallint; v_base_qty numeric; v_open date; v_bstatus text; v_bno text; v_bexp date;
BEGIN
  SELECT s.item_type, s.track_batch, s.base_uom_id, s.item_id INTO sku FROM catalog.v_sku s WHERE s.variant_id = NEW.variant_id;
  IF NOT FOUND OR sku.item_id <> NEW.item_id THEN
    PERFORM core.raise_hk('HK_INV_SKU_NOT_FOUND', 'variant does not belong to item');
  END IF;
  IF sku.item_type <> 'stock' THEN
    PERFORM core.raise_hk('HK_INV_NOT_STOCK_ITEM', 'only stock items have stock moves');
  END IF;
  IF sku.track_batch AND NEW.batch_id IS NULL THEN
    PERFORM core.raise_hk('HK_INV_BATCH_REQUIRED', 'batch-tracked item needs batch_id');
  ELSIF NOT sku.track_batch AND NEW.batch_id IS NOT NULL THEN
    PERFORM core.raise_hk('HK_INV_BATCH_NOT_TRACKED', 'item is not batch-tracked');
  END IF;
  IF NOT inventory.rule_allowed(NEW.move_kind, NEW.valuation_rule) THEN
    PERFORM core.raise_hk('HK_INV_MOVE_RULE', format('valuation rule %s not allowed for %s', NEW.valuation_rule, NEW.move_kind));
  END IF;
  v_expect := inventory.kind_sign(NEW.move_kind) * CASE WHEN NEW.reversal_of_move_id IS NULL THEN 1 ELSE -1 END;
  IF sign(NEW.qty_base) <> v_expect THEN
    PERFORM core.raise_hk('HK_INV_MOVE_SIGN', format('%s quantity must be %s', NEW.move_kind, CASE WHEN v_expect > 0 THEN 'positive' ELSE 'negative' END));
  END IF;
  v_base_qty := catalog.convert_qty(NEW.item_id, NEW.qty_uom, NEW.uom_id, sku.base_uom_id);
  IF v_base_qty IS NULL OR v_base_qty <> abs(NEW.qty_base) THEN
    PERFORM core.raise_hk('HK_INV_MOVE_UOM', format('qty_base %s does not match %s in uom', NEW.qty_base, NEW.qty_uom));
  END IF;
  SELECT * INTO wh FROM inventory.warehouse w WHERE w.tenant_id = v_t AND w.id = NEW.warehouse_id;
  IF wh.kind = 'transit' AND NEW.move_kind NOT IN ('transfer_out','transfer_in') THEN
    PERFORM core.raise_hk('HK_INV_TRANSIT_KIND', 'transit warehouse accepts only transfer moves');
  END IF;
  IF NOT wh.is_active AND NEW.reversal_of_move_id IS NULL THEN
    PERFORM core.raise_hk('HK_INV_WAREHOUSE_INACTIVE', 'warehouse is inactive');
  END IF;
  NEW.branch_id := wh.branch_id;
  -- برگشت (ابطال): همان کلید، مقدار قرینه، همان تاریخ
  IF NEW.reversal_of_move_id IS NOT NULL THEN
    SELECT * INTO src FROM inventory.stock_move s WHERE s.tenant_id = v_t AND s.id = NEW.reversal_of_move_id;
    IF src.reversal_of_move_id IS NOT NULL OR src.variant_id <> NEW.variant_id OR src.warehouse_id <> NEW.warehouse_id
       OR src.batch_id IS DISTINCT FROM NEW.batch_id OR src.move_kind <> NEW.move_kind OR src.qty_base <> -NEW.qty_base
       OR src.move_date <> NEW.move_date THEN
      PERFORM core.raise_hk('HK_INV_REVERSAL_MISMATCH', 'reversal must mirror the original move (same key, kind, date; negated qty)');
    END IF;
  END IF;
  -- منبع بها
  IF NEW.cost_source_move_id IS NOT NULL THEN
    SELECT * INTO src FROM inventory.stock_move s WHERE s.tenant_id = v_t AND s.id = NEW.cost_source_move_id;
    IF src.variant_id <> NEW.variant_id OR src.reversal_of_move_id IS NOT NULL OR NEW.move_date < src.move_date
       OR abs(NEW.qty_base) > abs(src.qty_base)
       OR NOT ((NEW.move_kind = 'transfer_in' AND src.move_kind = 'transfer_out')
            OR (NEW.move_kind = 'sale_return' AND src.move_kind = 'sale_issue')
            OR (NEW.move_kind = 'purchase_return' AND src.move_kind IN ('receipt','opening'))) THEN
      PERFORM core.raise_hk('HK_INV_COST_SOURCE', 'cost source must be the matching earlier move of the same SKU');
    END IF;
  END IF;
  -- افتتاحیه: نخستین حرکت کلید است و هیچ حرکتی پیش از آن نمی‌آید
  IF NEW.move_kind = 'opening' AND NEW.reversal_of_move_id IS NULL THEN
    IF EXISTS (SELECT 1 FROM inventory.stock_move s
                WHERE s.tenant_id = v_t AND s.company_id = NEW.company_id AND s.warehouse_id = NEW.warehouse_id
                  AND s.variant_id = NEW.variant_id AND s.batch_id IS NOT DISTINCT FROM NEW.batch_id
                  AND s.move_kind <> 'opening' AND s.move_date < NEW.move_date) THEN
      PERFORM core.raise_hk('HK_INV_OPENING_NOT_FIRST', 'opening must precede every other move of the same key');
    END IF;
  ELSE
    SELECT min(s.move_date) INTO v_open FROM inventory.stock_move s
     WHERE s.tenant_id = v_t AND s.company_id = NEW.company_id AND s.warehouse_id = NEW.warehouse_id
       AND s.variant_id = NEW.variant_id AND s.batch_id IS NOT DISTINCT FROM NEW.batch_id
       AND s.move_kind = 'opening' AND s.reversal_of_move_id IS NULL;
    IF v_open IS NOT NULL AND NEW.move_date < v_open AND NEW.reversal_of_move_id IS NULL THEN
      PERFORM core.raise_hk('HK_INV_BEFORE_OPENING', format('move dated before the opening balance (%s)', v_open));
    END IF;
  END IF;
  -- بچ مسدود/فراخوان‌شده و بچ منقضی در فروش (سیاست از تنظیمات؛ صندوق آفلاین فقط استثنا ثبت می‌کند)
  IF NEW.batch_id IS NOT NULL AND NEW.move_kind IN ('sale_issue','backflush') AND NEW.reversal_of_move_id IS NULL THEN
    SELECT x.status, x.batch_no, x.expiry_date INTO v_bstatus, v_bno, v_bexp FROM inventory.batch x WHERE x.tenant_id = v_t AND x.id = NEW.batch_id;
    IF v_bstatus <> 'active' AND NEW.origin <> 'offline_device' THEN
      PERFORM core.raise_hk('HK_INV_BATCH_BLOCKED', format('batch %s is %s', v_bno, v_bstatus));
    END IF;
    IF v_bexp IS NOT NULL AND v_bexp < NEW.move_date AND NEW.origin <> 'offline_device'
       AND core.setting_effective('inventory.expired_batch_sale', NEW.company_id, wh.branch_id, NULL) = '"block"'::jsonb THEN
      PERFORM core.raise_hk('HK_INV_BATCH_EXPIRED', format('batch %s expired on %s', v_bno, v_bexp));
    END IF;
  END IF;
  NEW.pool_id := inventory.pool_acquire(NEW.company_id, NEW.item_id, NEW.variant_id, NEW.warehouse_id, NEW.move_date);
  NEW.posting_seq := nextval('inventory.posting_seq');
  NEW.created_at := now();
  RETURN NEW;
END $$;

-- ---------- تریگر AFTER INSERT روی stock_move (definer): موجودی، سیاست منفی، ارزیابی ----------
CREATE OR REPLACE FUNCTION inventory.stock_move_after() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  wh inventory.warehouse; pol inventory.company_policy; p inventory.cost_pool; v_bal numeric; v_min numeric;
  v_eff text; v_backdated boolean; v_status text; b inventory.batch;
BEGIN
  SELECT * INTO wh FROM inventory.warehouse w WHERE w.tenant_id = NEW.tenant_id AND w.id = NEW.warehouse_id;
  pol := inventory.policy_on(NEW.company_id, NEW.move_date);
  SELECT * INTO p FROM inventory.cost_pool c WHERE c.tenant_id = NEW.tenant_id AND c.id = NEW.pool_id;
  v_backdated := p.last_date IS NOT NULL AND (NEW.move_date, NEW.posting_seq) < (p.last_date, p.last_seq);

  -- موجودی جاری
  INSERT INTO inventory.stock_balance AS sb (tenant_id, company_id, warehouse_id, item_id, variant_id, batch_id, qty, last_move_date)
  VALUES (NEW.tenant_id, NEW.company_id, NEW.warehouse_id, NEW.item_id, NEW.variant_id, NEW.batch_id, NEW.qty_base, NEW.move_date)
  ON CONFLICT (tenant_id, warehouse_id, variant_id, batch_id)
  DO UPDATE SET qty = sb.qty + EXCLUDED.qty, last_move_date = greatest(sb.last_move_date, EXCLUDED.last_move_date), updated_at = now()
  RETURNING sb.qty INTO v_bal;

  -- سیاست موجودی منفی (انبار در راه همیشه block؛ صندوق آفلاین هرگز رد نمی‌شود ولی استثنا ثبت می‌کند)
  IF NEW.qty_base < 0 THEN
    v_eff := CASE WHEN wh.kind = 'transit' THEN 'block' WHEN wh.negative_policy = 'inherit' THEN pol.negative_stock_default ELSE wh.negative_policy END;
    v_min := v_bal;
    IF v_eff = 'block' AND v_backdated THEN
      SELECT min(x.run) INTO v_min FROM (
        SELECT s.move_date, s.posting_seq,
               sum(s.qty_base) OVER (ORDER BY s.move_date, s.posting_seq ROWS UNBOUNDED PRECEDING) AS run
          FROM inventory.stock_move s
         WHERE s.tenant_id = NEW.tenant_id AND s.warehouse_id = NEW.warehouse_id AND s.variant_id = NEW.variant_id
           AND s.batch_id IS NOT DISTINCT FROM NEW.batch_id) x
       WHERE (x.move_date, x.posting_seq) >= (NEW.move_date, NEW.posting_seq);
    END IF;
    IF v_min < 0 THEN
      IF v_eff = 'block' AND NOT (NEW.origin = 'offline_device' AND wh.kind <> 'transit') THEN
        PERFORM core.raise_hk('HK_INV_NEGATIVE_STOCK', format('warehouse %s would go negative (%s)', wh.code, v_min));
      ELSIF v_eff IN ('allow_warn','block') THEN
        INSERT INTO inventory.stock_exception (tenant_id, company_id, kind, move_id, warehouse_id, variant_id, qty_after, detail)
        VALUES (NEW.tenant_id, NEW.company_id, 'negative_stock', NEW.id, NEW.warehouse_id, NEW.variant_id, v_min,
                jsonb_build_object('policy', v_eff, 'origin', NEW.origin, 'backdated', v_backdated));
      END IF;
    END IF;
  END IF;

  -- بچ منقضی در فروش
  IF NEW.batch_id IS NOT NULL AND NEW.move_kind IN ('sale_issue','backflush') AND NEW.reversal_of_move_id IS NULL THEN
    SELECT * INTO b FROM inventory.batch x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.batch_id;
    IF b.expiry_date IS NOT NULL AND b.expiry_date < NEW.move_date THEN
      INSERT INTO inventory.stock_exception (tenant_id, company_id, kind, move_id, warehouse_id, variant_id, detail)
      VALUES (NEW.tenant_id, NEW.company_id, 'expired_batch', NEW.id, NEW.warehouse_id, NEW.variant_id,
              jsonb_build_object('batch_no', b.batch_no, 'expiry_date', b.expiry_date));
    END IF;
  END IF;

  -- ارزیابی
  PERFORM inventory.valuate(NEW, 'initial', NULL, NULL);
  SELECT l.cost_status INTO v_status FROM inventory.valuation_layer l
   WHERE l.tenant_id = NEW.tenant_id AND l.move_id = NEW.id AND l.layer_kind = 'initial';
  IF v_status = 'unknown' THEN
    INSERT INTO inventory.stock_exception (tenant_id, company_id, kind, move_id, warehouse_id, variant_id, detail)
    VALUES (NEW.tenant_id, NEW.company_id, 'unknown_cost', NEW.id, NEW.warehouse_id, NEW.variant_id, '{}'::jsonb);
  END IF;
  IF v_backdated THEN
    UPDATE inventory.cost_pool c
       SET move_count = c.move_count + 1, dirty_since = coalesce(c.dirty_since, now()),
           dirty_from_date = CASE WHEN c.dirty_from_date IS NULL OR (NEW.move_date, NEW.posting_seq) < (c.dirty_from_date, c.dirty_from_seq)
                                  THEN NEW.move_date ELSE c.dirty_from_date END,
           dirty_from_seq  = CASE WHEN c.dirty_from_date IS NULL OR (NEW.move_date, NEW.posting_seq) < (c.dirty_from_date, c.dirty_from_seq)
                                  THEN NEW.posting_seq ELSE c.dirty_from_seq END
     WHERE c.id = NEW.pool_id;
  ELSE
    UPDATE inventory.cost_pool c SET last_date = NEW.move_date, last_seq = NEW.posting_seq, move_count = c.move_count + 1
     WHERE c.id = NEW.pool_id;
  END IF;
  RETURN NULL;
END $$;

-- ---------- پس از درج همهٔ سریال‌ها (deferred): تعداد سریال = مقدار حرکت ----------
CREATE OR REPLACE FUNCTION inventory.stock_move_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_serial boolean; v_n bigint;
BEGIN
  SELECT s.track_serial INTO v_serial FROM catalog.v_sku s WHERE s.variant_id = NEW.variant_id;
  SELECT count(*) INTO v_n FROM inventory.serial_move x WHERE x.tenant_id = NEW.tenant_id AND x.move_id = NEW.id;
  IF v_serial AND v_n <> abs(NEW.qty_base) THEN
    PERFORM core.raise_hk('HK_INV_SERIAL_COUNT', format('serial-tracked move needs %s serials, got %s', abs(NEW.qty_base), v_n));
  ELSIF NOT v_serial AND v_n > 0 THEN
    PERFORM core.raise_hk('HK_INV_SERIAL_NOT_TRACKED', 'item is not serial-tracked');
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_stock_move_before ON inventory.stock_move;
CREATE TRIGGER trg_stock_move_before BEFORE INSERT ON inventory.stock_move
  FOR EACH ROW EXECUTE FUNCTION inventory.stock_move_before();
DROP TRIGGER IF EXISTS trg_stock_move_after ON inventory.stock_move;
CREATE TRIGGER trg_stock_move_after AFTER INSERT ON inventory.stock_move
  FOR EACH ROW EXECUTE FUNCTION inventory.stock_move_after();
DROP TRIGGER IF EXISTS trg_stock_move_verify ON inventory.stock_move;
CREATE CONSTRAINT TRIGGER trg_stock_move_verify AFTER INSERT ON inventory.stock_move
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION inventory.stock_move_verify();
DROP TRIGGER IF EXISTS trg_immutable ON inventory.stock_move;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON inventory.stock_move
  FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- ---------- سریال ----------
CREATE OR REPLACE FUNCTION inventory.serial_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_track boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT bool_or(s.track_serial) INTO v_track FROM catalog.v_sku s WHERE s.variant_id = NEW.variant_id AND s.item_id = NEW.item_id;
    IF NOT coalesce(v_track, false) THEN
      PERFORM core.raise_hk('HK_INV_SERIAL_NOT_TRACKED', 'item is not serial-tracked');
    END IF;
    IF NEW.status <> 'registered' OR NEW.warehouse_id IS NOT NULL OR NEW.last_move_id IS NOT NULL THEN
      PERFORM core.raise_hk('HK_INV_SERIAL_STATE', 'a new serial starts as registered; its state changes only through moves');
    END IF;
  ELSIF NEW.item_id <> OLD.item_id OR NEW.variant_id <> OLD.variant_id OR NEW.serial_no <> OLD.serial_no THEN
    PERFORM core.raise_hk('HK_INV_SERIAL_IMMUTABLE', 'serial identity is immutable');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_serial_guard ON inventory.serial;
CREATE TRIGGER trg_serial_guard BEFORE INSERT OR UPDATE ON inventory.serial
  FOR EACH ROW EXECUTE FUNCTION inventory.serial_guard();
DROP TRIGGER IF EXISTS trg_touch ON inventory.serial;
CREATE TRIGGER trg_touch BEFORE UPDATE ON inventory.serial FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE OR REPLACE FUNCTION inventory.serial_move_before() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE mv inventory.stock_move; s inventory.serial;
BEGIN
  SELECT * INTO mv FROM inventory.stock_move x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.move_id;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_INV_MOVE_NOT_FOUND', 'stock move not found'); END IF;
  SELECT * INTO s FROM inventory.serial x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.serial_id;
  IF s.variant_id <> mv.variant_id OR s.item_id <> mv.item_id OR s.batch_id IS DISTINCT FROM coalesce(mv.batch_id, s.batch_id) THEN
    PERFORM core.raise_hk('HK_INV_SERIAL_SKU', 'serial does not belong to the moved SKU/batch');
  END IF;
  NEW.company_id := mv.company_id;
  NEW.qty_sign := sign(mv.qty_base)::smallint;
  NEW.warehouse_id := mv.warehouse_id;
  NEW.created_at := now();
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION inventory.serial_move_after() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE mv inventory.stock_move; s inventory.serial; v_ok boolean; v_wdays integer;
BEGIN
  SELECT * INTO mv FROM inventory.stock_move x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.move_id;
  SELECT * INTO s FROM inventory.serial x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.serial_id FOR UPDATE;
  IF NEW.qty_sign > 0 THEN
    v_ok := s.status IN ('registered','out');
  ELSE
    v_ok := s.status = 'in_stock' AND s.warehouse_id = NEW.warehouse_id;
  END IF;
  IF NOT v_ok THEN
    IF mv.origin <> 'offline_device' THEN
      PERFORM core.raise_hk('HK_INV_SERIAL_STATE', format('serial %s is %s and cannot move %s here', s.serial_no, s.status,
                            CASE WHEN NEW.qty_sign > 0 THEN 'in' ELSE 'out' END));
    END IF;
    INSERT INTO inventory.stock_exception (tenant_id, company_id, kind, move_id, warehouse_id, variant_id, serial_id, detail)
    VALUES (NEW.tenant_id, NEW.company_id, 'serial_conflict', NEW.move_id, NEW.warehouse_id, mv.variant_id, NEW.serial_id,
            jsonb_build_object('status_before', s.status, 'warehouse_before', s.warehouse_id));
  END IF;
  IF NEW.qty_sign > 0 THEN
    UPDATE inventory.serial SET status = 'in_stock', company_id = NEW.company_id, warehouse_id = NEW.warehouse_id,
           last_move_id = NEW.move_id, last_move_kind = mv.move_kind,
           batch_id = coalesce(batch_id, mv.batch_id)
     WHERE id = s.id;
  ELSE
    SELECT i.warranty_days INTO v_wdays FROM catalog.item i WHERE i.tenant_id = NEW.tenant_id AND i.id = mv.item_id;
    UPDATE inventory.serial SET status = 'out', warehouse_id = NULL, last_move_id = NEW.move_id, last_move_kind = mv.move_kind,
           warranty_start = CASE WHEN mv.move_kind = 'sale_issue' AND mv.reversal_of_move_id IS NULL AND v_wdays IS NOT NULL
                                 THEN mv.move_date ELSE warranty_start END,
           warranty_end   = CASE WHEN mv.move_kind = 'sale_issue' AND mv.reversal_of_move_id IS NULL AND v_wdays IS NOT NULL
                                 THEN mv.move_date + v_wdays ELSE warranty_end END,
           sold_to_party_id = CASE WHEN mv.move_kind = 'sale_issue' AND mv.reversal_of_move_id IS NULL THEN mv.party_id ELSE sold_to_party_id END
     WHERE id = s.id;
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_serial_move_before ON inventory.serial_move;
CREATE TRIGGER trg_serial_move_before BEFORE INSERT ON inventory.serial_move
  FOR EACH ROW EXECUTE FUNCTION inventory.serial_move_before();
DROP TRIGGER IF EXISTS trg_serial_move_after ON inventory.serial_move;
CREATE TRIGGER trg_serial_move_after AFTER INSERT ON inventory.serial_move
  FOR EACH ROW EXECUTE FUNCTION inventory.serial_move_after();
DROP TRIGGER IF EXISTS trg_immutable ON inventory.serial_move;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON inventory.serial_move
  FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

DROP TRIGGER IF EXISTS trg_immutable ON inventory.valuation_layer;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON inventory.valuation_layer
  FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- ---------- تعدیل بهای ثابت (هزینهٔ جانبی، تفاوت قیمت، تعیین بهای نامعلوم، تجدید ارزیابی دستی) ----------
CREATE OR REPLACE FUNCTION inventory.add_cost_adjustment(p_move_id uuid, p_delta numeric, p_reason text,
                                                         p_source_module text, p_source_doc_type text, p_source_doc_id uuid,
                                                         p_gl_date date)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_t uuid := inventory.require_tenant(); mv inventory.stock_move; v_id uuid; v_minor smallint; v_fixed numeric;
BEGIN
  IF p_reason NOT IN ('landed_cost','price_difference','cost_resolution','manual_revaluation') THEN
    PERFORM core.raise_hk('HK_INV_ADJUST_REASON', 'invalid fixed-cost adjustment reason');
  END IF;
  SELECT * INTO mv FROM inventory.stock_move s WHERE s.tenant_id = v_t AND s.id = p_move_id;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_INV_MOVE_NOT_FOUND', 'stock move not found'); END IF;
  IF mv.valuation_rule <> 'input' OR mv.qty_base < 0 OR mv.reversal_of_move_id IS NOT NULL
     OR EXISTS (SELECT 1 FROM inventory.stock_move r WHERE r.tenant_id = v_t AND r.reversal_of_move_id = mv.id) THEN
    PERFORM core.raise_hk('HK_INV_ADJUST_TARGET', 'fixed cost adjustments apply only to live incoming moves with an input cost');
  END IF;
  v_minor := inventory.company_minor(mv.company_id);
  IF p_delta = 0 OR p_delta <> round(p_delta, v_minor) THEN
    PERFORM core.raise_hk('HK_INV_ADJUST_AMOUNT', 'delta must be non-zero and rounded to the currency minor unit');
  END IF;
  SELECT coalesce(sum(l.value), 0) INTO v_fixed FROM inventory.valuation_layer l
   WHERE l.tenant_id = v_t AND l.move_id = mv.id AND NOT l.is_derived;
  IF v_fixed + p_delta < 0 THEN
    PERFORM core.raise_hk('HK_INV_ADJUST_NEGATIVE', 'incoming value cannot become negative');
  END IF;
  PERFORM 1 FROM inventory.cost_pool c WHERE c.id = mv.pool_id FOR UPDATE;
  INSERT INTO inventory.valuation_layer (tenant_id, company_id, pool_id, move_id, layer_kind, is_derived, reason, value, cost_status,
                                         gl_date, source_module, source_doc_type, source_doc_id)
  VALUES (v_t, mv.company_id, mv.pool_id, mv.id, 'adjustment', false, p_reason, p_delta, 'known',
          greatest(mv.move_date, coalesce(p_gl_date, mv.move_date)), p_source_module, p_source_doc_type, p_source_doc_id)
  RETURNING id INTO v_id;
  UPDATE inventory.cost_pool c
     SET dirty_from_date = mv.move_date, dirty_from_seq = mv.posting_seq, dirty_since = coalesce(c.dirty_since, now())
   WHERE c.id = mv.pool_id
     AND (c.dirty_from_date IS NULL OR (mv.move_date, mv.posting_seq) < (c.dirty_from_date, c.dirty_from_seq));
  RETURN v_id;
END $$;

-- ---------- بازارزیابی (repost) یک استخر از نقطهٔ کثیف؛ idempotent: استخر تمیز ← ۰ ----------
CREATE OR REPLACE FUNCTION inventory.repost_pool(p_pool_id uuid, p_run_id uuid, p_gl_floor date) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_t uuid := inventory.require_tenant(); p inventory.cost_pool; cp inventory.pool_checkpoint; mv inventory.stock_move;
  v_layers integer := 0; v_scanned integer := 0; v_last_date date; v_last_seq bigint; v_run inventory.repost_run;
BEGIN
  SELECT * INTO v_run FROM inventory.repost_run r WHERE r.tenant_id = v_t AND r.id = p_run_id;
  IF NOT FOUND OR v_run.status <> 'running' THEN
    PERFORM core.raise_hk('HK_INV_REPOST_RUN', 'repost run must exist and be running');
  END IF;
  SELECT * INTO p FROM inventory.cost_pool c WHERE c.tenant_id = v_t AND c.id = p_pool_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_INV_POOL_NOT_FOUND', 'cost pool not found'); END IF;
  IF p.company_id <> v_run.company_id THEN PERFORM core.raise_hk('HK_INV_REPOST_RUN', 'run belongs to another company'); END IF;
  IF p.dirty_from_date IS NULL THEN RETURN 0; END IF;
  SELECT * INTO cp FROM inventory.pool_checkpoint k
   WHERE k.tenant_id = v_t AND k.pool_id = p.id AND (k.point_date, k.point_seq) < (p.dirty_from_date, p.dirty_from_seq)
   ORDER BY k.point_date DESC, k.point_seq DESC LIMIT 1;
  DELETE FROM inventory.pool_checkpoint k
   WHERE k.tenant_id = v_t AND k.pool_id = p.id AND (k.point_date, k.point_seq) >= (p.dirty_from_date, p.dirty_from_seq);
  DELETE FROM inventory.fifo_layer f WHERE f.tenant_id = v_t AND f.pool_id = p.id;
  IF cp.id IS NOT NULL THEN
    UPDATE inventory.cost_pool SET qty = cp.qty, value = cp.value, deficit_qty = cp.deficit_qty, deficit_value = cp.deficit_value,
           last_unit_cost = cp.last_unit_cost WHERE id = p.id;
    INSERT INTO inventory.fifo_layer (tenant_id, pool_id, move_id, point_date, point_seq, qty_in, qty_remaining, value_remaining)
    SELECT v_t, p.id, (e->>'move_id')::uuid, (e->>'point_date')::date, (e->>'point_seq')::bigint,
           (e->>'qty_in')::numeric, (e->>'qty_remaining')::numeric, (e->>'value_remaining')::numeric
      FROM jsonb_array_elements(cp.fifo_state) e;
  ELSE
    UPDATE inventory.cost_pool SET qty = 0, value = 0, deficit_qty = 0, deficit_value = 0, last_unit_cost = NULL WHERE id = p.id;
  END IF;
  FOR mv IN SELECT * FROM inventory.stock_move s
             WHERE s.tenant_id = v_t AND s.pool_id = p.id
               AND (cp.id IS NULL OR (s.move_date, s.posting_seq) > (cp.point_date, cp.point_seq))
             ORDER BY s.move_date, s.posting_seq LOOP
    v_layers := v_layers + inventory.valuate(mv, 'replay', p_run_id, p_gl_floor);
    v_scanned := v_scanned + 1;
    v_last_date := mv.move_date; v_last_seq := mv.posting_seq;
  END LOOP;
  UPDATE inventory.cost_pool
     SET dirty_from_date = NULL, dirty_from_seq = NULL, dirty_since = NULL,
         last_date = coalesce(v_last_date, cp.point_date, last_date), last_seq = coalesce(v_last_seq, cp.point_seq, last_seq),
         updated_at = now()
   WHERE id = p.id;
  UPDATE inventory.repost_run r
     SET pools_processed = r.pools_processed + 1, moves_scanned = r.moves_scanned + v_scanned, layers_added = r.layers_added + v_layers,
         total_delta = r.total_delta + coalesce((SELECT sum(l.value) FROM inventory.valuation_layer l
                                                  WHERE l.tenant_id = v_t AND l.repost_run_id = p_run_id AND l.pool_id = p.id), 0)
   WHERE r.id = p_run_id;
  RETURN v_layers;
END $$;

-- ---------- نقطهٔ بازیابی (فقط استخر تمیز) ----------
CREATE OR REPLACE FUNCTION inventory.create_checkpoint(p_pool_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_t uuid := inventory.require_tenant(); p inventory.cost_pool; v_id uuid;
BEGIN
  SELECT * INTO p FROM inventory.cost_pool c WHERE c.tenant_id = v_t AND c.id = p_pool_id FOR UPDATE;
  IF NOT FOUND OR p.dirty_from_date IS NOT NULL OR p.last_date IS NULL THEN
    PERFORM core.raise_hk('HK_INV_CHECKPOINT_STATE', 'checkpoint needs a clean pool with moves');
  END IF;
  INSERT INTO inventory.pool_checkpoint (tenant_id, pool_id, point_date, point_seq, qty, value, deficit_qty, deficit_value, last_unit_cost, fifo_state)
  SELECT v_t, p.id, p.last_date, p.last_seq, p.qty, p.value, p.deficit_qty, p.deficit_value, p.last_unit_cost,
         coalesce((SELECT jsonb_agg(jsonb_build_object('move_id', f.move_id, 'point_date', f.point_date, 'point_seq', f.point_seq,
                                                       'qty_in', f.qty_in, 'qty_remaining', f.qty_remaining, 'value_remaining', f.value_remaining)
                                    ORDER BY f.point_date, f.point_seq)
                     FROM inventory.fifo_layer f WHERE f.tenant_id = v_t AND f.pool_id = p.id AND f.qty_remaining > 0), '[]'::jsonb)
  ON CONFLICT (tenant_id, pool_id, point_date, point_seq) DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------- راستی‌آزمایی بدون اثر: بازپخش کامل در زیرتراکنش و برگرداندن تعداد لایه‌های اصلاحی (۰ = سازگار) ----------
CREATE OR REPLACE FUNCTION inventory.verify_pool_replay(p_pool_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_t uuid := inventory.require_tenant(); p inventory.cost_pool; v_run uuid; n integer; v_first record;
BEGIN
  SELECT * INTO p FROM inventory.cost_pool c WHERE c.tenant_id = v_t AND c.id = p_pool_id;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_INV_POOL_NOT_FOUND', 'cost pool not found'); END IF;
  SELECT s.move_date, s.posting_seq INTO v_first FROM inventory.stock_move s
   WHERE s.tenant_id = v_t AND s.pool_id = p.id ORDER BY s.move_date, s.posting_seq LIMIT 1;
  IF NOT FOUND THEN RETURN 0; END IF;
  BEGIN
    INSERT INTO inventory.repost_run (tenant_id, company_id, trigger_reason, gl_floor_date)
    VALUES (v_t, p.company_id, 'integrity', v_first.move_date) RETURNING id INTO v_run;
    DELETE FROM inventory.pool_checkpoint k WHERE k.tenant_id = v_t AND k.pool_id = p.id;
    UPDATE inventory.cost_pool SET dirty_from_date = v_first.move_date, dirty_from_seq = v_first.posting_seq, dirty_since = now()
     WHERE id = p.id;
    n := inventory.repost_pool(p.id, v_run, v_first.move_date);
    RAISE EXCEPTION USING ERRCODE = 'HKV01', MESSAGE = n::text;
  EXCEPTION WHEN SQLSTATE 'HKV01' THEN
    n := SQLERRM::integer;
  END;
  RETURN n;
END $$;

-- مالکیت و بازبینی توابع definer (D-32: مالک NOLOGIN NOBYPASSRLS، search_path ثابت، فهرست مجاز)
ALTER FUNCTION inventory.pool_acquire(uuid, uuid, uuid, uuid, date) OWNER TO hk_inventory_definer;
ALTER FUNCTION inventory.fifo_take(uuid, uuid, numeric, uuid, smallint, numeric) OWNER TO hk_inventory_definer;
ALTER FUNCTION inventory.valuate(inventory.stock_move, text, uuid, date) OWNER TO hk_inventory_definer;
ALTER FUNCTION inventory.stock_move_after() OWNER TO hk_inventory_definer;
ALTER FUNCTION inventory.serial_move_after() OWNER TO hk_inventory_definer;
ALTER FUNCTION inventory.add_cost_adjustment(uuid, numeric, text, text, text, uuid, date) OWNER TO hk_inventory_definer;
ALTER FUNCTION inventory.repost_pool(uuid, uuid, date) OWNER TO hk_inventory_definer;
ALTER FUNCTION inventory.create_checkpoint(uuid) OWNER TO hk_inventory_definer;
ALTER FUNCTION inventory.verify_pool_replay(uuid) OWNER TO hk_inventory_definer;
COMMENT ON FUNCTION inventory.pool_acquire(uuid, uuid, uuid, uuid, date) IS 'HK_DEFINER_REVIEWED: 05-commerce §5-3; creates/locks the caller tenant''s cost pool only';
COMMENT ON FUNCTION inventory.fifo_take(uuid, uuid, numeric, uuid, smallint, numeric) IS 'HK_DEFINER_REVIEWED: 05-commerce §5-3; internal, not executable by hk_app';
COMMENT ON FUNCTION inventory.valuate(inventory.stock_move, text, uuid, date) IS 'HK_DEFINER_REVIEWED: 05-commerce §5-3; internal, not executable by hk_app';
COMMENT ON FUNCTION inventory.stock_move_after() IS 'HK_DEFINER_REVIEWED: 05-commerce §5-3; trigger on inventory.stock_move';
COMMENT ON FUNCTION inventory.serial_move_after() IS 'HK_DEFINER_REVIEWED: 05-commerce §5-3; trigger on inventory.serial_move';
COMMENT ON FUNCTION inventory.add_cost_adjustment(uuid, numeric, text, text, text, uuid, date) IS 'HK_DEFINER_REVIEWED: 05-commerce §5-3; RLS-bound to app.tenant_id';
COMMENT ON FUNCTION inventory.repost_pool(uuid, uuid, date) IS 'HK_DEFINER_REVIEWED: 05-commerce §5-3; RLS-bound to app.tenant_id';
COMMENT ON FUNCTION inventory.create_checkpoint(uuid) IS 'HK_DEFINER_REVIEWED: 05-commerce §5-3; RLS-bound to app.tenant_id';
COMMENT ON FUNCTION inventory.verify_pool_replay(uuid) IS 'HK_DEFINER_REVIEWED: 05-commerce §5-3; side-effect free (subtransaction rolled back)';
REVOKE ALL ON FUNCTION inventory.fifo_take(uuid, uuid, numeric, uuid, smallint, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION inventory.valuate(inventory.stock_move, text, uuid, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION inventory.stock_move_after() FROM PUBLIC;
REVOKE ALL ON FUNCTION inventory.serial_move_after() FROM PUBLIC;
REVOKE ALL ON FUNCTION inventory.pool_acquire(uuid, uuid, uuid, uuid, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION inventory.add_cost_adjustment(uuid, numeric, text, text, text, uuid, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION inventory.repost_pool(uuid, uuid, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION inventory.create_checkpoint(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION inventory.verify_pool_replay(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION inventory.pool_acquire(uuid, uuid, uuid, uuid, date),
                          inventory.add_cost_adjustment(uuid, numeric, text, text, text, uuid, date),
                          inventory.repost_pool(uuid, uuid, date), inventory.create_checkpoint(uuid),
                          inventory.verify_pool_replay(uuid) TO hk_app;

-- =====================================================================
-- ۸. inventory — نگهبان‌های پیکربندی و اسناد
-- =====================================================================

-- سیاست: v1 روش و دامنهٔ استخر را عوض نمی‌کند؛ تغییر حالت فقط از تاریخی که حرکتی پس از آن نیست.
CREATE OR REPLACE FUNCTION inventory.company_policy_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE prev inventory.company_policy; v_moves boolean;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    SELECT EXISTS (SELECT 1 FROM inventory.stock_move s WHERE s.tenant_id = OLD.tenant_id AND s.company_id = OLD.company_id
                                                         AND s.move_date >= OLD.effective_from) INTO v_moves;
    IF v_moves AND (TG_OP = 'DELETE' OR NEW.valuation_method <> OLD.valuation_method OR NEW.inventory_mode <> OLD.inventory_mode
                    OR NEW.cost_pool_scope <> OLD.cost_pool_scope OR NEW.effective_from <> OLD.effective_from
                    OR NEW.company_id <> OLD.company_id) THEN
      PERFORM core.raise_hk('HK_INV_POLICY_LOCKED', 'policy fields are fixed once stock moves exist in its period');
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF EXISTS (SELECT 1 FROM inventory.company_policy p WHERE p.tenant_id = NEW.tenant_id AND p.company_id = NEW.company_id
                                                          AND p.effective_from > NEW.effective_from) THEN
      PERFORM core.raise_hk('HK_INV_POLICY_RETROACTIVE', 'a policy cannot be inserted before a later one');
    END IF;
    SELECT * INTO prev FROM inventory.company_policy p WHERE p.tenant_id = NEW.tenant_id AND p.company_id = NEW.company_id
     ORDER BY p.effective_from DESC LIMIT 1;
    IF FOUND AND (prev.valuation_method <> NEW.valuation_method OR prev.cost_pool_scope <> NEW.cost_pool_scope) THEN
      PERFORM core.raise_hk('HK_INV_POLICY_METHOD_CHANGE', 'changing valuation method or pool scope is a v2 procedure');
    END IF;
    IF EXISTS (SELECT 1 FROM inventory.stock_move s WHERE s.tenant_id = NEW.tenant_id AND s.company_id = NEW.company_id
                                                     AND s.move_date >= NEW.effective_from) THEN
      PERFORM core.raise_hk('HK_INV_POLICY_RETROACTIVE', 'stock moves already exist on or after effective_from');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_policy_guard ON inventory.company_policy;
CREATE TRIGGER trg_policy_guard BEFORE INSERT OR UPDATE OR DELETE ON inventory.company_policy
  FOR EACH ROW EXECUTE FUNCTION inventory.company_policy_guard();

CREATE OR REPLACE FUNCTION inventory.warehouse_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.company_id <> OLD.company_id OR NEW.code <> OLD.code
     OR ((NEW.kind <> OLD.kind OR NEW.branch_id IS DISTINCT FROM OLD.branch_id)
         AND EXISTS (SELECT 1 FROM inventory.stock_move s WHERE s.tenant_id = OLD.tenant_id AND s.warehouse_id = OLD.id)) THEN
    PERFORM core.raise_hk('HK_INV_WAREHOUSE_LOCKED', 'company and code are immutable; kind and branch are fixed after first move');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_warehouse_guard ON inventory.warehouse;
CREATE TRIGGER trg_warehouse_guard BEFORE UPDATE ON inventory.warehouse
  FOR EACH ROW EXECUTE FUNCTION inventory.warehouse_guard();

CREATE OR REPLACE FUNCTION inventory.batch_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_batch boolean; v_expiry boolean;
BEGIN
  SELECT bool_or(s.track_batch), bool_or(s.track_expiry) INTO v_batch, v_expiry FROM catalog.v_sku s WHERE s.item_id = NEW.item_id;
  IF NOT coalesce(v_batch, false) THEN
    PERFORM core.raise_hk('HK_INV_BATCH_NOT_TRACKED', 'item is not batch-tracked');
  END IF;
  IF v_expiry AND NEW.expiry_date IS NULL THEN
    PERFORM core.raise_hk('HK_INV_BATCH_EXPIRY_REQUIRED', 'expiry-tracked item needs expiry_date');
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.item_id <> OLD.item_id OR NEW.batch_no <> OLD.batch_no
       OR NEW.variant_id IS DISTINCT FROM OLD.variant_id
       OR ((NEW.expiry_date IS DISTINCT FROM OLD.expiry_date OR NEW.mfg_date IS DISTINCT FROM OLD.mfg_date)
           AND EXISTS (SELECT 1 FROM inventory.stock_move s WHERE s.tenant_id = OLD.tenant_id AND s.batch_id = OLD.id))) THEN
    PERFORM core.raise_hk('HK_INV_BATCH_LOCKED', 'batch identity is immutable; dates are fixed after first move');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_batch_guard ON inventory.batch;
CREATE TRIGGER trg_batch_guard BEFORE INSERT OR UPDATE ON inventory.batch
  FOR EACH ROW EXECUTE FUNCTION inventory.batch_guard();

-- bundle: ورودی‌ها فقط در پیش‌نویس؛ ارسال با جمع برابر؛ bundle خروجی سریال/بچ تازه نمی‌سازد.
CREATE OR REPLACE FUNCTION inventory.bundle_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_sum numeric; v_new boolean; v_serial boolean; v_nser bigint;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_INV_BUNDLE_LOCKED', 'only draft bundles can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status <> 'draft' THEN
    PERFORM core.raise_hk('HK_INV_BUNDLE_LOCKED', 'posted/cancelled bundles are immutable');
  END IF;
  IF NEW.status = 'posted' THEN
    SELECT coalesce(sum(e.qty_base), 0), bool_or(e.serial_no IS NOT NULL OR e.new_batch_no IS NOT NULL), count(*) FILTER (WHERE e.serial_id IS NOT NULL OR e.serial_no IS NOT NULL)
      INTO v_sum, v_new, v_nser
      FROM inventory.tracking_bundle_entry e WHERE e.tenant_id = NEW.tenant_id AND e.bundle_id = NEW.id;
    SELECT s.track_serial INTO v_serial FROM catalog.v_sku s WHERE s.variant_id = NEW.variant_id;
    IF v_sum <> NEW.total_qty_base THEN
      PERFORM core.raise_hk('HK_INV_BUNDLE_QTY', format('bundle entries sum to %s, expected %s', v_sum, NEW.total_qty_base));
    END IF;
    IF v_serial AND v_nser <> NEW.total_qty_base THEN
      PERFORM core.raise_hk('HK_INV_BUNDLE_QTY', 'serial-tracked bundle needs one serial per unit');
    END IF;
    IF NEW.direction = 'out' AND coalesce(v_new, false) THEN
      PERFORM core.raise_hk('HK_INV_BUNDLE_OUT_NEW', 'outgoing bundle must reference existing serials/batches');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_bundle_guard ON inventory.tracking_bundle;
CREATE TRIGGER trg_bundle_guard BEFORE INSERT OR UPDATE OR DELETE ON inventory.tracking_bundle
  FOR EACH ROW EXECUTE FUNCTION inventory.bundle_guard();

CREATE OR REPLACE FUNCTION inventory.bundle_entry_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text; r record;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  SELECT b.status INTO v_status FROM inventory.tracking_bundle b WHERE b.tenant_id = r.tenant_id AND b.id = r.bundle_id;
  IF v_status IS DISTINCT FROM 'draft' AND v_status IS NOT NULL THEN
    PERFORM core.raise_hk('HK_INV_BUNDLE_LOCKED', 'entries of a posted bundle are immutable');
  END IF;
  RETURN r;
END $$;
DROP TRIGGER IF EXISTS trg_bundle_entry_guard ON inventory.tracking_bundle_entry;
CREATE TRIGGER trg_bundle_entry_guard BEFORE INSERT OR UPDATE OR DELETE ON inventory.tracking_bundle_entry
  FOR EACH ROW EXECUTE FUNCTION inventory.bundle_entry_guard();

-- سند انبار: ماشین حالت و تغییرناپذیری پس از پیش‌نویس
CREATE OR REPLACE FUNCTION inventory.stock_doc_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[]; v_allowed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_INV_DOC_IMMUTABLE', 'only draft documents can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' AND NEW.origin NOT IN ('migration','offline_device','system') THEN
      PERFORM core.raise_hk('HK_INV_DOC_TRANSITION', 'documents start as draft');
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = NEW.status AND OLD.status = 'draft' THEN RETURN NEW; END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN (('draft','posted'),('draft','in_transit'),('in_transit','posted'),
                                       ('in_transit','cancelled'),('posted','cancelled'))) THEN
    PERFORM core.raise_hk('HK_INV_DOC_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  IF OLD.status = 'draft' THEN RETURN NEW; END IF;
  v_changed := inventory.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  v_allowed := ARRAY['status','updated_at','row_version']
            || CASE WHEN (OLD.status, NEW.status) = ('in_transit','posted')
                    THEN ARRAY['received_date','received_at','received_by','gl_receive_journal_id'] ELSE ARRAY[]::text[] END
            || CASE WHEN NEW.status = 'cancelled' THEN ARRAY['cancelled_at','cancelled_by','cancel_reason','cancel_journal_id']
                    ELSE ARRAY[]::text[] END;
  IF NOT (v_changed <@ v_allowed) THEN
    PERFORM core.raise_hk('HK_INV_DOC_IMMUTABLE', format('cannot change %s after posting', array_to_string(v_changed, ',')));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_stock_doc_guard ON inventory.stock_doc;
CREATE TRIGGER trg_stock_doc_guard BEFORE INSERT OR UPDATE OR DELETE ON inventory.stock_doc
  FOR EACH ROW EXECUTE FUNCTION inventory.stock_doc_guard();

-- سطر سند: فقط در پیش‌نویس؛ received_qty_base فقط در in_transit
CREATE OR REPLACE FUNCTION inventory.stock_doc_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text; r record;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  SELECT d.status INTO v_status FROM inventory.stock_doc d WHERE d.tenant_id = r.tenant_id AND d.id = r.doc_id;
  IF v_status IS NULL OR v_status = 'draft' THEN RETURN r; END IF;
  IF TG_OP = 'UPDATE' AND v_status = 'in_transit'
     AND inventory.changed_columns(to_jsonb(OLD), to_jsonb(NEW)) <@ ARRAY['received_qty_base'] THEN
    RETURN NEW;
  END IF;
  PERFORM core.raise_hk('HK_INV_DOC_IMMUTABLE', 'lines can change only while the document is a draft');
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_stock_doc_line_guard ON inventory.stock_doc_line;
CREATE TRIGGER trg_stock_doc_line_guard BEFORE INSERT OR UPDATE OR DELETE ON inventory.stock_doc_line
  FOR EACH ROW EXECUTE FUNCTION inventory.stock_doc_line_guard();

-- انبارگردانی: draft → counting → reviewing → posted؛ لغو پیش از ثبت
CREATE OR REPLACE FUNCTION inventory.count_session_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_INV_COUNT_STATE', 'only draft count sessions can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN PERFORM core.raise_hk('HK_INV_COUNT_STATE', 'count sessions start as draft'); END IF;
    RETURN NEW;
  END IF;
  IF OLD.status IN ('posted','cancelled') THEN
    PERFORM core.raise_hk('HK_INV_COUNT_STATE', 'posted/cancelled count sessions are immutable');
  END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN
       (('draft','counting'),('counting','reviewing'),('reviewing','counting'),('reviewing','posted'),
        ('draft','cancelled'),('counting','cancelled'),('reviewing','cancelled'))) THEN
    PERFORM core.raise_hk('HK_INV_COUNT_STATE', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  IF OLD.status <> 'draft' AND (NEW.warehouse_id <> OLD.warehouse_id OR NEW.count_date <> OLD.count_date
                                OR NEW.scope <> OLD.scope OR NEW.category_id IS DISTINCT FROM OLD.category_id) THEN
    PERFORM core.raise_hk('HK_INV_COUNT_STATE', 'warehouse, date and scope are fixed once counting starts');
  END IF;
  IF NEW.status = 'posted' AND EXISTS (SELECT 1 FROM inventory.count_line l WHERE l.tenant_id = NEW.tenant_id AND l.session_id = NEW.id
                                                                        AND (l.system_qty_base IS NULL OR l.counted_qty_base IS NULL)) THEN
    PERFORM core.raise_hk('HK_INV_COUNT_INCOMPLETE', 'every line needs a system snapshot and an accepted count');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_count_session_guard ON inventory.count_session;
CREATE TRIGGER trg_count_session_guard BEFORE INSERT OR UPDATE OR DELETE ON inventory.count_session
  FOR EACH ROW EXECUTE FUNCTION inventory.count_session_guard();

CREATE OR REPLACE FUNCTION inventory.count_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text; r record;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  SELECT s.status INTO v_status FROM inventory.count_session s WHERE s.tenant_id = r.tenant_id AND s.id = r.session_id;
  IF v_status IN ('posted','cancelled') THEN
    PERFORM core.raise_hk('HK_INV_COUNT_STATE', 'lines of a posted/cancelled count are immutable');
  END IF;
  IF TG_OP <> 'DELETE' AND v_status IN ('draft','counting') AND NEW.system_qty_base IS NOT NULL THEN
    PERFORM core.raise_hk('HK_INV_COUNT_STATE', 'system snapshot is taken only when the session moves to reviewing');
  END IF;
  RETURN r;
END $$;
DROP TRIGGER IF EXISTS trg_count_line_guard ON inventory.count_line;
CREATE TRIGGER trg_count_line_guard BEFORE INSERT OR UPDATE OR DELETE ON inventory.count_line
  FOR EACH ROW EXECUTE FUNCTION inventory.count_line_guard();

CREATE OR REPLACE FUNCTION inventory.count_entry_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s inventory.count_session; v_first uuid;
BEGIN
  SELECT cs.* INTO s FROM inventory.count_line l JOIN inventory.count_session cs ON cs.tenant_id = l.tenant_id AND cs.id = l.session_id
   WHERE l.tenant_id = NEW.tenant_id AND l.id = NEW.line_id;
  IF s.status <> 'counting' AND NOT (s.status = 'reviewing' AND NEW.round_no = 2) THEN
    PERFORM core.raise_hk('HK_INV_COUNT_STATE', 'entries are accepted only while counting (round 2 also in review)');
  END IF;
  IF NEW.round_no > s.rounds THEN
    PERFORM core.raise_hk('HK_INV_COUNT_ROUND', 'session does not have this round');
  END IF;
  IF NEW.round_no = 2 THEN
    SELECT e.counted_by INTO v_first FROM inventory.count_entry e
     WHERE e.tenant_id = NEW.tenant_id AND e.line_id = NEW.line_id AND e.round_no = 1 LIMIT 1;
    IF v_first IS NOT NULL AND v_first = NEW.counted_by THEN
      PERFORM core.raise_hk('HK_INV_COUNT_SAME_COUNTER', 'round 2 must be counted by a different person');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_count_entry_guard ON inventory.count_entry;
CREATE TRIGGER trg_count_entry_guard BEFORE INSERT ON inventory.count_entry
  FOR EACH ROW EXECUTE FUNCTION inventory.count_entry_guard();
DROP TRIGGER IF EXISTS trg_immutable ON inventory.count_entry;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON inventory.count_entry
  FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

CREATE OR REPLACE FUNCTION inventory.periodic_close_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_INV_PERIODIC_STATE', 'only draft closes can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' AND NEW.status <> 'draft' THEN
    PERFORM core.raise_hk('HK_INV_PERIODIC_STATE', 'periodic close starts as draft');
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status <> 'draft' THEN
    IF NOT (OLD.status = 'posted' AND NEW.status = 'reversed'
            AND inventory.changed_columns(to_jsonb(OLD), to_jsonb(NEW)) <@ ARRAY['status','reversal_journal_id','updated_at','row_version']) THEN
      PERFORM core.raise_hk('HK_INV_PERIODIC_STATE', 'posted periodic close can only be reversed');
    END IF;
  END IF;
  IF NEW.status = 'posted' AND NOT EXISTS (SELECT 1 FROM inventory.company_policy p
                                            WHERE p.tenant_id = NEW.tenant_id AND p.company_id = NEW.company_id
                                              AND p.inventory_mode = 'periodic' AND p.effective_from <= NEW.period_from) THEN
    PERFORM core.raise_hk('HK_INV_PERIODIC_MODE', 'company is not in periodic mode for this period');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_periodic_close_guard ON inventory.periodic_close;
CREATE TRIGGER trg_periodic_close_guard BEFORE INSERT OR UPDATE OR DELETE ON inventory.periodic_close
  FOR EACH ROW EXECUTE FUNCTION inventory.periodic_close_guard();

CREATE OR REPLACE FUNCTION inventory.stock_exception_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'resolved' OR (OLD.status = 'acknowledged' AND NEW.status = 'open') THEN
    PERFORM core.raise_hk('HK_INV_EXCEPTION_STATE', 'exceptions move forward only (open → acknowledged → resolved)');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_stock_exception_guard ON inventory.stock_exception;
CREATE TRIGGER trg_stock_exception_guard BEFORE UPDATE ON inventory.stock_exception
  FOR EACH ROW EXECUTE FUNCTION inventory.stock_exception_guard();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['company_policy','warehouse','location','branch_default','reorder_rule','batch','tracking_bundle',
                           'stock_doc','count_session','periodic_close','stock_exception'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_touch ON inventory.%I', t);
    EXECUTE format('CREATE TRIGGER trg_touch BEFORE UPDATE ON inventory.%I FOR EACH ROW EXECUTE FUNCTION core.touch_row()', t);
  END LOOP;
END $$;

-- =====================================================================
-- ۹. inventory — ویوها، زیردفتر، راستی‌آزمایی
-- =====================================================================
-- ارزش هر حرکت (Σ لایه‌ها) و بدترین وضعیت
CREATE OR REPLACE VIEW inventory.v_move_value WITH (security_invoker = true) AS
SELECT m.tenant_id, m.id AS move_id, m.company_id, m.warehouse_id, m.item_id, m.variant_id, m.batch_id, m.move_date, m.posting_seq,
       m.move_kind, m.qty_base, m.pool_id, m.source_module, m.source_doc_type, m.source_doc_id, m.source_line_id,
       coalesce(sum(l.value) FILTER (WHERE NOT l.is_derived), 0) AS fixed_value,
       coalesce(sum(l.value) FILTER (WHERE l.is_derived), 0) AS derived_value,
       coalesce(sum(l.value), 0) AS total_value,
       CASE WHEN bool_or(l.cost_status = 'unknown') THEN 'unknown' WHEN bool_or(l.cost_status = 'estimated') THEN 'estimated'
            ELSE 'known' END AS cost_status
  FROM inventory.stock_move m
  LEFT JOIN inventory.valuation_layer l ON l.tenant_id = m.tenant_id AND l.move_id = m.id
 GROUP BY m.tenant_id, m.id;

-- کاردکس: گردش مقدار و ریالی با ماندهٔ جاری برای هر (انبار، SKU)
CREATE OR REPLACE VIEW inventory.v_kardex WITH (security_invoker = true) AS
SELECT v.*, sum(v.qty_base) OVER w AS running_qty, sum(v.total_value) OVER w AS running_value
  FROM inventory.v_move_value v
WINDOW w AS (PARTITION BY v.tenant_id, v.warehouse_id, v.variant_id ORDER BY v.move_date, v.posting_seq ROWS UNBOUNDED PRECEDING);

-- موجودی جاری با بهای استخر (دامنهٔ شرکت: مقدار × میانگین استخر؛ دامنهٔ انبار: ارزش دقیق استخر)
CREATE OR REPLACE VIEW inventory.v_stock_on_hand WITH (security_invoker = true) AS
SELECT b.tenant_id, b.company_id, b.warehouse_id, b.item_id, b.variant_id, b.batch_id, b.qty, p.id AS pool_id, p.method,
       CASE WHEN p.qty > 0 THEN round(p.value / p.qty, 12) ELSE p.last_unit_cost END AS unit_cost,
       CASE WHEN p.warehouse_id IS NOT NULL AND b.batch_id IS NULL
            THEN p.value
            ELSE round(b.qty * coalesce(CASE WHEN p.qty > 0 THEN p.value / p.qty ELSE p.last_unit_cost END, 0), 4) END AS value,
       (p.dirty_from_date IS NOT NULL) AS valuation_pending
  FROM inventory.stock_balance b
  LEFT JOIN inventory.cost_pool p ON p.tenant_id = b.tenant_id AND p.company_id = b.company_id AND p.variant_id = b.variant_id
                                  AND (p.warehouse_id = b.warehouse_id OR p.warehouse_id IS NULL);

-- دسترس‌پذیری بچ برای FEFO
CREATE OR REPLACE VIEW inventory.v_batch_availability WITH (security_invoker = true) AS
SELECT b.tenant_id, b.company_id, b.warehouse_id, b.variant_id, b.batch_id, x.batch_no, x.expiry_date, x.status, b.qty
  FROM inventory.stock_balance b JOIN inventory.batch x ON x.tenant_id = b.tenant_id AND x.id = b.batch_id
 WHERE b.qty > 0;

-- پیشنهاد FEFO: بچ‌های فعال به ترتیب انقضا (نامنقضی اول، سپس بی‌انقضا) تا پوشش مقدار
CREATE OR REPLACE FUNCTION inventory.fefo_candidates(p_warehouse_id uuid, p_variant_id uuid, p_qty numeric, p_on date)
RETURNS TABLE (batch_id uuid, batch_no text, expiry_date date, available numeric, take numeric)
LANGUAGE sql STABLE AS $$
  WITH c AS (
    SELECT a.batch_id, a.batch_no, a.expiry_date, a.qty AS available,
           sum(a.qty) OVER (ORDER BY a.expiry_date NULLS LAST, a.batch_no ROWS UNBOUNDED PRECEDING) AS cum
      FROM inventory.v_batch_availability a
     WHERE a.warehouse_id = p_warehouse_id AND a.variant_id = p_variant_id AND a.status = 'active'
       AND (a.expiry_date IS NULL OR a.expiry_date >= p_on))
  SELECT c.batch_id, c.batch_no, c.expiry_date, c.available,
         least(c.available, p_qty - (c.cum - c.available)) AS take
    FROM c WHERE c.cum - c.available < p_qty
   ORDER BY c.expiry_date NULLS LAST, c.batch_no
$$;

-- قرارداد زیردفتر ledger (§۵-۱۴ بخش ۰۳): ماندهٔ موجودی به تفکیک حساب GL ثبت‌شده
CREATE OR REPLACE FUNCTION inventory.ledger_subledger_stock(p_company_id uuid, p_as_of date)
RETURNS TABLE (account_id uuid, dim_value_id uuid, currency char(3), balance_base numeric, balance_txn numeric)
LANGUAGE sql STABLE AS $$
  WITH perpetual AS (
    SELECT m.asset_account_id AS account_id, sum(l.value) AS bal
      FROM inventory.valuation_layer l
      JOIN inventory.stock_move m ON m.tenant_id = l.tenant_id AND m.id = l.move_id
     WHERE m.company_id = p_company_id AND m.asset_account_id IS NOT NULL AND l.gl_date <= p_as_of
     GROUP BY m.asset_account_id),
  periodic AS (
    SELECT cl.asset_account_id AS account_id, cl.closing_value AS bal
      FROM inventory.periodic_close c
      JOIN inventory.periodic_close_line cl ON cl.tenant_id = c.tenant_id AND cl.close_id = c.id
     WHERE c.company_id = p_company_id AND c.status = 'posted'
       AND c.period_to = (SELECT max(c2.period_to) FROM inventory.periodic_close c2
                           WHERE c2.company_id = p_company_id AND c2.status = 'posted' AND c2.period_to <= p_as_of))
  SELECT x.account_id, NULL::uuid, (SELECT co.base_currency FROM core.company co WHERE co.id = p_company_id), sum(x.bal), sum(x.bal)
    FROM (SELECT * FROM perpetual UNION ALL SELECT * FROM periodic) x
   GROUP BY x.account_id
$$;

-- سازگاری مشتق‌ها: مقدار استخر = Σ حرکت؛ ارزش استخر تمیز = Σ لایه؛ موجودی انبار = Σ حرکت
CREATE OR REPLACE FUNCTION inventory.verify_derived(p_company_id uuid)
RETURNS TABLE (object_id uuid, problem text)
LANGUAGE sql STABLE AS $$
  SELECT p.id, format('pool qty %s <> moves %s', p.qty, coalesce(m.q, 0))
    FROM inventory.cost_pool p
    LEFT JOIN (SELECT pool_id, sum(qty_base) q FROM inventory.stock_move WHERE company_id = p_company_id GROUP BY pool_id) m ON m.pool_id = p.id
   WHERE p.company_id = p_company_id AND p.qty <> coalesce(m.q, 0)
  UNION ALL
  SELECT p.id, format('clean pool value %s <> layers %s', p.value, coalesce(l.v, 0))
    FROM inventory.cost_pool p
    LEFT JOIN (SELECT pool_id, sum(value) v FROM inventory.valuation_layer WHERE company_id = p_company_id GROUP BY pool_id) l ON l.pool_id = p.id
   WHERE p.company_id = p_company_id AND p.dirty_from_date IS NULL AND p.value <> coalesce(l.v, 0)
  UNION ALL
  SELECT b.id, format('balance %s <> moves %s', b.qty, coalesce(m.q, 0))
    FROM inventory.stock_balance b
    LEFT JOIN (SELECT warehouse_id, variant_id, batch_id, sum(qty_base) q FROM inventory.stock_move
                WHERE company_id = p_company_id GROUP BY 1, 2, 3) m
      ON m.warehouse_id = b.warehouse_id AND m.variant_id = b.variant_id AND m.batch_id IS NOT DISTINCT FROM b.batch_id
   WHERE b.company_id = p_company_id AND b.qty <> coalesce(m.q, 0)
  UNION ALL
  SELECT s.id, format('serial %s state %s disagrees with last move', s.serial_no, s.status)
    FROM inventory.serial s
    JOIN LATERAL (SELECT sm.qty_sign, sm.warehouse_id FROM inventory.serial_move sm
                   WHERE sm.tenant_id = s.tenant_id AND sm.serial_id = s.id ORDER BY sm.created_at DESC, sm.id DESC LIMIT 1) x ON true
   WHERE s.company_id = p_company_id
     AND ((x.qty_sign = 1 AND (s.status <> 'in_stock' OR s.warehouse_id <> x.warehouse_id)) OR (x.qty_sign = -1 AND s.status <> 'out'))
$$;

-- =====================================================================
-- ۱۰. sales — قیمت و تخفیف (موتور قاعده؛ قیمت پایه از catalog.resolve_price)
-- =====================================================================
-- مالیات یک ردیف با روش گرد کردن snapshot شده از قاعدهٔ مالیات (RC_IITP: truncate)
CREATE OR REPLACE FUNCTION sales.tax_part(p_base numeric, p_rate numeric, p_mode text, p_minor smallint) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_mode WHEN 'truncate' THEN trunc(p_base * p_rate / 100, p_minor)
                     WHEN 'half_up'  THEN round(p_base * p_rate / 100, p_minor) END
$$;

CREATE TABLE IF NOT EXISTS sales.pricing_rule (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid,
  code                 text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
  version              integer NOT NULL DEFAULT 1 CHECK (version >= 1),
  name                 text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  status               text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','retired')),
  kind                 text NOT NULL CHECK (kind IN ('line_discount','price_override','tiered','invoice_discount','free_item')),
  priority             smallint NOT NULL DEFAULT 100 CHECK (priority BETWEEN 0 AND 1000),
  stack_group          text CHECK (stack_group ~ '^[a-z][a-z0-9_]{0,30}$'),
  exclusive            boolean NOT NULL DEFAULT false,
  item_id              uuid,
  variant_id           uuid,
  category_id          uuid,
  brand_id             uuid,
  posting_group_id     uuid,
  party_id             uuid,
  party_group_id       uuid,
  branch_id            uuid,
  channel              text CHECK (channel IN ('pos','invoice','online')),
  price_list_id        uuid,
  valid_from           date NOT NULL,
  valid_to             date,
  weekdays             smallint[] CHECK (weekdays <@ ARRAY[0,1,2,3,4,5,6]::smallint[] AND cardinality(weekdays) >= 1),   -- ۰ = شنبه
  time_from            time,
  time_to              time,
  min_qty              core.qty CHECK (min_qty > 0),
  min_amount           core.amount CHECK (min_amount > 0),
  currency             char(3) REFERENCES ref.currency(code),
  discount_percent     numeric(9,6) CHECK (discount_percent > 0 AND discount_percent <= 100),
  discount_amount      core.amount CHECK (discount_amount > 0),
  override_price       core.rate CHECK (override_price >= 0),
  buy_qty              core.qty CHECK (buy_qty > 0),
  free_item_id         uuid,
  free_variant_id      uuid,
  free_uom_id          uuid,
  free_qty             core.qty CHECK (free_qty > 0),
  max_discount_amount  core.amount CHECK (max_discount_amount > 0),
  requires_approval    boolean NOT NULL DEFAULT false,
  first_used_at        timestamptz,
  source_pack          text,
  source_pack_version  text,
  created_by           uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code, version),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, category_id) REFERENCES catalog.item_category(tenant_id, id),
  FOREIGN KEY (tenant_id, brand_id) REFERENCES catalog.brand(tenant_id, id),
  FOREIGN KEY (tenant_id, posting_group_id) REFERENCES catalog.item_posting_group(tenant_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, party_group_id) REFERENCES parties.party_group(tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id) REFERENCES core.branch(tenant_id, id),
  FOREIGN KEY (tenant_id, price_list_id) REFERENCES catalog.price_list(tenant_id, id),
  FOREIGN KEY (tenant_id, free_item_id, free_variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, free_item_id, free_uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT pricing_rule_window CHECK (valid_to IS NULL OR valid_to >= valid_from),
  CONSTRAINT pricing_rule_time_pair CHECK ((time_from IS NULL) = (time_to IS NULL)),
  CONSTRAINT pricing_rule_party_one CHECK (num_nonnulls(party_id, party_group_id) <= 1),
  CONSTRAINT pricing_rule_currency CHECK (num_nonnulls(discount_amount, min_amount, override_price, max_discount_amount) = 0 OR currency IS NOT NULL),
  CONSTRAINT pricing_rule_kind_shape CHECK (
       (kind = 'line_discount'    AND num_nonnulls(discount_percent, discount_amount) = 1 AND override_price IS NULL AND free_qty IS NULL)
    OR (kind = 'price_override'   AND override_price IS NOT NULL AND num_nonnulls(discount_percent, discount_amount, free_qty) = 0)
    OR (kind = 'tiered'           AND num_nonnulls(discount_percent, discount_amount, override_price, free_qty) = 0)
    OR (kind = 'invoice_discount' AND num_nonnulls(discount_percent, discount_amount) = 1 AND override_price IS NULL AND free_qty IS NULL
                                  AND num_nonnulls(item_id, variant_id, category_id, brand_id, posting_group_id) = 0)
    OR (kind = 'free_item'        AND num_nonnulls(buy_qty, free_variant_id, free_uom_id, free_qty) = 4
                                  AND num_nonnulls(discount_percent, discount_amount, override_price) = 0)),
  CONSTRAINT pricing_rule_item_scope CHECK (variant_id IS NULL OR item_id IS NOT NULL),
  CHECK ((source_pack IS NULL) = (source_pack_version IS NULL)),
  -- یک نسخهٔ فعال برای هر کد در هر بازه
  CONSTRAINT pricing_rule_one_active EXCLUDE USING gist (tenant_id WITH =, code WITH =,
    daterange(valid_from, valid_to, '[]') WITH &&) WHERE (status = 'active')
);
SELECT core.enable_tenant_rls('sales.pricing_rule');
CREATE INDEX IF NOT EXISTS pricing_rule_active_idx ON sales.pricing_rule (tenant_id, kind, valid_from) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS sales.pricing_rule_tier (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  rule_id           uuid NOT NULL,
  min_qty           core.qty NOT NULL CHECK (min_qty > 0),
  discount_percent  numeric(9,6) CHECK (discount_percent > 0 AND discount_percent <= 100),
  discount_amount   core.amount CHECK (discount_amount > 0),
  override_price    core.rate CHECK (override_price >= 0),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, rule_id, min_qty),
  FOREIGN KEY (tenant_id, rule_id) REFERENCES sales.pricing_rule(tenant_id, id) ON DELETE CASCADE,
  CHECK (num_nonnulls(discount_percent, discount_amount, override_price) = 1)
);
SELECT core.enable_tenant_rls('sales.pricing_rule_tier');

-- =====================================================================
-- ۱۱. sales — پیش‌فاکتور و سفارش
-- =====================================================================
CREATE TABLE IF NOT EXISTS sales."order" (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  company_id            uuid NOT NULL,
  branch_id             uuid NOT NULL,
  kind                  text NOT NULL CHECK (kind IN ('quotation','order')),
  status                text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','open','won','lost','expired','confirmed','closed','cancelled')),
  doc_date              date NOT NULL,
  valid_until           date,
  number_issued_id      uuid,
  doc_no                text CHECK (char_length(doc_no) BETWEEN 1 AND 100),
  customer_party_id     uuid NOT NULL,
  quotation_id          uuid,
  price_list_id         uuid,
  currency              char(3) NOT NULL REFERENCES ref.currency(code),
  exchange_rate         core.rate NOT NULL DEFAULT 1 CHECK (exchange_rate > 0),
  prices_include_tax    boolean NOT NULL DEFAULT false,
  payment_term_id       uuid,
  salesperson_party_id  uuid,
  delivery_date         date,
  warehouse_id          uuid,
  gross_amount          core.amount NOT NULL DEFAULT 0 CHECK (gross_amount >= 0),
  discount_amount       core.amount NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  tax_amount            core.amount NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  total_amount          core.amount NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  credit_check_id       uuid,
  approval_request_id   uuid,
  notes                 text CHECK (notes = core.fa_normalize_text(notes)),
  custom                jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(custom) = 'object'),
  confirmed_by          uuid,
  confirmed_at          timestamptz,
  closed_at             timestamptz,
  cancel_reason         text,
  created_by            uuid,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, number_issued_id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, customer_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, quotation_id) REFERENCES sales."order"(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, price_list_id) REFERENCES catalog.price_list(tenant_id, id),
  FOREIGN KEY (tenant_id, payment_term_id) REFERENCES parties.payment_term(tenant_id, id),
  FOREIGN KEY (tenant_id, salesperson_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, approval_request_id) REFERENCES core.approval_request(tenant_id, id),
  FOREIGN KEY (tenant_id, confirmed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT order_kind_status CHECK (
       (kind = 'quotation' AND status IN ('draft','open','won','lost','expired','cancelled'))
    OR (kind = 'order'     AND status IN ('draft','confirmed','closed','cancelled'))),
  CONSTRAINT order_number CHECK ((status <> 'draft') = (number_issued_id IS NOT NULL AND doc_no IS NOT NULL)),
  CONSTRAINT order_quotation_link CHECK (quotation_id IS NULL OR kind = 'order'),
  CONSTRAINT order_valid_until CHECK (valid_until IS NULL OR (kind = 'quotation' AND valid_until >= doc_date)),
  CONSTRAINT order_confirmed_meta CHECK (kind = 'quotation' OR (status IN ('confirmed','closed')) = (confirmed_at IS NOT NULL)
                                         OR (status = 'cancelled')),
  CONSTRAINT order_cancel_reason CHECK ((status = 'cancelled') = (cancel_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('sales."order"');
SELECT core.attach_custom_fields('sales."order"', 'sales.order');

CREATE TABLE IF NOT EXISTS sales.order_line (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  order_id              uuid NOT NULL,
  line_no               integer NOT NULL CHECK (line_no BETWEEN 1 AND 100000),
  item_id               uuid NOT NULL,
  variant_id            uuid NOT NULL,
  uom_id                uuid NOT NULL,
  qty                   core.qty NOT NULL CHECK (qty > 0),
  qty_base              core.qty NOT NULL CHECK (qty_base > 0),
  unit_price            core.rate NOT NULL CHECK (unit_price >= 0),
  line_discount_amount  core.amount NOT NULL DEFAULT 0 CHECK (line_discount_amount >= 0),
  net_amount            core.amount NOT NULL CHECK (net_amount >= 0),
  tax_amount            core.amount NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  warehouse_id          uuid,
  delivery_date         date,
  description           text CHECK (description = core.fa_normalize_text(description)),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, order_id, line_no),
  FOREIGN KEY (tenant_id, order_id) REFERENCES sales."order"(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, id)
);
SELECT core.enable_tenant_rls('sales.order_line');

-- =====================================================================
-- ۱۲. sales — حوالهٔ تحویل (و رسید مرجوعی)
-- =====================================================================
CREATE TABLE IF NOT EXISTS sales.delivery (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  company_id            uuid NOT NULL,
  branch_id             uuid NOT NULL,
  direction             text NOT NULL DEFAULT 'out' CHECK (direction IN ('out','return')),
  status                text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','cancelled')),
  doc_date              date NOT NULL,
  number_issued_id      uuid,
  doc_no                text CHECK (char_length(doc_no) BETWEEN 1 AND 100),
  customer_party_id     uuid NOT NULL,
  order_id              uuid,
  original_delivery_id  uuid,
  warehouse_id          uuid NOT NULL,
  shipping_address      text CHECK (shipping_address = core.fa_normalize_text(shipping_address)),
  carrier               text CHECK (carrier = core.fa_normalize_text(carrier)),
  gl_status             text NOT NULL DEFAULT 'pending' CHECK (gl_status IN ('pending','posted','not_required','deferred')),
  gl_journal_id         uuid,
  cancel_journal_id     uuid,
  posted_by             uuid,
  posted_at             timestamptz,
  cancelled_by          uuid,
  cancelled_at          timestamptz,
  cancel_reason         text,
  created_by            uuid,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, number_issued_id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, customer_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, order_id) REFERENCES sales."order"(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, original_delivery_id) REFERENCES sales.delivery(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, cancel_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, posted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, cancelled_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT delivery_number CHECK ((status <> 'draft') = (number_issued_id IS NOT NULL AND doc_no IS NOT NULL AND posted_at IS NOT NULL)),
  CONSTRAINT delivery_cancel CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)),
  CONSTRAINT delivery_return_link CHECK ((direction = 'return') = (original_delivery_id IS NOT NULL)),
  CONSTRAINT delivery_gl_link CHECK ((gl_status = 'posted') = (gl_journal_id IS NOT NULL)),
  CONSTRAINT delivery_gl_when_posted CHECK (status = 'draft' OR gl_status <> 'pending')
);
SELECT core.enable_tenant_rls('sales.delivery');

CREATE TABLE IF NOT EXISTS sales.delivery_line (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  delivery_id       uuid NOT NULL,
  line_no           integer NOT NULL CHECK (line_no BETWEEN 1 AND 100000),
  order_line_id     uuid,
  original_line_id  uuid,
  item_id           uuid NOT NULL,
  variant_id        uuid NOT NULL,
  uom_id            uuid NOT NULL,
  qty               core.qty NOT NULL CHECK (qty > 0),
  qty_base          core.qty NOT NULL CHECK (qty_base > 0),
  bundle_id         uuid,
  description       text CHECK (description = core.fa_normalize_text(description)),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, delivery_id, line_no),
  FOREIGN KEY (tenant_id, delivery_id) REFERENCES sales.delivery(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, order_line_id) REFERENCES sales.order_line(tenant_id, id),
  FOREIGN KEY (tenant_id, original_line_id) REFERENCES sales.delivery_line(tenant_id, id),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, bundle_id) REFERENCES inventory.tracking_bundle(tenant_id, id)
);
SELECT core.enable_tenant_rls('sales.delivery_line');

-- =====================================================================
-- ۱۳. sales — فاکتور، برگشت از فروش، اصلاحی
-- =====================================================================
CREATE TABLE IF NOT EXISTS sales.gl_batch (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  branch_id        uuid NOT NULL,
  batch_date       date NOT NULL,
  source_kind      text NOT NULL CHECK (source_kind IN ('pos_shift','manual')),
  source_ref       uuid,                 -- pos.shift (FK بین‌ماژولی در جهت pos → sales ممکن نیست؛ ارجاع نرم)
  status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open','posted','cancelled')),
  gl_journal_id    uuid,
  posted_at        timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  CHECK ((status = 'posted') = (gl_journal_id IS NOT NULL AND posted_at IS NOT NULL))
);
SELECT core.enable_tenant_rls('sales.gl_batch');

CREATE TABLE IF NOT EXISTS sales.invoice (
  tenant_id                uuid NOT NULL REFERENCES core.tenant(id),
  id                       uuid NOT NULL DEFAULT uuidv7(),
  company_id               uuid NOT NULL,
  branch_id                uuid NOT NULL,
  doc_kind                 text NOT NULL DEFAULT 'invoice' CHECK (doc_kind IN ('invoice','return','correction')),
  status                   text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','cancelled')),
  doc_date                 date NOT NULL,
  issued_at                timestamptz,
  number_issued_id         uuid,
  doc_no                   text CHECK (char_length(doc_no) BETWEEN 1 AND 100),
  number_source            text NOT NULL DEFAULT 'server' CHECK (number_source IN ('server','device')),
  device_id                uuid,
  original_invoice_id      uuid,                  -- ریشهٔ زنجیره (فاکتور اصلی) برای برگشت و اصلاحی
  supersedes_invoice_id    uuid,                  -- اصلاحی: نسخهٔ قبلی (اصلی یا اصلاحی قبلی)
  order_id                 uuid,
  customer_party_id        uuid NOT NULL,
  buyer_name               text CHECK (buyer_name = core.fa_normalize_text(buyer_name)),
  buyer_person_type        text CHECK (buyer_person_type IN ('natural','legal','civil_partnership','foreign_natural','foreign_legal')),
  buyer_national_id        text CHECK (buyer_national_id ~ '^[0-9]{10,12}$'),
  buyer_economic_code      text CHECK (buyer_economic_code ~ '^([0-9]{11}|[0-9]{14})$'),
  buyer_postal_code        text CHECK (buyer_postal_code ~ '^[0-9]{10}$'),
  buyer_branch_code        text CHECK (buyer_branch_code ~ '^[0-9]{4}$'),
  buyer_passport_no        text CHECK (buyer_passport_no ~ '^[A-Z0-9]{5,20}$'),
  currency                 char(3) NOT NULL REFERENCES ref.currency(code),
  currency_minor           smallint NOT NULL CHECK (currency_minor BETWEEN 0 AND 4),
  exchange_rate            core.rate NOT NULL DEFAULT 1 CHECK (exchange_rate > 0),
  price_list_id            uuid,
  prices_include_tax       boolean NOT NULL DEFAULT false,
  pricing_date             date,
  settlement_method        text NOT NULL DEFAULT 'cash' CHECK (settlement_method IN ('cash','credit','mixed')),
  cash_amount              core.amount CHECK (cash_amount >= 0),
  credit_amount            core.amount CHECK (credit_amount >= 0),
  payment_term_id          uuid,
  due_date                 date,
  stock_mode               text NOT NULL DEFAULT 'immediate' CHECK (stock_mode IN ('none','immediate','via_delivery')),
  warehouse_id             uuid,
  gross_amount             core.amount NOT NULL DEFAULT 0 CHECK (gross_amount >= 0),
  line_discount_total      core.amount NOT NULL DEFAULT 0 CHECK (line_discount_total >= 0),
  invoice_discount_mode    text NOT NULL DEFAULT 'none' CHECK (invoice_discount_mode IN ('none','percent','amount')),
  invoice_discount_percent numeric(9,6) CHECK (invoice_discount_percent > 0 AND invoice_discount_percent <= 100),
  invoice_discount_amount  core.amount NOT NULL DEFAULT 0 CHECK (invoice_discount_amount >= 0),
  net_amount               core.amount NOT NULL DEFAULT 0 CHECK (net_amount >= 0),
  vat_amount               core.amount NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
  other_tax_amount         core.amount NOT NULL DEFAULT 0 CHECK (other_tax_amount >= 0),
  other_levy_amount        core.amount NOT NULL DEFAULT 0 CHECK (other_levy_amount >= 0),
  total_amount             core.amount NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  total_base               core.amount NOT NULL DEFAULT 0 CHECK (total_base >= 0),
  moadian_required         boolean NOT NULL DEFAULT false,
  moadian_type             smallint CHECK (moadian_type IN (1,2,3)),
  moadian_pattern          smallint CHECK (moadian_pattern IN (1,2,3,4,5,6,7,8,9,11,13,14)),
  moadian_extra            jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(moadian_extra) = 'object'),
  tax_snapshot             jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(tax_snapshot) = 'object'),
  tax_document_id          uuid,                  -- tax.* (FK بین‌ماژولی §۱۲)
  channel                  text NOT NULL DEFAULT 'invoice' CHECK (channel IN ('invoice','pos','online','migration')),
  source_ref               text CHECK (char_length(source_ref) <= 200),
  salesperson_party_id     uuid,
  gl_mode                  text NOT NULL DEFAULT 'per_document' CHECK (gl_mode IN ('per_document','batched','none')),
  gl_journal_id            uuid,
  gl_batch_id              uuid,
  cancel_journal_id        uuid,
  credit_check_id          uuid,
  approval_request_id      uuid,
  posted_by                uuid,
  posted_at                timestamptz,
  cancelled_by             uuid,
  cancelled_at             timestamptz,
  cancel_reason            text,
  notes                    text CHECK (notes = core.fa_normalize_text(notes)),
  custom                   jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(custom) = 'object'),
  created_by               uuid,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  row_version              integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, number_issued_id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, original_invoice_id) REFERENCES sales.invoice(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, supersedes_invoice_id) REFERENCES sales.invoice(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, order_id) REFERENCES sales."order"(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, customer_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, price_list_id) REFERENCES catalog.price_list(tenant_id, id),
  FOREIGN KEY (tenant_id, payment_term_id) REFERENCES parties.payment_term(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, salesperson_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_batch_id) REFERENCES sales.gl_batch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, cancel_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, approval_request_id) REFERENCES core.approval_request(tenant_id, id),
  FOREIGN KEY (tenant_id, posted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, cancelled_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT invoice_chain_shape CHECK ((doc_kind = 'invoice') = (original_invoice_id IS NULL)
                                       AND (doc_kind = 'correction') = (supersedes_invoice_id IS NOT NULL)),
  CONSTRAINT invoice_number CHECK ((status <> 'draft') = (number_issued_id IS NOT NULL AND doc_no IS NOT NULL
                                                           AND posted_at IS NOT NULL AND issued_at IS NOT NULL)),
  CONSTRAINT invoice_device_number CHECK ((number_source = 'device') = (device_id IS NOT NULL)),
  CONSTRAINT invoice_cancel CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)),
  CONSTRAINT invoice_totals CHECK (net_amount = gross_amount - line_discount_total - invoice_discount_amount
                                   AND total_amount = net_amount + vat_amount + other_tax_amount + other_levy_amount),
  CONSTRAINT invoice_discount_mode_shape CHECK (
       (invoice_discount_mode = 'none'    AND invoice_discount_percent IS NULL AND invoice_discount_amount = 0)
    OR (invoice_discount_mode = 'percent' AND invoice_discount_percent IS NOT NULL)
    OR (invoice_discount_mode = 'amount'  AND invoice_discount_percent IS NULL)),
  -- مؤدیان: setm=3 ⇒ cap + insp = tbill − tvam − todam
  CONSTRAINT invoice_settlement_split CHECK ((settlement_method = 'mixed') = (cash_amount IS NOT NULL AND credit_amount IS NOT NULL)
                                             AND (settlement_method <> 'mixed'
                                                  OR cash_amount + credit_amount = total_amount - vat_amount - other_tax_amount)),
  CONSTRAINT invoice_stock_mode CHECK (stock_mode <> 'immediate' OR warehouse_id IS NOT NULL OR doc_kind = 'correction'),
  CONSTRAINT invoice_due_date CHECK (due_date IS NULL OR due_date >= doc_date),
  CONSTRAINT invoice_gl_shape CHECK (status = 'draft'
       OR (gl_mode = 'per_document' AND gl_journal_id IS NOT NULL AND gl_batch_id IS NULL)
       OR (gl_mode = 'batched' AND gl_batch_id IS NOT NULL AND gl_journal_id IS NULL)
       OR (gl_mode = 'none' AND total_amount = 0 AND gl_journal_id IS NULL AND gl_batch_id IS NULL)),
  CONSTRAINT invoice_cancel_gl CHECK (status <> 'cancelled' OR gl_mode <> 'per_document' OR cancel_journal_id IS NOT NULL),
  CONSTRAINT invoice_moadian_shape CHECK (NOT moadian_required OR status = 'draft'
                                          OR (moadian_type IS NOT NULL AND moadian_pattern IS NOT NULL AND buyer_person_type IS NOT NULL))
);
SELECT core.enable_tenant_rls('sales.invoice');
SELECT core.attach_custom_fields('sales.invoice', 'sales.invoice');
-- زنجیرهٔ اصلاحی خطی است: هر نسخه حداکثر یک اصلاحی ثبت‌شده دارد
CREATE UNIQUE INDEX IF NOT EXISTS invoice_one_correction ON sales.invoice (tenant_id, supersedes_invoice_id)
  WHERE supersedes_invoice_id IS NOT NULL AND status = 'posted';
CREATE INDEX IF NOT EXISTS invoice_customer_idx ON sales.invoice (tenant_id, company_id, customer_party_id, doc_date);
CREATE INDEX IF NOT EXISTS invoice_original_idx ON sales.invoice (tenant_id, original_invoice_id) WHERE original_invoice_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS invoice_batch_idx ON sales.invoice (tenant_id, gl_batch_id) WHERE gl_batch_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS sales.invoice_line (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL DEFAULT uuidv7(),
  invoice_id              uuid NOT NULL,
  line_no                 integer NOT NULL CHECK (line_no BETWEEN 1 AND 100000),
  item_id                 uuid NOT NULL,
  variant_id              uuid NOT NULL,
  uom_id                  uuid NOT NULL,
  qty                     core.qty NOT NULL CHECK (qty > 0),                  -- am
  qty_base                core.qty NOT NULL CHECK (qty_base > 0),
  unit_price              core.rate NOT NULL CHECK (unit_price >= 0),         -- fee
  currency_minor          smallint NOT NULL CHECK (currency_minor BETWEEN 0 AND 4),
  gross_amount            core.amount NOT NULL CHECK (gross_amount >= 0),     -- prdis
  line_discount_amount    core.amount NOT NULL DEFAULT 0 CHECK (line_discount_amount >= 0),
  invoice_discount_alloc  core.amount NOT NULL DEFAULT 0 CHECK (invoice_discount_alloc >= 0),
  discount_amount         core.amount NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),   -- dis
  net_amount              core.amount NOT NULL CHECK (net_amount >= 0),       -- adis
  tax_rounding            text NOT NULL DEFAULT 'truncate' CHECK (tax_rounding IN ('truncate','half_up')),
  vat_rate                numeric(7,4) NOT NULL DEFAULT 0 CHECK (vat_rate >= 0 AND vat_rate <= 100),   -- vra
  vat_amount              core.amount NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),                   -- vam
  other_tax_code          text CHECK (other_tax_code ~ '^[A-Za-z0-9._-]{1,40}$'),                    -- odt
  other_tax_rate          numeric(7,4) NOT NULL DEFAULT 0 CHECK (other_tax_rate >= 0 AND other_tax_rate <= 100),
  other_tax_amount        core.amount NOT NULL DEFAULT 0 CHECK (other_tax_amount >= 0),             -- odam
  other_levy_code         text CHECK (other_levy_code ~ '^[A-Za-z0-9._-]{1,40}$'),                   -- olt
  other_levy_rate         numeric(7,4) NOT NULL DEFAULT 0 CHECK (other_levy_rate >= 0 AND other_levy_rate <= 100),
  other_levy_amount       core.amount NOT NULL DEFAULT 0 CHECK (other_levy_amount >= 0),            -- olam
  line_total              core.amount NOT NULL CHECK (line_total >= 0),       -- tsstam
  tax_category_code       text CHECK (tax_category_code ~ '^[a-z][a-z0-9_.]{1,63}$'),
  sstid                   text CHECK (sstid ~ '^[0-9]{13}$'),
  moadian_unit_code       text REFERENCES ref.moadian_unit(code),
  item_title              text CHECK (item_title = core.fa_normalize_text(item_title) AND char_length(item_title) BETWEEN 1 AND 400),  -- sstt
  price_source            text NOT NULL DEFAULT 'price_list' CHECK (price_source IN ('price_list','manual','rule','contract','barcode','migration')),
  price_list_id           uuid,
  price_entry_id          uuid,
  original_line_id        uuid,                 -- برگشت/اصلاحی ← سطر فاکتور اصلی (ریشه)
  order_line_id           uuid,
  delivery_line_id        uuid,
  warehouse_id            uuid,
  bundle_id               uuid,
  bom_id                  uuid,                 -- کیت/دستور پخت مصرف‌شده (snapshot نسخه)
  cost_center_dim_id      uuid,
  project_dim_id          uuid,
  salesperson_party_id    uuid,
  moadian_extra           jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(moadian_extra) = 'object'),
  description             text CHECK (description = core.fa_normalize_text(description)),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, invoice_id, line_no),
  FOREIGN KEY (tenant_id, invoice_id) REFERENCES sales.invoice(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, price_list_id) REFERENCES catalog.price_list(tenant_id, id),
  FOREIGN KEY (tenant_id, price_entry_id) REFERENCES catalog.price_list_item(tenant_id, id),
  FOREIGN KEY (tenant_id, original_line_id) REFERENCES sales.invoice_line(tenant_id, id),
  FOREIGN KEY (tenant_id, order_line_id) REFERENCES sales.order_line(tenant_id, id),
  FOREIGN KEY (tenant_id, delivery_line_id) REFERENCES sales.delivery_line(tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, id),
  FOREIGN KEY (tenant_id, bundle_id) REFERENCES inventory.tracking_bundle(tenant_id, id),
  FOREIGN KEY (tenant_id, bom_id) REFERENCES catalog.bom(tenant_id, id),
  FOREIGN KEY (tenant_id, cost_center_dim_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, project_dim_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, salesperson_party_id) REFERENCES parties.party(tenant_id, id),
  -- حساب سطر مؤدیان (RC_IITP): prdis = trunc(am × fee)؛ adis = prdis − dis؛ vam = trunc(adis × vra / 100)؛ tsstam = adis + vam + odam + olam
  CONSTRAINT invoice_line_gross CHECK (gross_amount = trunc(qty * unit_price, currency_minor)),
  CONSTRAINT invoice_line_discount_sum CHECK (discount_amount = line_discount_amount + invoice_discount_alloc),
  CONSTRAINT invoice_line_net CHECK (net_amount = gross_amount - discount_amount),
  CONSTRAINT invoice_line_vat CHECK (vat_amount = sales.tax_part(net_amount, vat_rate, tax_rounding, currency_minor)),
  CONSTRAINT invoice_line_other_tax CHECK (other_tax_amount = sales.tax_part(net_amount, other_tax_rate, tax_rounding, currency_minor)
                                           AND (other_tax_rate = 0 OR other_tax_code IS NOT NULL)),
  CONSTRAINT invoice_line_other_levy CHECK (other_levy_amount = sales.tax_part(net_amount, other_levy_rate, tax_rounding, currency_minor)
                                            AND (other_levy_rate = 0 OR other_levy_code IS NOT NULL)),
  CONSTRAINT invoice_line_total CHECK (line_total = net_amount + vat_amount + other_tax_amount + other_levy_amount)
);
SELECT core.enable_tenant_rls('sales.invoice_line');
CREATE INDEX IF NOT EXISTS invoice_line_original_idx ON sales.invoice_line (tenant_id, original_line_id) WHERE original_line_id IS NOT NULL;

-- ردپای تخفیف هر سطر (قطعی و قابل ممیزی؛ همان ترتیب موتور قیمت آفلاین)
CREATE TABLE IF NOT EXISTS sales.invoice_line_discount (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  line_id               uuid NOT NULL,
  seq                   smallint NOT NULL CHECK (seq BETWEEN 1 AND 50),
  source                text NOT NULL CHECK (source IN ('manual','rule','invoice','rounding','coupon')),
  pricing_rule_id       uuid,
  basis                 text NOT NULL CHECK (basis IN ('percent','amount','price_override','free_item')),
  percent               numeric(9,6) CHECK (percent > 0 AND percent <= 100),
  amount                core.amount NOT NULL CHECK (amount > 0),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, line_id, seq),
  FOREIGN KEY (tenant_id, line_id) REFERENCES sales.invoice_line(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, pricing_rule_id) REFERENCES sales.pricing_rule(tenant_id, id),
  CHECK ((source = 'rule') = (pricing_rule_id IS NOT NULL)),
  CHECK ((basis = 'percent') = (percent IS NOT NULL))
);
SELECT core.enable_tenant_rls('sales.invoice_line_discount');

-- سهم فروشندگان از فاکتور (پورسانت)
CREATE TABLE IF NOT EXISTS sales.invoice_salesperson (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  invoice_id     uuid NOT NULL,
  party_id       uuid NOT NULL,
  share_percent  numeric(9,6) NOT NULL CHECK (share_percent > 0 AND share_percent <= 100),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, invoice_id, party_id),
  FOREIGN KEY (tenant_id, invoice_id) REFERENCES sales.invoice(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id)
);
SELECT core.enable_tenant_rls('sales.invoice_salesperson');

-- =====================================================================
-- ۱۴. sales — اعتبار مشتری و پورسانت
-- =====================================================================
CREATE TABLE IF NOT EXISTS sales.credit_check (
  tenant_id                    uuid NOT NULL REFERENCES core.tenant(id),
  id                           uuid NOT NULL DEFAULT uuidv7(),
  company_id                   uuid NOT NULL,
  party_id                     uuid NOT NULL,
  doc_type                     text NOT NULL CHECK (doc_type IN ('sales.order','sales.invoice')),
  doc_id                       uuid NOT NULL,
  policy                       text NOT NULL CHECK (policy IN ('none','warn','block')),
  credit_limit                 core.amount CHECK (credit_limit >= 0),
  currency                     char(3) NOT NULL REFERENCES ref.currency(code),
  exposure_receivable          core.amount NOT NULL,
  exposure_open_orders         core.amount NOT NULL CHECK (exposure_open_orders >= 0),
  exposure_uncleared_cheques   core.amount NOT NULL CHECK (exposure_uncleared_cheques >= 0),
  doc_amount                   core.amount NOT NULL CHECK (doc_amount >= 0),
  total_exposure               core.amount NOT NULL,
  result                       text NOT NULL CHECK (result IN ('ok','warn','blocked','overridden')),
  approval_request_id          uuid,
  override_by                  uuid,
  checked_by                   uuid,
  checked_at                   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, approval_request_id) REFERENCES core.approval_request(tenant_id, id),
  FOREIGN KEY (tenant_id, override_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, checked_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT credit_check_total CHECK (total_exposure = exposure_receivable + exposure_open_orders + exposure_uncleared_cheques + doc_amount),
  CONSTRAINT credit_check_limit CHECK (policy = 'none' OR credit_limit IS NOT NULL),
  CONSTRAINT credit_check_result CHECK (
       (result = 'ok'         AND (policy = 'none' OR total_exposure <= credit_limit))
    OR (result = 'warn'       AND policy = 'warn' AND total_exposure > credit_limit)
    OR (result = 'blocked'    AND policy = 'block' AND total_exposure > credit_limit)
    OR (result = 'overridden' AND policy = 'block' AND total_exposure > credit_limit AND override_by IS NOT NULL))
);
SELECT core.enable_tenant_rls('sales.credit_check');
DROP TRIGGER IF EXISTS trg_immutable ON sales.credit_check;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON sales.credit_check FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

ALTER TABLE sales."order" DROP CONSTRAINT IF EXISTS order_credit_check_fk;
ALTER TABLE sales."order" ADD CONSTRAINT order_credit_check_fk FOREIGN KEY (tenant_id, credit_check_id) REFERENCES sales.credit_check(tenant_id, id);
ALTER TABLE sales.invoice DROP CONSTRAINT IF EXISTS invoice_credit_check_fk;
ALTER TABLE sales.invoice ADD CONSTRAINT invoice_credit_check_fk FOREIGN KEY (tenant_id, credit_check_id) REFERENCES sales.credit_check(tenant_id, id);

-- اقلام باز و تسویه در زیردفتر treasury.open_item / treasury.allocation است (بخش ۰۶). sales در همان تراکنش ثبت،
-- OpenItemService.register را صدا می‌زند؛ این بخش جدول تسویهٔ جدا ندارد (یک منبع حقیقت).

-- پورسانت (مدل داده v1؛ محاسبه v2)
CREATE TABLE IF NOT EXISTS sales.commission_plan (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  company_id   uuid NOT NULL,
  code         text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'),
  name         text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 200),
  basis        text NOT NULL CHECK (basis IN ('net_revenue','gross_profit','collected')),
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('draft','active','retired')),
  valid_from   date NOT NULL,
  valid_to     date,
  source_pack  text,
  source_pack_version text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  CHECK (valid_to IS NULL OR valid_to >= valid_from),
  CHECK ((source_pack IS NULL) = (source_pack_version IS NULL))
);
SELECT core.enable_tenant_rls('sales.commission_plan');

CREATE TABLE IF NOT EXISTS sales.commission_rule (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  plan_id       uuid NOT NULL,
  category_id   uuid,
  item_id       uuid,
  min_amount    core.amount NOT NULL DEFAULT 0 CHECK (min_amount >= 0),
  rate_percent  numeric(9,6) CHECK (rate_percent > 0 AND rate_percent <= 100),
  fixed_amount  core.amount CHECK (fixed_amount > 0),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, plan_id, category_id, item_id, min_amount),
  FOREIGN KEY (tenant_id, plan_id) REFERENCES sales.commission_plan(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, category_id) REFERENCES catalog.item_category(tenant_id, id),
  FOREIGN KEY (tenant_id, item_id) REFERENCES catalog.item(tenant_id, id),
  CHECK (num_nonnulls(rate_percent, fixed_amount) = 1),
  CHECK (num_nonnulls(category_id, item_id) <= 1)
);
SELECT core.enable_tenant_rls('sales.commission_rule');

CREATE TABLE IF NOT EXISTS sales.commission_assignment (
  tenant_id   uuid NOT NULL REFERENCES core.tenant(id),
  id          uuid NOT NULL DEFAULT uuidv7(),
  plan_id     uuid NOT NULL,
  party_id    uuid NOT NULL,
  valid_from  date NOT NULL,
  valid_to    date,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, plan_id) REFERENCES sales.commission_plan(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  CHECK (valid_to IS NULL OR valid_to >= valid_from),
  CONSTRAINT commission_assignment_no_overlap EXCLUDE USING gist (tenant_id WITH =, party_id WITH =,
    daterange(valid_from, valid_to, '[]') WITH &&)
);
SELECT core.enable_tenant_rls('sales.commission_assignment');

CREATE TABLE IF NOT EXISTS sales.commission_entry (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  party_id         uuid NOT NULL,
  plan_id          uuid NOT NULL,
  invoice_id       uuid NOT NULL,
  invoice_line_id  uuid,
  entry_date       date NOT NULL,
  basis_amount     core.amount NOT NULL,
  rate_percent     numeric(9,6),
  amount           core.amount NOT NULL CHECK (amount <> 0),
  reversal_of_id   uuid,
  settled_ref      uuid,                 -- payroll/treasury (v2؛ ارجاع نرم)
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, invoice_id) REFERENCES sales.invoice(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, invoice_line_id) REFERENCES sales.invoice_line(tenant_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, plan_id) REFERENCES sales.commission_plan(tenant_id, id),
  FOREIGN KEY (tenant_id, reversal_of_id) REFERENCES sales.commission_entry(tenant_id, id)
);
SELECT core.enable_tenant_rls('sales.commission_entry');
CREATE UNIQUE INDEX IF NOT EXISTS commission_entry_one_reversal ON sales.commission_entry (tenant_id, reversal_of_id) WHERE reversal_of_id IS NOT NULL;
DROP TRIGGER IF EXISTS trg_immutable ON sales.commission_entry;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON sales.commission_entry FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

ALTER TABLE sales.invoice DROP CONSTRAINT IF EXISTS invoice_correction_no_stock;
ALTER TABLE sales.invoice ADD CONSTRAINT invoice_correction_no_stock CHECK (doc_kind <> 'correction' OR stock_mode = 'none');

-- =====================================================================
-- ۱۵. sales — نگهبان‌ها و راستی‌آزمایی‌ها
-- =====================================================================

-- پیوند سند با GL: سند حسابداری باید مبدأش همین سند (یا دستهٔ آن) باشد (ویوی منتشرشدهٔ ledger)
CREATE OR REPLACE FUNCTION sales.assert_gl_link(p_journal_id uuid, p_module text, p_doc_id uuid) RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_journal_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM ledger.v_journal_line v
        WHERE v.journal_id = p_journal_id AND v.source_module = p_module AND v.source_doc_id = p_doc_id) THEN
    PERFORM core.raise_hk('HK_COMMERCE_GL_LINK', format('journal %s does not originate from %s document %s', p_journal_id, p_module, p_doc_id));
  END IF;
END $$;

-- پیوند سند با شمارهٔ صادرشده (core.number_issued): همین سند و همین نوع
CREATE OR REPLACE FUNCTION sales.assert_number_link(p_number_issued_id uuid, p_doc_type text, p_doc_id uuid) RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_number_issued_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM core.number_issued n
        WHERE n.id = p_number_issued_id AND n.status = 'used' AND n.doc_type = p_doc_type AND n.doc_id = p_doc_id) THEN
    PERFORM core.raise_hk('HK_COMMERCE_NUMBER_LINK', format('number %s was not issued to %s %s', p_number_issued_id, p_doc_type, p_doc_id));
  END IF;
END $$;

-- قاعدهٔ قیمت: پس از نخستین استفاده محتوا ثابت است (نسخهٔ تازه بسازید)؛ فقط بازنشستگی و کوتاه‌کردن بازه
CREATE OR REPLACE FUNCTION sales.pricing_rule_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.first_used_at IS NOT NULL THEN PERFORM core.raise_hk('HK_SALES_RULE_USED', 'a used pricing rule cannot be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.first_used_at IS NOT NULL THEN PERFORM core.raise_hk('HK_SALES_RULE_USED', 'first_used_at is set by posting'); END IF;
    RETURN NEW;
  END IF;
  IF OLD.first_used_at IS NOT NULL AND NEW.first_used_at IS DISTINCT FROM OLD.first_used_at THEN
    PERFORM core.raise_hk('HK_SALES_RULE_USED', 'first_used_at is write-once');
  END IF;
  IF OLD.status = 'retired' THEN PERFORM core.raise_hk('HK_SALES_RULE_USED', 'retired rules are immutable'); END IF;
  IF OLD.first_used_at IS NOT NULL OR OLD.status = 'active' THEN
    v_changed := inventory.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
    IF NOT (v_changed <@ ARRAY['status','valid_to','first_used_at','updated_at','row_version'])
       OR (NEW.status = 'draft')
       OR (NEW.valid_to IS DISTINCT FROM OLD.valid_to AND (NEW.valid_to IS NULL OR (OLD.valid_to IS NOT NULL AND NEW.valid_to > OLD.valid_to))) THEN
      PERFORM core.raise_hk('HK_SALES_RULE_USED', 'active/used rules only retire or shorten; create a new version instead');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_pricing_rule_guard ON sales.pricing_rule;
CREATE TRIGGER trg_pricing_rule_guard BEFORE INSERT OR UPDATE OR DELETE ON sales.pricing_rule
  FOR EACH ROW EXECUTE FUNCTION sales.pricing_rule_guard();

CREATE OR REPLACE FUNCTION sales.pricing_rule_tier_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r record; v_status text; v_used timestamptz;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  SELECT p.status, p.first_used_at INTO v_status, v_used FROM sales.pricing_rule p WHERE p.tenant_id = r.tenant_id AND p.id = r.rule_id;
  IF v_status IS NOT NULL AND (v_status <> 'draft' OR v_used IS NOT NULL) THEN
    PERFORM core.raise_hk('HK_SALES_RULE_USED', 'tiers change only on draft rules');
  END IF;
  RETURN r;
END $$;
DROP TRIGGER IF EXISTS trg_pricing_rule_tier_guard ON sales.pricing_rule_tier;
CREATE TRIGGER trg_pricing_rule_tier_guard BEFORE INSERT OR UPDATE OR DELETE ON sales.pricing_rule_tier
  FOR EACH ROW EXECUTE FUNCTION sales.pricing_rule_tier_guard();

-- نگهبان عمومی سطر: والد باید پیش‌نویس باشد. TG_ARGV[0] = جدول والد، TG_ARGV[1] = ستون FK
CREATE OR REPLACE FUNCTION sales.child_of_draft_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r jsonb; v_status text;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  EXECUTE format('SELECT status FROM %s WHERE tenant_id = $1 AND id = $2', TG_ARGV[0])
     INTO v_status USING (r->>'tenant_id')::uuid, (r->>TG_ARGV[1])::uuid;
  IF v_status IS NOT NULL AND v_status <> 'draft' THEN
    PERFORM core.raise_hk('HK_COMMERCE_DOC_IMMUTABLE', format('lines of a %s document are immutable', v_status));
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;

-- پیش‌فاکتور/سفارش
CREATE OR REPLACE FUNCTION sales.order_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_COMMERCE_DOC_IMMUTABLE', 'only drafts can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN PERFORM core.raise_hk('HK_COMMERCE_DOC_TRANSITION', 'documents start as draft'); END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'draft' AND NEW.status = 'draft' THEN RETURN NEW; END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.kind, OLD.status, NEW.status) IN (
        ('quotation','draft','open'),('quotation','open','won'),('quotation','open','lost'),('quotation','open','expired'),
        ('quotation','open','cancelled'),('order','draft','confirmed'),('order','confirmed','closed'),('order','confirmed','cancelled'))) THEN
    PERFORM core.raise_hk('HK_COMMERCE_DOC_TRANSITION', format('%s %s → %s is not allowed', OLD.kind, OLD.status, NEW.status));
  END IF;
  IF OLD.status <> 'draft' THEN
    v_changed := inventory.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
    IF NOT (v_changed <@ ARRAY['status','closed_at','cancel_reason','notes','approval_request_id','credit_check_id','custom','updated_at','row_version']) THEN
      PERFORM core.raise_hk('HK_COMMERCE_DOC_IMMUTABLE', format('cannot change %s after the document left draft', array_to_string(v_changed, ',')));
    END IF;
  END IF;
  IF NEW.kind = 'order' AND NEW.status = 'cancelled' AND (
       EXISTS (SELECT 1 FROM sales.delivery_line dl JOIN sales.order_line ol ON ol.tenant_id = dl.tenant_id AND ol.id = dl.order_line_id
                 JOIN sales.delivery d ON d.tenant_id = dl.tenant_id AND d.id = dl.delivery_id
                WHERE ol.tenant_id = NEW.tenant_id AND ol.order_id = NEW.id AND d.status = 'posted')
    OR EXISTS (SELECT 1 FROM sales.invoice_line il JOIN sales.order_line ol ON ol.tenant_id = il.tenant_id AND ol.id = il.order_line_id
                 JOIN sales.invoice i ON i.tenant_id = il.tenant_id AND i.id = il.invoice_id
                WHERE ol.tenant_id = NEW.tenant_id AND ol.order_id = NEW.id AND i.status = 'posted')) THEN
    PERFORM core.raise_hk('HK_SALES_ORDER_FULFILLED', 'an order with posted deliveries or invoices can only be closed');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_order_guard ON sales."order";
CREATE TRIGGER trg_order_guard BEFORE INSERT OR UPDATE OR DELETE ON sales."order"
  FOR EACH ROW EXECUTE FUNCTION sales.order_guard();
DROP TRIGGER IF EXISTS trg_line_guard ON sales.order_line;
CREATE TRIGGER trg_line_guard BEFORE INSERT OR UPDATE OR DELETE ON sales.order_line
  FOR EACH ROW EXECUTE FUNCTION sales.child_of_draft_guard('sales."order"', 'order_id');

-- نگهبان عمومی سرسند ثبت‌شدنی (حواله، فاکتور، رسید، فاکتور خرید): draft → posted → cancelled؛
-- پس از پیش‌نویس فقط ستون‌های لغو تغییر می‌کنند. TG_ARGV: ستون‌های مجاز اضافه (کاما-جدا)
CREATE OR REPLACE FUNCTION sales.posted_doc_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[]; v_allowed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_COMMERCE_DOC_IMMUTABLE', 'only drafts can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN PERFORM core.raise_hk('HK_COMMERCE_DOC_TRANSITION', 'documents start as draft'); END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'draft' AND NEW.status IN ('draft','posted') THEN RETURN NEW; END IF;
  IF NOT (OLD.status = 'posted' AND NEW.status IN ('posted','cancelled')) THEN
    PERFORM core.raise_hk('HK_COMMERCE_DOC_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  v_changed := inventory.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  v_allowed := ARRAY['status','cancelled_at','cancelled_by','cancel_reason','cancel_journal_id','updated_at','row_version']
               || string_to_array(coalesce(TG_ARGV[0], ''), ',');
  IF NEW.status = 'posted' THEN v_allowed := ARRAY['updated_at','row_version'] || string_to_array(coalesce(TG_ARGV[0], ''), ','); END IF;
  IF NOT (v_changed <@ v_allowed) THEN
    PERFORM core.raise_hk('HK_COMMERCE_DOC_IMMUTABLE', format('cannot change %s on a posted document', array_to_string(v_changed, ',')));
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_doc_guard ON sales.delivery;
CREATE TRIGGER trg_doc_guard BEFORE INSERT OR UPDATE OR DELETE ON sales.delivery
  FOR EACH ROW EXECUTE FUNCTION sales.posted_doc_guard('');
DROP TRIGGER IF EXISTS trg_line_guard ON sales.delivery_line;
CREATE TRIGGER trg_line_guard BEFORE INSERT OR UPDATE OR DELETE ON sales.delivery_line
  FOR EACH ROW EXECUTE FUNCTION sales.child_of_draft_guard('sales.delivery', 'delivery_id');

-- فاکتور: پیش‌شرط لغو (بدون برگشت/اصلاحی فعال). تسویهٔ باز را treasury.open_item رد می‌کند (open_item_cancel).
CREATE OR REPLACE FUNCTION sales.invoice_cancel_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'posted' AND NEW.status = 'cancelled' THEN
    IF EXISTS (SELECT 1 FROM sales.invoice x WHERE x.tenant_id = OLD.tenant_id AND x.status = 'posted'
                 AND (x.original_invoice_id = OLD.id OR x.supersedes_invoice_id = OLD.id)) THEN
      PERFORM core.raise_hk('HK_SALES_CANCEL_HAS_DEPENDENTS', 'cancel its posted returns/corrections first');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_doc_guard ON sales.invoice;
CREATE TRIGGER trg_doc_guard BEFORE INSERT OR UPDATE OR DELETE ON sales.invoice
  FOR EACH ROW EXECUTE FUNCTION sales.posted_doc_guard('');
DROP TRIGGER IF EXISTS trg_invoice_cancel_guard ON sales.invoice;
CREATE TRIGGER trg_invoice_cancel_guard BEFORE UPDATE ON sales.invoice
  FOR EACH ROW EXECUTE FUNCTION sales.invoice_cancel_guard();

-- سطر فاکتور: فقط در پیش‌نویس؛ رقم اعشار = سرسند؛ اجازهٔ تخفیف/تغییر قیمت از کالا
CREATE OR REPLACE FUNCTION sales.invoice_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE h sales.invoice; sku record;
BEGIN
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  SELECT * INTO h FROM sales.invoice i WHERE i.tenant_id = NEW.tenant_id AND i.id = NEW.invoice_id;
  IF NEW.currency_minor <> h.currency_minor THEN
    PERFORM core.raise_hk('HK_SALES_LINE_MINOR', 'line currency_minor must equal the invoice');
  END IF;
  SELECT s.allow_discount, s.allow_price_override, s.item_type INTO sku FROM catalog.v_sku s WHERE s.variant_id = NEW.variant_id;
  IF NOT sku.allow_discount AND NEW.discount_amount > 0 THEN
    PERFORM core.raise_hk('HK_SALES_DISCOUNT_NOT_ALLOWED', 'item does not allow discounts');
  END IF;
  IF NOT sku.allow_price_override AND NEW.price_source = 'manual' THEN
    PERFORM core.raise_hk('HK_SALES_PRICE_OVERRIDE_NOT_ALLOWED', 'item does not allow manual prices');
  END IF;
  IF h.doc_kind <> 'invoice' AND NEW.original_line_id IS NULL THEN
    PERFORM core.raise_hk('HK_SALES_ORIGINAL_LINE_REQUIRED', 'return/correction lines must reference the original line');
  END IF;
  IF h.doc_kind = 'invoice' AND NEW.original_line_id IS NOT NULL THEN
    PERFORM core.raise_hk('HK_SALES_ORIGINAL_LINE_REQUIRED', 'original_line_id is only for returns/corrections');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_line_guard ON sales.invoice_line;
CREATE TRIGGER trg_line_guard BEFORE INSERT OR UPDATE OR DELETE ON sales.invoice_line
  FOR EACH ROW EXECUTE FUNCTION sales.child_of_draft_guard('sales.invoice', 'invoice_id');
DROP TRIGGER IF EXISTS trg_line_rules ON sales.invoice_line;
CREATE TRIGGER trg_line_rules BEFORE INSERT OR UPDATE ON sales.invoice_line
  FOR EACH ROW EXECUTE FUNCTION sales.invoice_line_guard();

CREATE OR REPLACE FUNCTION sales.invoice_line_child_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r jsonb; v_status text;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  SELECT i.status INTO v_status FROM sales.invoice_line l JOIN sales.invoice i ON i.tenant_id = l.tenant_id AND i.id = l.invoice_id
   WHERE l.tenant_id = (r->>'tenant_id')::uuid AND l.id = (r->>'line_id')::uuid;
  IF v_status IS NOT NULL AND v_status <> 'draft' THEN
    PERFORM core.raise_hk('HK_COMMERCE_DOC_IMMUTABLE', 'discount trace of a posted invoice is immutable');
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_line_guard ON sales.invoice_line_discount;
CREATE TRIGGER trg_line_guard BEFORE INSERT OR UPDATE OR DELETE ON sales.invoice_line_discount
  FOR EACH ROW EXECUTE FUNCTION sales.invoice_line_child_guard();
DROP TRIGGER IF EXISTS trg_line_guard ON sales.invoice_salesperson;
CREATE TRIGGER trg_line_guard BEFORE INSERT OR UPDATE OR DELETE ON sales.invoice_salesperson
  FOR EACH ROW EXECUTE FUNCTION sales.child_of_draft_guard('sales.invoice', 'invoice_id');

-- سطر جاری یک سطر اصلی (پس از آخرین اصلاحی ثبت‌شده)
CREATE OR REPLACE FUNCTION sales.current_line(p_original_line_id uuid) RETURNS sales.invoice_line
LANGUAGE plpgsql STABLE AS $$
DECLARE r sales.invoice_line;
BEGIN
  SELECT l.* INTO r FROM sales.invoice_line l JOIN sales.invoice i ON i.tenant_id = l.tenant_id AND i.id = l.invoice_id
   WHERE l.original_line_id = p_original_line_id AND i.doc_kind = 'correction' AND i.status = 'posted'
     AND NOT EXISTS (SELECT 1 FROM sales.invoice d WHERE d.tenant_id = i.tenant_id AND d.supersedes_invoice_id = i.id AND d.status = 'posted')
   LIMIT 1;
  IF NOT FOUND THEN
    SELECT l.* INTO r FROM sales.invoice_line l WHERE l.id = p_original_line_id;
  END IF;
  RETURN r;
END $$;

-- سطر یک نسخهٔ مشخص (فاکتور اصلی یا یک اصلاحی) برای یک سطر اصلی
CREATE OR REPLACE FUNCTION sales.version_line(p_invoice_id uuid, p_original_line_id uuid) RETURNS sales.invoice_line
LANGUAGE sql STABLE AS $$
  SELECT l.* FROM sales.invoice_line l
   WHERE l.invoice_id = p_invoice_id AND (l.id = p_original_line_id OR l.original_line_id = p_original_line_id)
   LIMIT 1
$$;

-- راستی‌آزمایی هنگام ثبت (deferred؛ پس از درج همهٔ سطرها، تخفیف‌ها، حرکت‌ها و سند GL در همان تراکنش)
CREATE OR REPLACE FUNCTION sales.invoice_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  t record; root sales.invoice; prev sales.invoice; rl record; ol sales.invoice_line; cur sales.invoice_line;
  v_sum numeric; v_bad integer; v_batch text; v_share numeric;
BEGIN
  IF NEW.status = 'cancelled' AND TG_OP = 'UPDATE' AND OLD.status = 'posted' THEN
    -- ابطال: هر حرکت انبار سند برگشت خورده باشد و سند GL ابطال به این فاکتور اشاره کند
    IF EXISTS (SELECT 1 FROM inventory.stock_move m WHERE m.tenant_id = NEW.tenant_id AND m.source_doc_id = NEW.id
                  AND m.reversal_of_move_id IS NULL
                  AND NOT EXISTS (SELECT 1 FROM inventory.stock_move r WHERE r.tenant_id = m.tenant_id AND r.reversal_of_move_id = m.id)) THEN
      PERFORM core.raise_hk('HK_SALES_CANCEL_STOCK', 'every stock move of a cancelled invoice must be reversed');
    END IF;
    PERFORM sales.assert_gl_link(NEW.cancel_journal_id, 'sales', NEW.id);
    RETURN NULL;
  END IF;
  IF NEW.status <> 'posted' OR (TG_OP = 'UPDATE' AND OLD.status = 'posted') THEN RETURN NULL; END IF;

  -- جمع‌های سرسند = Σ سطرها
  SELECT count(*) AS n, coalesce(sum(gross_amount), 0) AS gross, coalesce(sum(line_discount_amount), 0) AS ld,
         coalesce(sum(invoice_discount_alloc), 0) AS ia, coalesce(sum(vat_amount), 0) AS vat,
         coalesce(sum(other_tax_amount), 0) AS ot, coalesce(sum(other_levy_amount), 0) AS ol,
         coalesce(sum(line_total), 0) AS tot,
         count(*) FILTER (WHERE sstid IS NULL OR moadian_unit_code IS NULL) AS missing_moadian
    INTO t FROM sales.invoice_line WHERE tenant_id = NEW.tenant_id AND invoice_id = NEW.id;
  IF t.n = 0 THEN PERFORM core.raise_hk('HK_SALES_EMPTY', 'a posted invoice needs at least one line'); END IF;
  IF t.gross <> NEW.gross_amount OR t.ld <> NEW.line_discount_total OR t.ia <> NEW.invoice_discount_amount
     OR t.vat <> NEW.vat_amount OR t.ot <> NEW.other_tax_amount OR t.ol <> NEW.other_levy_amount OR t.tot <> NEW.total_amount THEN
    PERFORM core.raise_hk('HK_SALES_TOTALS', 'header totals must equal the sum of lines (including allocated invoice discount)');
  END IF;
  -- ردپای تخفیف = تخفیف سطر
  SELECT count(*) INTO v_bad FROM sales.invoice_line l
   WHERE l.tenant_id = NEW.tenant_id AND l.invoice_id = NEW.id
     AND (l.line_discount_amount <> coalesce((SELECT sum(d.amount) FROM sales.invoice_line_discount d
                                               WHERE d.tenant_id = l.tenant_id AND d.line_id = l.id AND d.source IN ('manual','rule','coupon')), 0)
       OR l.invoice_discount_alloc <> coalesce((SELECT sum(d.amount) FROM sales.invoice_line_discount d
                                               WHERE d.tenant_id = l.tenant_id AND d.line_id = l.id AND d.source IN ('invoice','rounding')), 0));
  IF v_bad > 0 THEN PERFORM core.raise_hk('HK_SALES_DISCOUNT_TRACE', 'discount trace must explain every line discount'); END IF;
  -- سهم فروشندگان
  SELECT sum(share_percent) INTO v_share FROM sales.invoice_salesperson WHERE tenant_id = NEW.tenant_id AND invoice_id = NEW.id;
  IF v_share IS NOT NULL AND v_share <> 100 THEN PERFORM core.raise_hk('HK_SALES_SHARES', 'salesperson shares must sum to 100'); END IF;
  -- مؤدیان: شناسهٔ کالا و واحد هر سطر؛ خریدار نوع ۱
  IF NEW.moadian_required THEN
    IF t.missing_moadian > 0 THEN PERFORM core.raise_hk('HK_SALES_MOADIAN_FIELDS', 'every line needs sstid and moadian unit code'); END IF;
    IF NEW.moadian_type = 1 AND NOT (
         (NEW.buyer_person_type IN ('legal','civil_partnership','foreign_legal') AND NEW.buyer_economic_code IS NOT NULL)
      OR (NEW.buyer_person_type IN ('natural','foreign_natural')
          AND (NEW.buyer_economic_code IS NOT NULL OR (NEW.buyer_national_id IS NOT NULL AND NEW.buyer_postal_code IS NOT NULL)))) THEN
      PERFORM core.raise_hk('HK_SALES_MOADIAN_BUYER', 'type-1 invoice needs buyer economic code (or national id + postal code for natural persons)');
    END IF;
    IF NEW.moadian_type IN (2,3) AND NEW.settlement_method <> 'cash' THEN
      PERFORM core.raise_hk('HK_SALES_MOADIAN_SETTLEMENT', 'type-2/3 invoices are cash only');
    END IF;
  END IF;
  -- شماره و GL
  PERFORM sales.assert_number_link(NEW.number_issued_id, 'sales.' || NEW.doc_kind, NEW.id);
  IF NEW.gl_mode = 'per_document' THEN PERFORM sales.assert_gl_link(NEW.gl_journal_id, 'sales', NEW.id); END IF;
  IF NEW.gl_mode = 'batched' THEN
    SELECT b.status INTO v_batch FROM sales.gl_batch b WHERE b.tenant_id = NEW.tenant_id AND b.id = NEW.gl_batch_id;
    IF v_batch <> 'open' THEN PERFORM core.raise_hk('HK_SALES_BATCH_CLOSED', 'invoice can join only an open GL batch'); END IF;
  END IF;
  -- برگشت از فروش: ارجاع به سطر اصلی، همان قیمت واحد و نرخ (مؤدیان ins=4)، مقدار ≤ باقی‌ماندهٔ قابل برگشت
  IF NEW.doc_kind IN ('return','correction') THEN
    SELECT * INTO root FROM sales.invoice r WHERE r.tenant_id = NEW.tenant_id AND r.id = NEW.original_invoice_id;
    IF root.doc_kind <> 'invoice' OR root.status <> 'posted' OR root.customer_party_id <> NEW.customer_party_id
       OR root.currency <> NEW.currency OR NEW.doc_date < root.doc_date THEN
      PERFORM core.raise_hk('HK_SALES_ORIGINAL_INVOICE', 'reference must be a posted original invoice of the same customer and currency, dated earlier');
    END IF;
  END IF;
  IF NEW.doc_kind = 'return' THEN
    FOR rl IN SELECT * FROM sales.invoice_line x WHERE x.tenant_id = NEW.tenant_id AND x.invoice_id = NEW.id LOOP
      SELECT * INTO ol FROM sales.invoice_line o WHERE o.tenant_id = rl.tenant_id AND o.id = rl.original_line_id FOR NO KEY UPDATE;
      IF ol.invoice_id <> root.id OR ol.variant_id <> rl.variant_id OR ol.uom_id <> rl.uom_id THEN
        PERFORM core.raise_hk('HK_SALES_RETURN_LINE', 'return line must reference a line of the original invoice with the same SKU and unit');
      END IF;
      cur := sales.current_line(ol.id);
      IF cur.unit_price <> rl.unit_price OR cur.vat_rate <> rl.vat_rate THEN
        PERFORM core.raise_hk('HK_SALES_RETURN_PRICE', 'return keeps the current unit price and VAT rate of the sold line');
      END IF;
      SELECT coalesce(sum(x.qty), 0) INTO v_sum FROM sales.invoice_line x JOIN sales.invoice i ON i.tenant_id = x.tenant_id AND i.id = x.invoice_id
       WHERE x.tenant_id = rl.tenant_id AND x.original_line_id = ol.id AND i.doc_kind = 'return' AND i.status = 'posted';
      IF v_sum > ol.qty THEN
        PERFORM core.raise_hk('HK_SALES_RETURN_QTY', format('returned %s exceeds sold %s', v_sum, ol.qty));
      END IF;
    END LOOP;
  END IF;
  -- اصلاحی (ins=2): نسخهٔ قبلی ثبت‌شده و آخرین؛ خریدار، نوع، الگو و نرخ ثابت؛ مقدار کالای انباری ثابت
  IF NEW.doc_kind = 'correction' THEN
    SELECT * INTO prev FROM sales.invoice p WHERE p.tenant_id = NEW.tenant_id AND p.id = NEW.supersedes_invoice_id;
    IF prev.status <> 'posted' OR coalesce(prev.original_invoice_id, prev.id) <> NEW.original_invoice_id
       OR prev.customer_party_id <> NEW.customer_party_id OR prev.moadian_type IS DISTINCT FROM NEW.moadian_type
       OR prev.moadian_pattern IS DISTINCT FROM NEW.moadian_pattern THEN
      PERFORM core.raise_hk('HK_SALES_CORRECTION_SCOPE', 'correction keeps buyer, type and pattern of the latest posted version');
    END IF;
    FOR rl IN SELECT x.*, s.item_type FROM sales.invoice_line x JOIN catalog.v_sku s ON s.variant_id = x.variant_id
              WHERE x.tenant_id = NEW.tenant_id AND x.invoice_id = NEW.id LOOP
      cur := sales.version_line(prev.id, rl.original_line_id);
      SELECT * INTO ol FROM sales.invoice_line o WHERE o.tenant_id = rl.tenant_id AND o.id = rl.original_line_id;
      IF ol.invoice_id <> root.id OR cur.id IS NULL OR cur.variant_id <> rl.variant_id OR cur.vat_rate <> rl.vat_rate
         OR (rl.item_type = 'stock' AND cur.qty <> rl.qty) THEN
        PERFORM core.raise_hk('HK_SALES_CORRECTION_LINE', 'correction keeps SKU and VAT rate; quantity of stock items changes only by return');
      END IF;
    END LOOP;
  END IF;
  -- انبار: هر سطر کالای انباری با تحویل فوری دقیقاً به اندازهٔ مقدار حرکت دارد
  IF NEW.stock_mode = 'immediate' THEN
    SELECT count(*) INTO v_bad FROM sales.invoice_line l JOIN catalog.v_sku s ON s.variant_id = l.variant_id
     WHERE l.tenant_id = NEW.tenant_id AND l.invoice_id = NEW.id AND s.item_type = 'stock'
       AND l.qty_base <> coalesce((SELECT sum(abs(m.qty_base)) FROM inventory.stock_move m
                                   WHERE m.tenant_id = l.tenant_id AND m.source_doc_id = NEW.id AND m.source_line_id = l.id
                                     AND m.reversal_of_move_id IS NULL
                                     AND m.move_kind = CASE WHEN NEW.doc_kind = 'return' THEN 'sale_return' ELSE 'sale_issue' END), 0);
    IF v_bad > 0 THEN PERFORM core.raise_hk('HK_SALES_STOCK_LINK', 'stock lines must have matching stock moves'); END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_invoice_verify ON sales.invoice;
CREATE CONSTRAINT TRIGGER trg_invoice_verify AFTER INSERT OR UPDATE ON sales.invoice
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION sales.invoice_verify();

-- حواله: شماره، GL و حرکت انبار
CREATE OR REPLACE FUNCTION sales.delivery_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_bad integer;
BEGIN
  IF NEW.status = 'cancelled' AND TG_OP = 'UPDATE' AND OLD.status = 'posted' THEN
    IF EXISTS (SELECT 1 FROM inventory.stock_move m WHERE m.tenant_id = NEW.tenant_id AND m.source_doc_id = NEW.id
                  AND m.reversal_of_move_id IS NULL
                  AND NOT EXISTS (SELECT 1 FROM inventory.stock_move r WHERE r.tenant_id = m.tenant_id AND r.reversal_of_move_id = m.id)) THEN
      PERFORM core.raise_hk('HK_SALES_CANCEL_STOCK', 'every stock move of a cancelled delivery must be reversed');
    END IF;
    RETURN NULL;
  END IF;
  IF NEW.status <> 'posted' OR (TG_OP = 'UPDATE' AND OLD.status = 'posted') THEN RETURN NULL; END IF;
  PERFORM sales.assert_number_link(NEW.number_issued_id, 'sales.delivery', NEW.id);
  PERFORM sales.assert_gl_link(NEW.gl_journal_id, 'sales', NEW.id);
  SELECT count(*) INTO v_bad FROM sales.delivery_line l
   WHERE l.tenant_id = NEW.tenant_id AND l.delivery_id = NEW.id
     AND l.qty_base <> coalesce((SELECT sum(abs(m.qty_base)) FROM inventory.stock_move m
                                 WHERE m.tenant_id = l.tenant_id AND m.source_doc_id = NEW.id AND m.source_line_id = l.id
                                   AND m.reversal_of_move_id IS NULL), 0);
  IF v_bad > 0 OR NOT EXISTS (SELECT 1 FROM sales.delivery_line l WHERE l.tenant_id = NEW.tenant_id AND l.delivery_id = NEW.id) THEN
    PERFORM core.raise_hk('HK_SALES_STOCK_LINK', 'each delivery line needs stock moves of the same quantity');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_delivery_verify ON sales.delivery;
CREATE CONSTRAINT TRIGGER trg_delivery_verify AFTER INSERT OR UPDATE ON sales.delivery
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION sales.delivery_verify();

CREATE OR REPLACE FUNCTION sales.gl_batch_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'open' OR EXISTS (SELECT 1 FROM sales.invoice i WHERE i.tenant_id = OLD.tenant_id AND i.gl_batch_id = OLD.id) THEN
      PERFORM core.raise_hk('HK_SALES_BATCH_CLOSED', 'only empty open batches can be deleted');
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status <> 'open' THEN PERFORM core.raise_hk('HK_SALES_BATCH_CLOSED', 'posted/cancelled batches are immutable'); END IF;
  IF NEW.status = 'cancelled' AND EXISTS (SELECT 1 FROM sales.invoice i WHERE i.tenant_id = OLD.tenant_id AND i.gl_batch_id = OLD.id
                                            AND i.status <> 'cancelled') THEN
    PERFORM core.raise_hk('HK_SALES_BATCH_CLOSED', 'a batch with live invoices cannot be cancelled; post it');
  END IF;
  IF NEW.status = 'posted' THEN PERFORM sales.assert_gl_link(NEW.gl_journal_id, 'sales', NEW.id); END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_gl_batch_guard ON sales.gl_batch;
CREATE TRIGGER trg_gl_batch_guard BEFORE UPDATE OR DELETE ON sales.gl_batch
  FOR EACH ROW EXECUTE FUNCTION sales.gl_batch_guard();

CREATE OR REPLACE FUNCTION sales.commission_entry_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE o sales.commission_entry;
BEGIN
  IF NEW.reversal_of_id IS NOT NULL THEN
    SELECT * INTO o FROM sales.commission_entry e WHERE e.tenant_id = NEW.tenant_id AND e.id = NEW.reversal_of_id;
    IF o.reversal_of_id IS NOT NULL OR o.amount <> -NEW.amount OR o.party_id <> NEW.party_id OR o.invoice_id <> NEW.invoice_id THEN
      PERFORM core.raise_hk('HK_SALES_COMMISSION_REVERSAL', 'reversal must mirror the original commission entry');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_commission_entry_guard ON sales.commission_entry;
CREATE TRIGGER trg_commission_entry_guard BEFORE INSERT ON sales.commission_entry
  FOR EACH ROW EXECUTE FUNCTION sales.commission_entry_guard();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pricing_rule','"order"','delivery','invoice','gl_batch','commission_plan'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_touch ON sales.%s', t);
    EXECUTE format('CREATE TRIGGER trg_touch BEFORE UPDATE ON sales.%s FOR EACH ROW EXECUTE FUNCTION core.touch_row()', t);
  END LOOP;
END $$;

-- =====================================================================
-- ۱۶. sales — ویوهای منتشرشده
-- =====================================================================
-- مبلغ نسخهٔ جاری هر فاکتور اصلی (اصلی یا آخرین اصلاحی ثبت‌شده) — مبنای قلم باز treasury و پیش‌نمایش مؤدیان
CREATE OR REPLACE VIEW sales.v_invoice_current WITH (security_invoker = true) AS
SELECT i.tenant_id, i.company_id, i.id AS invoice_id, i.doc_no, i.doc_date, i.due_date, i.customer_party_id, i.currency,
       coalesce(c.id, i.id) AS current_version_id, coalesce(c.total_amount, i.total_amount) AS current_total,
       coalesce(c.vat_amount, i.vat_amount) AS current_vat
  FROM sales.invoice i
  LEFT JOIN LATERAL (
    SELECT x.id, x.total_amount, x.vat_amount FROM sales.invoice x
     WHERE x.tenant_id = i.tenant_id AND x.original_invoice_id = i.id AND x.doc_kind = 'correction' AND x.status = 'posted'
       AND NOT EXISTS (SELECT 1 FROM sales.invoice d WHERE d.tenant_id = x.tenant_id AND d.supersedes_invoice_id = x.id AND d.status = 'posted')
     LIMIT 1) c ON true
 WHERE i.doc_kind = 'invoice' AND i.status = 'posted';

-- مقدار قابل برگشت هر سطر فروش
CREATE OR REPLACE VIEW sales.v_line_returnable WITH (security_invoker = true) AS
SELECT l.tenant_id, l.invoice_id, l.id AS line_id, l.variant_id, l.qty AS sold_qty,
       coalesce((SELECT sum(x.qty) FROM sales.invoice_line x JOIN sales.invoice r ON r.tenant_id = x.tenant_id AND r.id = x.invoice_id
                  WHERE x.tenant_id = l.tenant_id AND x.original_line_id = l.id AND r.doc_kind = 'return' AND r.status = 'posted'), 0) AS returned_qty
  FROM sales.invoice_line l JOIN sales.invoice i ON i.tenant_id = l.tenant_id AND i.id = l.invoice_id
 WHERE i.doc_kind = 'invoice' AND i.status = 'posted';

-- پیشرفت سفارش: سفارش‌شده / تحویل‌شده / فاکتورشده (به واحد پایه)
CREATE OR REPLACE VIEW sales.v_order_line_progress WITH (security_invoker = true) AS
SELECT ol.tenant_id, ol.order_id, ol.id AS order_line_id, ol.variant_id, ol.qty_base AS ordered_base,
       coalesce((SELECT sum(dl.qty_base) FROM sales.delivery_line dl JOIN sales.delivery d ON d.tenant_id = dl.tenant_id AND d.id = dl.delivery_id
                  WHERE dl.tenant_id = ol.tenant_id AND dl.order_line_id = ol.id AND d.status = 'posted' AND d.direction = 'out'), 0) AS delivered_base,
       coalesce((SELECT sum(il.qty_base) FROM sales.invoice_line il JOIN sales.invoice i ON i.tenant_id = il.tenant_id AND i.id = il.invoice_id
                  WHERE il.tenant_id = ol.tenant_id AND il.order_line_id = ol.id AND i.status = 'posted' AND i.doc_kind = 'invoice'), 0) AS invoiced_base
  FROM sales.order_line ol;

-- حاشیهٔ سود سطر فاکتور (ارزش حرکت‌های انبار سطر، شامل اجزای کیت و مواد دستور پخت)
CREATE OR REPLACE VIEW sales.v_invoice_line_margin WITH (security_invoker = true) AS
SELECT l.tenant_id, l.invoice_id, l.id AS line_id, l.net_amount,
       -coalesce(sum(mv.total_value), 0) AS cost_amount,
       l.net_amount + coalesce(sum(mv.total_value), 0) AS margin_amount,
       CASE WHEN bool_or(mv.cost_status = 'unknown') THEN 'unknown' WHEN bool_or(mv.cost_status = 'estimated') THEN 'estimated'
            ELSE 'known' END AS cost_status
  FROM sales.invoice_line l
  LEFT JOIN inventory.v_move_value mv ON mv.tenant_id = l.tenant_id AND mv.source_line_id = l.id
 GROUP BY l.tenant_id, l.invoice_id, l.id, l.net_amount;

-- =====================================================================
-- ۱۷. purchase — درخواست و سفارش خرید
-- =====================================================================
CREATE TABLE IF NOT EXISTS purchase."order" (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid NOT NULL,
  branch_id            uuid NOT NULL,
  kind                 text NOT NULL CHECK (kind IN ('requisition','order')),
  status               text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','submitted','approved','confirmed','closed','cancelled')),
  doc_date             date NOT NULL,
  number_issued_id     uuid,
  doc_no               text CHECK (char_length(doc_no) BETWEEN 1 AND 100),
  supplier_party_id    uuid,
  requisition_id       uuid,
  price_list_id        uuid,
  currency             char(3) NOT NULL REFERENCES ref.currency(code),
  exchange_rate        core.rate NOT NULL DEFAULT 1 CHECK (exchange_rate > 0),
  payment_term_id      uuid,
  expected_date        date,
  warehouse_id         uuid,
  total_amount         core.amount NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  approval_request_id  uuid,
  notes                text CHECK (notes = core.fa_normalize_text(notes)),
  confirmed_at         timestamptz,
  closed_at            timestamptz,
  cancel_reason        text,
  created_by           uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, number_issued_id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, supplier_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, requisition_id) REFERENCES purchase."order"(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, price_list_id) REFERENCES catalog.price_list(tenant_id, id),
  FOREIGN KEY (tenant_id, payment_term_id) REFERENCES parties.payment_term(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, approval_request_id) REFERENCES core.approval_request(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT po_kind_status CHECK (
       (kind = 'requisition' AND status IN ('draft','submitted','approved','closed','cancelled'))
    OR (kind = 'order'       AND status IN ('draft','submitted','approved','confirmed','closed','cancelled'))),
  CONSTRAINT po_supplier CHECK (kind = 'requisition' OR status = 'draft' OR supplier_party_id IS NOT NULL),
  CONSTRAINT po_number CHECK ((status <> 'draft') = (number_issued_id IS NOT NULL AND doc_no IS NOT NULL)),
  CONSTRAINT po_requisition_link CHECK (requisition_id IS NULL OR kind = 'order'),
  CONSTRAINT po_cancel_reason CHECK ((status = 'cancelled') = (cancel_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('purchase."order"');

CREATE TABLE IF NOT EXISTS purchase.order_line (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  order_id             uuid NOT NULL,
  line_no              integer NOT NULL CHECK (line_no BETWEEN 1 AND 100000),
  item_id              uuid NOT NULL,
  variant_id           uuid NOT NULL,
  uom_id               uuid NOT NULL,
  qty                  core.qty NOT NULL CHECK (qty > 0),
  qty_base             core.qty NOT NULL CHECK (qty_base > 0),
  unit_price           core.rate CHECK (unit_price >= 0),
  discount_amount      core.amount NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  net_amount           core.amount CHECK (net_amount >= 0),
  vat_rate             numeric(7,4) NOT NULL DEFAULT 0 CHECK (vat_rate >= 0 AND vat_rate <= 100),
  requisition_line_id  uuid,
  expected_date        date,
  description          text CHECK (description = core.fa_normalize_text(description)),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, order_id, line_no),
  FOREIGN KEY (tenant_id, order_id) REFERENCES purchase."order"(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, requisition_line_id) REFERENCES purchase.order_line(tenant_id, id),
  CHECK ((unit_price IS NULL) = (net_amount IS NULL))
);
SELECT core.enable_tenant_rls('purchase.order_line');

-- =====================================================================
-- ۱۸. purchase — رسید کالا (GRN)
-- =====================================================================
CREATE TABLE IF NOT EXISTS purchase.receipt (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  company_id             uuid NOT NULL,
  branch_id              uuid NOT NULL,
  status                 text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','cancelled')),
  doc_date               date NOT NULL,
  number_issued_id       uuid,
  doc_no                 text CHECK (char_length(doc_no) BETWEEN 1 AND 100),
  supplier_party_id      uuid NOT NULL,
  order_id               uuid,
  warehouse_id           uuid NOT NULL,
  supplier_delivery_no   text CHECK (supplier_delivery_no = core.fa_normalize_ident(supplier_delivery_no)),
  currency               char(3) NOT NULL REFERENCES ref.currency(code),
  exchange_rate          core.rate NOT NULL DEFAULT 1 CHECK (exchange_rate > 0),
  gl_status              text NOT NULL DEFAULT 'pending' CHECK (gl_status IN ('pending','posted','not_required','deferred')),
  gl_journal_id          uuid,
  cancel_journal_id      uuid,
  posted_by              uuid,
  posted_at              timestamptz,
  cancelled_by           uuid,
  cancelled_at           timestamptz,
  cancel_reason          text,
  created_by             uuid,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, number_issued_id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, supplier_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, order_id) REFERENCES purchase."order"(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, cancel_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, posted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, cancelled_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT receipt_number CHECK ((status <> 'draft') = (number_issued_id IS NOT NULL AND doc_no IS NOT NULL AND posted_at IS NOT NULL)),
  CONSTRAINT receipt_cancel CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)),
  CONSTRAINT receipt_gl_link CHECK ((gl_status = 'posted') = (gl_journal_id IS NOT NULL)),
  CONSTRAINT receipt_gl_when_posted CHECK (status = 'draft' OR gl_status <> 'pending')
);
SELECT core.enable_tenant_rls('purchase.receipt');

CREATE TABLE IF NOT EXISTS purchase.receipt_line (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  receipt_id      uuid NOT NULL,
  line_no         integer NOT NULL CHECK (line_no BETWEEN 1 AND 100000),
  order_line_id   uuid,
  item_id         uuid NOT NULL,
  variant_id      uuid NOT NULL,
  uom_id          uuid NOT NULL,
  qty             core.qty NOT NULL CHECK (qty > 0),
  qty_base        core.qty NOT NULL CHECK (qty_base > 0),
  unit_price      core.rate NOT NULL CHECK (unit_price >= 0),          -- قیمت مورد انتظار (سفارش/فهرست)
  value_txn       core.amount NOT NULL CHECK (value_txn >= 0),
  value_base      core.amount NOT NULL CHECK (value_base >= 0),
  bundle_id       uuid,
  description     text CHECK (description = core.fa_normalize_text(description)),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, receipt_id, line_no),
  FOREIGN KEY (tenant_id, receipt_id) REFERENCES purchase.receipt(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, order_line_id) REFERENCES purchase.order_line(tenant_id, id),
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, bundle_id) REFERENCES inventory.tracking_bundle(tenant_id, id)
);
SELECT core.enable_tenant_rls('purchase.receipt_line');

-- =====================================================================
-- ۱۹. purchase — فاکتور خرید و برگشت از خرید، هزینهٔ جانبی
-- =====================================================================
CREATE TABLE IF NOT EXISTS purchase.invoice (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  company_id             uuid NOT NULL,
  branch_id              uuid NOT NULL,
  doc_kind               text NOT NULL DEFAULT 'invoice' CHECK (doc_kind IN ('invoice','return')),
  status                 text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','cancelled')),
  doc_date               date NOT NULL,
  number_issued_id       uuid,
  doc_no                 text CHECK (char_length(doc_no) BETWEEN 1 AND 100),
  supplier_party_id      uuid NOT NULL,
  supplier_invoice_no    text CHECK (supplier_invoice_no = core.fa_normalize_ident(supplier_invoice_no) AND char_length(supplier_invoice_no) BETWEEN 1 AND 60),
  supplier_invoice_date  date,
  supplier_taxid         text CHECK (supplier_taxid ~ '^[A-Za-z0-9]{22}$'),
  original_invoice_id    uuid,
  order_id               uuid,
  currency               char(3) NOT NULL REFERENCES ref.currency(code),
  currency_minor         smallint NOT NULL CHECK (currency_minor BETWEEN 0 AND 4),
  exchange_rate          core.rate NOT NULL DEFAULT 1 CHECK (exchange_rate > 0),
  stock_mode             text NOT NULL DEFAULT 'immediate' CHECK (stock_mode IN ('none','immediate','via_receipt')),
  warehouse_id           uuid,
  settlement_method      text NOT NULL DEFAULT 'credit' CHECK (settlement_method IN ('cash','credit','mixed')),
  payment_term_id        uuid,
  due_date               date,
  gross_amount           core.amount NOT NULL DEFAULT 0 CHECK (gross_amount >= 0),
  discount_amount        core.amount NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  net_amount             core.amount NOT NULL DEFAULT 0 CHECK (net_amount >= 0),
  vat_amount             core.amount NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
  other_tax_amount       core.amount NOT NULL DEFAULT 0 CHECK (other_tax_amount >= 0),
  charges_amount         core.amount NOT NULL DEFAULT 0 CHECK (charges_amount >= 0),
  charges_vat_amount     core.amount NOT NULL DEFAULT 0 CHECK (charges_vat_amount >= 0),
  total_amount           core.amount NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  total_base             core.amount NOT NULL DEFAULT 0 CHECK (total_base >= 0),
  amount_unit            core.amount_unit,                  -- واحد ورودی برای ورود از مهاجرت/Excel
  channel                text NOT NULL DEFAULT 'manual' CHECK (channel IN ('manual','moadian_inbox','migration','api')),
  gl_status              text NOT NULL DEFAULT 'pending' CHECK (gl_status IN ('pending','posted','not_required')),
  gl_journal_id          uuid,
  cancel_journal_id      uuid,
  approval_request_id    uuid,
  posted_by              uuid,
  posted_at              timestamptz,
  cancelled_by           uuid,
  cancelled_at           timestamptz,
  cancel_reason          text,
  notes                  text CHECK (notes = core.fa_normalize_text(notes)),
  created_by             uuid,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, number_issued_id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, supplier_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, original_invoice_id) REFERENCES purchase.invoice(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, order_id) REFERENCES purchase."order"(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, payment_term_id) REFERENCES parties.payment_term(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, cancel_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, approval_request_id) REFERENCES core.approval_request(tenant_id, id),
  FOREIGN KEY (tenant_id, posted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, cancelled_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT pinv_return_link CHECK ((doc_kind = 'return') = (original_invoice_id IS NOT NULL)),
  CONSTRAINT pinv_number CHECK ((status <> 'draft') = (number_issued_id IS NOT NULL AND doc_no IS NOT NULL AND posted_at IS NOT NULL)),
  CONSTRAINT pinv_cancel CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)),
  CONSTRAINT pinv_totals CHECK (net_amount = gross_amount - discount_amount
                                AND total_amount = net_amount + vat_amount + other_tax_amount + charges_amount + charges_vat_amount),
  CONSTRAINT pinv_stock_mode CHECK (stock_mode <> 'immediate' OR warehouse_id IS NOT NULL),
  CONSTRAINT pinv_gl_link CHECK ((gl_status = 'posted') = (gl_journal_id IS NOT NULL)),
  CONSTRAINT pinv_gl_when_posted CHECK (status = 'draft' OR gl_status <> 'pending'),
  CONSTRAINT pinv_cancel_gl CHECK (status <> 'cancelled' OR gl_journal_id IS NULL OR cancel_journal_id IS NOT NULL),
  CONSTRAINT pinv_migration_unit CHECK (channel NOT IN ('migration','moadian_inbox') OR amount_unit IS NOT NULL),
  CONSTRAINT pinv_due_date CHECK (due_date IS NULL OR due_date >= doc_date)
);
SELECT core.enable_tenant_rls('purchase.invoice');
-- تلهٔ «ورود دوبارهٔ فاکتور تأمین‌کننده»: یک فاکتور خرید فعال برای هر (شرکت، تأمین‌کننده، شمارهٔ فاکتور او) و هر taxid
CREATE UNIQUE INDEX IF NOT EXISTS pinv_supplier_no_uq ON purchase.invoice (tenant_id, company_id, supplier_party_id, supplier_invoice_no)
  WHERE doc_kind = 'invoice' AND status <> 'cancelled' AND supplier_invoice_no IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS pinv_taxid_uq ON purchase.invoice (tenant_id, supplier_taxid)
  WHERE status <> 'cancelled' AND supplier_taxid IS NOT NULL;

CREATE TABLE IF NOT EXISTS purchase.invoice_line (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  invoice_id           uuid NOT NULL,
  line_no              integer NOT NULL CHECK (line_no BETWEEN 1 AND 100000),
  item_id              uuid NOT NULL,
  variant_id           uuid NOT NULL,
  uom_id               uuid NOT NULL,
  qty                  core.qty NOT NULL CHECK (qty > 0),
  qty_base             core.qty NOT NULL CHECK (qty_base > 0),
  unit_price           core.rate NOT NULL CHECK (unit_price >= 0),
  gross_amount         core.amount NOT NULL CHECK (gross_amount >= 0),
  discount_amount      core.amount NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  net_amount           core.amount NOT NULL CHECK (net_amount >= 0),
  vat_rate             numeric(7,4) NOT NULL DEFAULT 0 CHECK (vat_rate >= 0 AND vat_rate <= 100),
  vat_amount           core.amount NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
  other_tax_amount     core.amount NOT NULL DEFAULT 0 CHECK (other_tax_amount >= 0),
  line_total           core.amount NOT NULL CHECK (line_total >= 0),
  sstid                text CHECK (sstid ~ '^[0-9]{13}$'),
  receipt_line_id      uuid,
  order_line_id        uuid,
  original_line_id     uuid,
  warehouse_id         uuid,
  bundle_id            uuid,
  expense_posting_key  text REFERENCES ledger.posting_key(key),     -- برای کالای غیرانباری/خدمت
  cost_center_dim_id   uuid,
  project_dim_id       uuid,
  description          text CHECK (description = core.fa_normalize_text(description)),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, invoice_id, line_no),
  FOREIGN KEY (tenant_id, invoice_id) REFERENCES purchase.invoice(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, item_id, variant_id) REFERENCES catalog.item_variant(tenant_id, item_id, id),
  FOREIGN KEY (tenant_id, item_id, uom_id) REFERENCES catalog.item_uom(tenant_id, item_id, uom_id),
  FOREIGN KEY (tenant_id, receipt_line_id) REFERENCES purchase.receipt_line(tenant_id, id),
  FOREIGN KEY (tenant_id, order_line_id) REFERENCES purchase.order_line(tenant_id, id),
  FOREIGN KEY (tenant_id, original_line_id) REFERENCES purchase.invoice_line(tenant_id, id),
  FOREIGN KEY (tenant_id, warehouse_id) REFERENCES inventory.warehouse(tenant_id, id),
  FOREIGN KEY (tenant_id, bundle_id) REFERENCES inventory.tracking_bundle(tenant_id, id),
  FOREIGN KEY (tenant_id, cost_center_dim_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, project_dim_id) REFERENCES ledger.dimension_value(tenant_id, id),
  CONSTRAINT pinv_line_net CHECK (net_amount = gross_amount - discount_amount),
  CONSTRAINT pinv_line_total CHECK (line_total = net_amount + vat_amount + other_tax_amount)
);
SELECT core.enable_tenant_rls('purchase.invoice_line');
CREATE INDEX IF NOT EXISTS pinv_line_receipt_idx ON purchase.invoice_line (tenant_id, receipt_line_id) WHERE receipt_line_id IS NOT NULL;

-- هزینهٔ جانبی روی فاکتور خرید (کرایه، بیمه، گمرک)؛ سرمایه‌ای ← تسهیم روی سطرهای کالا
CREATE TABLE IF NOT EXISTS purchase.invoice_charge (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  invoice_id           uuid NOT NULL,
  line_no              integer NOT NULL CHECK (line_no BETWEEN 1 AND 1000),
  charge_kind          text NOT NULL CHECK (charge_kind IN ('freight','insurance','customs','handling','other')),
  description          text CHECK (description = core.fa_normalize_text(description)),
  amount               core.amount NOT NULL CHECK (amount > 0),
  vat_amount           core.amount NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
  capitalize           boolean NOT NULL DEFAULT true,
  allocation_basis     text NOT NULL DEFAULT 'value' CHECK (allocation_basis IN ('value','qty','weight','volume','manual')),
  expense_posting_key  text REFERENCES ledger.posting_key(key),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, invoice_id, line_no),
  FOREIGN KEY (tenant_id, invoice_id) REFERENCES purchase.invoice(tenant_id, id) ON DELETE CASCADE,
  CHECK (capitalize OR expense_posting_key IS NOT NULL)
);
SELECT core.enable_tenant_rls('purchase.invoice_charge');

-- سند هزینهٔ جانبی مستقل (v2؛ مدل داده آماده): هزینهٔ فاکتور دیگری روی رسیدهای پیشین
CREATE TABLE IF NOT EXISTS purchase.landed_cost_voucher (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid NOT NULL,
  status               text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','cancelled')),
  doc_date             date NOT NULL,
  number_issued_id     uuid,
  doc_no               text,
  source_invoice_id    uuid,
  allocation_basis     text NOT NULL DEFAULT 'value' CHECK (allocation_basis IN ('value','qty','weight','volume','manual')),
  gl_status            text NOT NULL DEFAULT 'pending' CHECK (gl_status IN ('pending','posted','not_required')),
  gl_journal_id        uuid,
  cancel_journal_id    uuid,
  posted_at            timestamptz,
  cancelled_at         timestamptz,
  cancel_reason        text,
  created_by           uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, number_issued_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, source_invoice_id) REFERENCES purchase.invoice(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, cancel_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((status <> 'draft') = (number_issued_id IS NOT NULL AND doc_no IS NOT NULL AND posted_at IS NOT NULL)),
  CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)),
  CHECK ((gl_status = 'posted') = (gl_journal_id IS NOT NULL)),
  CHECK (status = 'draft' OR gl_status <> 'pending')
);
SELECT core.enable_tenant_rls('purchase.landed_cost_voucher');

CREATE TABLE IF NOT EXISTS purchase.landed_cost_line (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  voucher_id    uuid NOT NULL,
  line_no       integer NOT NULL CHECK (line_no BETWEEN 1 AND 1000),
  charge_kind   text NOT NULL CHECK (charge_kind IN ('freight','insurance','customs','handling','other')),
  amount        core.amount NOT NULL CHECK (amount > 0),
  description   text CHECK (description = core.fa_normalize_text(description)),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, voucher_id, line_no),
  FOREIGN KEY (tenant_id, voucher_id) REFERENCES purchase.landed_cost_voucher(tenant_id, id) ON DELETE CASCADE
);
SELECT core.enable_tenant_rls('purchase.landed_cost_line');

-- تسهیم هزینهٔ جانبی (هزینهٔ فاکتور یا سطر سند هزینهٔ جانبی) روی سطر فاکتور یا سطر رسید
CREATE TABLE IF NOT EXISTS purchase.cost_allocation (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL DEFAULT uuidv7(),
  charge_id               uuid,
  landed_cost_line_id     uuid,
  target_invoice_line_id  uuid,
  target_receipt_line_id  uuid,
  basis_value             core.amount NOT NULL CHECK (basis_value >= 0),
  amount                  core.amount NOT NULL CHECK (amount >= 0),
  amount_base             core.amount NOT NULL CHECK (amount_base >= 0),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, charge_id) REFERENCES purchase.invoice_charge(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, landed_cost_line_id) REFERENCES purchase.landed_cost_line(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, target_invoice_line_id) REFERENCES purchase.invoice_line(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, target_receipt_line_id) REFERENCES purchase.receipt_line(tenant_id, id),
  CHECK (num_nonnulls(charge_id, landed_cost_line_id) = 1),
  CHECK (num_nonnulls(target_invoice_line_id, target_receipt_line_id) = 1)
);
SELECT core.enable_tenant_rls('purchase.cost_allocation');
CREATE UNIQUE INDEX IF NOT EXISTS cost_allocation_uq ON purchase.cost_allocation
  (tenant_id, coalesce(charge_id, landed_cost_line_id), coalesce(target_invoice_line_id, target_receipt_line_id));

-- اقلام باز و تسویهٔ فاکتور خرید در treasury.open_item / treasury.allocation (بخش ۰۶)؛ purchase در همان تراکنش ثبت
-- OpenItemService.register را صدا می‌زند.

-- =====================================================================
-- ۲۰. purchase — صورتحساب‌های خرید از Excel کارپوشهٔ مؤدیان و تطبیق
-- =====================================================================
CREATE TABLE IF NOT EXISTS purchase.moadian_inbox_batch (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  attachment_id    uuid NOT NULL,
  file_sha256      bytea NOT NULL CHECK (octet_length(file_sha256) = 32),
  format_version   text NOT NULL CHECK (format_version ~ '^[a-z0-9][a-z0-9._-]{1,40}$'),
  amount_unit      core.amount_unit NOT NULL,
  period_from      date,
  period_to        date,
  row_count        integer NOT NULL DEFAULT 0 CHECK (row_count >= 0),
  parsed_count     integer NOT NULL DEFAULT 0 CHECK (parsed_count >= 0),
  error_count      integer NOT NULL DEFAULT 0 CHECK (error_count >= 0),
  status           text NOT NULL DEFAULT 'uploaded' CHECK (status IN ('uploaded','parsed','failed')),
  errors           jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(errors) = 'array'),
  uploaded_by      uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, file_sha256),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, attachment_id) REFERENCES core.attachment(tenant_id, id),
  FOREIGN KEY (tenant_id, uploaded_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (parsed_count + error_count <= row_count),
  CHECK (period_to IS NULL OR period_from IS NULL OR period_to >= period_from)
);
SELECT core.enable_tenant_rls('purchase.moadian_inbox_batch');

CREATE TABLE IF NOT EXISTS purchase.moadian_inbox_invoice (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  company_id          uuid NOT NULL,
  first_batch_id      uuid NOT NULL,
  last_batch_id       uuid NOT NULL,
  taxid               text NOT NULL CHECK (taxid ~ '^[A-Za-z0-9]{22}$'),
  reference_taxid     text CHECK (reference_taxid ~ '^[A-Za-z0-9]{22}$'),    -- irtaxid برای اصلاحی/ابطالی/برگشتی
  issue_date          date NOT NULL,
  seller_tin          text NOT NULL CHECK (seller_tin ~ '^[0-9]{10,14}$'),
  seller_name         text CHECK (seller_name = core.fa_normalize_text(seller_name)),
  invoice_type        smallint CHECK (invoice_type IN (1,2,3)),
  invoice_pattern     smallint,
  invoice_subject     smallint CHECK (invoice_subject IN (1,2,3,4)),
  total_amount        core.amount NOT NULL CHECK (total_amount >= 0),   -- ریال (پس از تبدیل صریح amount_unit دسته)
  vat_amount          core.amount NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
  portal_status       text NOT NULL CHECK (portal_status ~ '^[a-z][a-z0-9_]{1,30}$'),
  buyer_reaction      text NOT NULL DEFAULT 'none' CHECK (buyer_reaction IN ('none','accepted','rejected','auto_accepted')),
  raw_row             jsonb NOT NULL CHECK (jsonb_typeof(raw_row) = 'object'),
  supplier_party_id   uuid,
  match_status        text NOT NULL DEFAULT 'unmatched' CHECK (match_status IN ('unmatched','candidate','matched','ignored')),
  matched_invoice_id  uuid,
  match_score         numeric(5,4) CHECK (match_score BETWEEN 0 AND 1),
  matched_by          uuid,
  matched_at          timestamptz,
  ignore_reason       text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, taxid),
  FOREIGN KEY (tenant_id, company_id, first_batch_id) REFERENCES purchase.moadian_inbox_batch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, last_batch_id) REFERENCES purchase.moadian_inbox_batch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, supplier_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, matched_invoice_id) REFERENCES purchase.invoice(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, matched_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT inbox_match_shape CHECK (
       (match_status = 'matched' AND matched_invoice_id IS NOT NULL AND matched_at IS NOT NULL)
    OR (match_status = 'candidate' AND matched_invoice_id IS NOT NULL AND matched_at IS NULL)
    OR (match_status = 'ignored' AND matched_invoice_id IS NULL AND ignore_reason IS NOT NULL)
    OR (match_status = 'unmatched' AND matched_invoice_id IS NULL)),
  CONSTRAINT inbox_reference CHECK (invoice_subject IS NULL OR (invoice_subject = 1) = (reference_taxid IS NULL))
);
SELECT core.enable_tenant_rls('purchase.moadian_inbox_invoice');
CREATE UNIQUE INDEX IF NOT EXISTS inbox_one_match ON purchase.moadian_inbox_invoice (tenant_id, matched_invoice_id) WHERE match_status = 'matched';
CREATE INDEX IF NOT EXISTS inbox_seller_idx ON purchase.moadian_inbox_invoice (tenant_id, company_id, seller_tin, issue_date);

-- =====================================================================
-- ۲۱. purchase — نگهبان‌ها و راستی‌آزمایی
-- =====================================================================
CREATE OR REPLACE FUNCTION purchase.order_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_COMMERCE_DOC_IMMUTABLE', 'only drafts can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN PERFORM core.raise_hk('HK_COMMERCE_DOC_TRANSITION', 'documents start as draft'); END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'draft' AND NEW.status = 'draft' THEN RETURN NEW; END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN (
       ('draft','submitted'),('submitted','approved'),('submitted','cancelled'),('approved','confirmed'),('approved','closed'),
       ('approved','cancelled'),('confirmed','closed'),('confirmed','cancelled'),('draft','confirmed'))
       AND NOT (OLD.kind = 'requisition' AND NEW.status = 'confirmed')) THEN
    PERFORM core.raise_hk('HK_COMMERCE_DOC_TRANSITION', format('%s %s → %s is not allowed', OLD.kind, OLD.status, NEW.status));
  END IF;
  IF OLD.status <> 'draft' THEN
    v_changed := inventory.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
    IF NOT (v_changed <@ ARRAY['status','confirmed_at','closed_at','cancel_reason','notes','approval_request_id','updated_at','row_version']) THEN
      PERFORM core.raise_hk('HK_COMMERCE_DOC_IMMUTABLE', format('cannot change %s after the document left draft', array_to_string(v_changed, ',')));
    END IF;
  END IF;
  IF NEW.status = 'cancelled' AND EXISTS (
       SELECT 1 FROM purchase.receipt_line rl JOIN purchase.order_line ol ON ol.tenant_id = rl.tenant_id AND ol.id = rl.order_line_id
         JOIN purchase.receipt r ON r.tenant_id = rl.tenant_id AND r.id = rl.receipt_id
        WHERE ol.tenant_id = NEW.tenant_id AND ol.order_id = NEW.id AND r.status = 'posted') THEN
    PERFORM core.raise_hk('HK_PUR_ORDER_RECEIVED', 'an order with posted receipts can only be closed');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_order_guard ON purchase."order";
CREATE TRIGGER trg_order_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase."order"
  FOR EACH ROW EXECUTE FUNCTION purchase.order_guard();
DROP TRIGGER IF EXISTS trg_line_guard ON purchase.order_line;
CREATE TRIGGER trg_line_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase.order_line
  FOR EACH ROW EXECUTE FUNCTION sales.child_of_draft_guard('purchase."order"', 'order_id');

DROP TRIGGER IF EXISTS trg_doc_guard ON purchase.receipt;
CREATE TRIGGER trg_doc_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase.receipt
  FOR EACH ROW EXECUTE FUNCTION sales.posted_doc_guard('');
DROP TRIGGER IF EXISTS trg_line_guard ON purchase.receipt_line;
CREATE TRIGGER trg_line_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase.receipt_line
  FOR EACH ROW EXECUTE FUNCTION sales.child_of_draft_guard('purchase.receipt', 'receipt_id');
DROP TRIGGER IF EXISTS trg_doc_guard ON purchase.invoice;
CREATE TRIGGER trg_doc_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase.invoice
  FOR EACH ROW EXECUTE FUNCTION sales.posted_doc_guard('');
DROP TRIGGER IF EXISTS trg_line_guard ON purchase.invoice_line;
CREATE TRIGGER trg_line_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase.invoice_line
  FOR EACH ROW EXECUTE FUNCTION sales.child_of_draft_guard('purchase.invoice', 'invoice_id');
DROP TRIGGER IF EXISTS trg_line_guard ON purchase.invoice_charge;
CREATE TRIGGER trg_line_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase.invoice_charge
  FOR EACH ROW EXECUTE FUNCTION sales.child_of_draft_guard('purchase.invoice', 'invoice_id');
DROP TRIGGER IF EXISTS trg_doc_guard ON purchase.landed_cost_voucher;
CREATE TRIGGER trg_doc_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase.landed_cost_voucher
  FOR EACH ROW EXECUTE FUNCTION sales.posted_doc_guard('');
DROP TRIGGER IF EXISTS trg_line_guard ON purchase.landed_cost_line;
CREATE TRIGGER trg_line_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase.landed_cost_line
  FOR EACH ROW EXECUTE FUNCTION sales.child_of_draft_guard('purchase.landed_cost_voucher', 'voucher_id');

-- تسهیم: فقط وقتی سند مادرِ هزینه پیش‌نویس است
CREATE OR REPLACE FUNCTION purchase.cost_allocation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r purchase.cost_allocation; v_status text;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  IF r.charge_id IS NOT NULL THEN
    SELECT i.status INTO v_status FROM purchase.invoice_charge c JOIN purchase.invoice i ON i.tenant_id = c.tenant_id AND i.id = c.invoice_id
     WHERE c.tenant_id = r.tenant_id AND c.id = r.charge_id;
  ELSE
    SELECT v.status INTO v_status FROM purchase.landed_cost_line l JOIN purchase.landed_cost_voucher v ON v.tenant_id = l.tenant_id AND v.id = l.voucher_id
     WHERE l.tenant_id = r.tenant_id AND l.id = r.landed_cost_line_id;
  END IF;
  IF v_status IS NOT NULL AND v_status <> 'draft' THEN
    PERFORM core.raise_hk('HK_COMMERCE_DOC_IMMUTABLE', 'allocations of a posted document are immutable');
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_cost_allocation_guard ON purchase.cost_allocation;
CREATE TRIGGER trg_cost_allocation_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase.cost_allocation
  FOR EACH ROW EXECUTE FUNCTION purchase.cost_allocation_guard();

-- فاکتور خرید هنگام ثبت: جمع‌ها، تسهیم کامل هزینه‌های سرمایه‌ای، برگشت ≤ خرید، شماره، GL، حرکت انبار
CREATE OR REPLACE FUNCTION purchase.invoice_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE t record; v_bad integer; orig purchase.invoice; rl record; v_sum numeric;
BEGIN
  IF NEW.status = 'cancelled' AND TG_OP = 'UPDATE' AND OLD.status = 'posted' THEN
    IF EXISTS (SELECT 1 FROM inventory.stock_move m WHERE m.tenant_id = NEW.tenant_id AND m.source_doc_id = NEW.id
                  AND m.reversal_of_move_id IS NULL
                  AND NOT EXISTS (SELECT 1 FROM inventory.stock_move r WHERE r.tenant_id = m.tenant_id AND r.reversal_of_move_id = m.id)) THEN
      PERFORM core.raise_hk('HK_PUR_CANCEL_STOCK', 'every stock move of a cancelled invoice must be reversed');
    END IF;
    IF EXISTS (SELECT 1 FROM purchase.invoice x WHERE x.tenant_id = NEW.tenant_id AND x.original_invoice_id = NEW.id AND x.status = 'posted') THEN
      PERFORM core.raise_hk('HK_PUR_CANCEL_HAS_DEPENDENTS', 'cancel its posted returns first');
    END IF;
    RETURN NULL;
  END IF;
  IF NEW.status <> 'posted' OR (TG_OP = 'UPDATE' AND OLD.status = 'posted') THEN RETURN NULL; END IF;
  SELECT count(*) AS n, coalesce(sum(gross_amount), 0) AS gross, coalesce(sum(discount_amount), 0) AS disc,
         coalesce(sum(vat_amount), 0) AS vat, coalesce(sum(other_tax_amount), 0) AS ot
    INTO t FROM purchase.invoice_line WHERE tenant_id = NEW.tenant_id AND invoice_id = NEW.id;
  IF t.n = 0 THEN PERFORM core.raise_hk('HK_PUR_EMPTY', 'a posted purchase invoice needs at least one line'); END IF;
  IF t.gross <> NEW.gross_amount OR t.disc <> NEW.discount_amount OR t.vat <> NEW.vat_amount OR t.ot <> NEW.other_tax_amount
     OR NEW.charges_amount <> coalesce((SELECT sum(c.amount) FROM purchase.invoice_charge c WHERE c.tenant_id = NEW.tenant_id AND c.invoice_id = NEW.id), 0)
     OR NEW.charges_vat_amount <> coalesce((SELECT sum(c.vat_amount) FROM purchase.invoice_charge c WHERE c.tenant_id = NEW.tenant_id AND c.invoice_id = NEW.id), 0) THEN
    PERFORM core.raise_hk('HK_PUR_TOTALS', 'header totals must equal the sum of lines and charges');
  END IF;
  -- هزینهٔ سرمایه‌ای کامل تسهیم شود و فقط روی سطرهای همین فاکتور یا رسیدهای آن
  SELECT count(*) INTO v_bad FROM purchase.invoice_charge c
   WHERE c.tenant_id = NEW.tenant_id AND c.invoice_id = NEW.id
     AND ((c.capitalize AND c.amount <> coalesce((SELECT sum(a.amount) FROM purchase.cost_allocation a
                                                   WHERE a.tenant_id = c.tenant_id AND a.charge_id = c.id), 0))
       OR (NOT c.capitalize AND EXISTS (SELECT 1 FROM purchase.cost_allocation a WHERE a.tenant_id = c.tenant_id AND a.charge_id = c.id)));
  IF v_bad > 0 THEN PERFORM core.raise_hk('HK_PUR_CHARGE_ALLOCATION', 'capitalized charges must be fully allocated; expensed charges not at all'); END IF;
  IF EXISTS (SELECT 1 FROM purchase.cost_allocation a JOIN purchase.invoice_charge c ON c.tenant_id = a.tenant_id AND c.id = a.charge_id
              LEFT JOIN purchase.invoice_line il ON il.tenant_id = a.tenant_id AND il.id = a.target_invoice_line_id
              LEFT JOIN purchase.invoice_line rcl ON rcl.tenant_id = a.tenant_id AND rcl.receipt_line_id = a.target_receipt_line_id AND rcl.invoice_id = NEW.id
             WHERE c.tenant_id = NEW.tenant_id AND c.invoice_id = NEW.id
               AND coalesce(il.invoice_id, rcl.invoice_id) IS DISTINCT FROM NEW.id) THEN
    PERFORM core.raise_hk('HK_PUR_CHARGE_ALLOCATION', 'charges can be allocated only to this invoice''s lines or their receipts');
  END IF;
  PERFORM sales.assert_number_link(NEW.number_issued_id, 'purchase.' || NEW.doc_kind, NEW.id);
  PERFORM sales.assert_gl_link(NEW.gl_journal_id, 'purchase', NEW.id);
  IF NEW.doc_kind = 'return' THEN
    SELECT * INTO orig FROM purchase.invoice o WHERE o.tenant_id = NEW.tenant_id AND o.id = NEW.original_invoice_id;
    IF orig.doc_kind <> 'invoice' OR orig.status <> 'posted' OR orig.supplier_party_id <> NEW.supplier_party_id
       OR orig.currency <> NEW.currency OR NEW.doc_date < orig.doc_date THEN
      PERFORM core.raise_hk('HK_PUR_ORIGINAL_INVOICE', 'return must reference a posted purchase invoice of the same supplier and currency');
    END IF;
    FOR rl IN SELECT * FROM purchase.invoice_line x WHERE x.tenant_id = NEW.tenant_id AND x.invoice_id = NEW.id LOOP
      IF rl.original_line_id IS NULL OR NOT EXISTS (SELECT 1 FROM purchase.invoice_line o
                                                   WHERE o.tenant_id = rl.tenant_id AND o.id = rl.original_line_id AND o.invoice_id = orig.id
                                                     AND o.variant_id = rl.variant_id) THEN
        PERFORM core.raise_hk('HK_PUR_RETURN_LINE', 'return lines must reference the original invoice line of the same SKU');
      END IF;
      PERFORM 1 FROM purchase.invoice_line o WHERE o.tenant_id = rl.tenant_id AND o.id = rl.original_line_id FOR NO KEY UPDATE;
      SELECT coalesce(sum(x.qty_base), 0) INTO v_sum FROM purchase.invoice_line x JOIN purchase.invoice i ON i.tenant_id = x.tenant_id AND i.id = x.invoice_id
       WHERE x.tenant_id = rl.tenant_id AND x.original_line_id = rl.original_line_id AND i.doc_kind = 'return' AND i.status = 'posted';
      IF v_sum > (SELECT o.qty_base FROM purchase.invoice_line o WHERE o.tenant_id = rl.tenant_id AND o.id = rl.original_line_id) THEN
        PERFORM core.raise_hk('HK_PUR_RETURN_QTY', 'returned quantity exceeds purchased quantity');
      END IF;
    END LOOP;
  END IF;
  IF NEW.stock_mode = 'immediate' THEN
    SELECT count(*) INTO v_bad FROM purchase.invoice_line l JOIN catalog.v_sku s ON s.variant_id = l.variant_id
     WHERE l.tenant_id = NEW.tenant_id AND l.invoice_id = NEW.id AND s.item_type = 'stock'
       AND l.qty_base <> coalesce((SELECT sum(abs(m.qty_base)) FROM inventory.stock_move m
                                   WHERE m.tenant_id = l.tenant_id AND m.source_doc_id = NEW.id AND m.source_line_id = l.id
                                     AND m.reversal_of_move_id IS NULL
                                     AND m.move_kind = CASE WHEN NEW.doc_kind = 'return' THEN 'purchase_return' ELSE 'receipt' END), 0);
    IF v_bad > 0 THEN PERFORM core.raise_hk('HK_PUR_STOCK_LINK', 'stock lines must have matching stock moves'); END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_invoice_verify ON purchase.invoice;
CREATE CONSTRAINT TRIGGER trg_invoice_verify AFTER INSERT OR UPDATE ON purchase.invoice
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION purchase.invoice_verify();

CREATE OR REPLACE FUNCTION purchase.receipt_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_bad integer;
BEGIN
  IF NEW.status = 'cancelled' AND TG_OP = 'UPDATE' AND OLD.status = 'posted' THEN
    IF EXISTS (SELECT 1 FROM inventory.stock_move m WHERE m.tenant_id = NEW.tenant_id AND m.source_doc_id = NEW.id
                  AND m.reversal_of_move_id IS NULL
                  AND NOT EXISTS (SELECT 1 FROM inventory.stock_move r WHERE r.tenant_id = m.tenant_id AND r.reversal_of_move_id = m.id))
       OR EXISTS (SELECT 1 FROM purchase.invoice_line il JOIN purchase.receipt_line rl ON rl.tenant_id = il.tenant_id AND rl.id = il.receipt_line_id
                    JOIN purchase.invoice i ON i.tenant_id = il.tenant_id AND i.id = il.invoice_id
                   WHERE rl.tenant_id = NEW.tenant_id AND rl.receipt_id = NEW.id AND i.status = 'posted') THEN
      PERFORM core.raise_hk('HK_PUR_CANCEL_STOCK', 'reverse every stock move and cancel invoices of this receipt first');
    END IF;
    RETURN NULL;
  END IF;
  IF NEW.status <> 'posted' OR (TG_OP = 'UPDATE' AND OLD.status = 'posted') THEN RETURN NULL; END IF;
  PERFORM sales.assert_number_link(NEW.number_issued_id, 'purchase.receipt', NEW.id);
  PERFORM sales.assert_gl_link(NEW.gl_journal_id, 'purchase', NEW.id);
  SELECT count(*) INTO v_bad FROM purchase.receipt_line l
   WHERE l.tenant_id = NEW.tenant_id AND l.receipt_id = NEW.id
     AND l.qty_base <> coalesce((SELECT sum(m.qty_base) FROM inventory.stock_move m
                                 WHERE m.tenant_id = l.tenant_id AND m.source_doc_id = NEW.id AND m.source_line_id = l.id
                                   AND m.move_kind = 'receipt' AND m.reversal_of_move_id IS NULL), 0);
  IF v_bad > 0 OR NOT EXISTS (SELECT 1 FROM purchase.receipt_line l WHERE l.tenant_id = NEW.tenant_id AND l.receipt_id = NEW.id) THEN
    PERFORM core.raise_hk('HK_PUR_STOCK_LINK', 'each receipt line needs a receipt stock move of the same quantity');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_receipt_verify ON purchase.receipt;
CREATE CONSTRAINT TRIGGER trg_receipt_verify AFTER INSERT OR UPDATE ON purchase.receipt
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION purchase.receipt_verify();

-- تطبیق صورتحساب کارپوشه با فاکتور خرید: همان تأمین‌کننده و taxid سازگار
CREATE OR REPLACE FUNCTION purchase.inbox_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE inv purchase.invoice;
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.taxid <> OLD.taxid OR NEW.company_id <> OLD.company_id OR NEW.first_batch_id <> OLD.first_batch_id) THEN
    PERFORM core.raise_hk('HK_PUR_INBOX_IMMUTABLE', 'taxid, company and first batch are immutable');
  END IF;
  IF NEW.matched_invoice_id IS NOT NULL THEN
    SELECT * INTO inv FROM purchase.invoice i WHERE i.tenant_id = NEW.tenant_id AND i.id = NEW.matched_invoice_id;
    IF inv.status <> 'posted' OR (NEW.supplier_party_id IS NOT NULL AND inv.supplier_party_id <> NEW.supplier_party_id)
       OR (inv.supplier_taxid IS NOT NULL AND inv.supplier_taxid <> NEW.taxid) THEN
      PERFORM core.raise_hk('HK_PUR_INBOX_MATCH', 'match only a posted purchase invoice of the same supplier and taxid');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_inbox_guard ON purchase.moadian_inbox_invoice;
CREATE TRIGGER trg_inbox_guard BEFORE INSERT OR UPDATE ON purchase.moadian_inbox_invoice
  FOR EACH ROW EXECUTE FUNCTION purchase.inbox_guard();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['"order"','receipt','invoice','landed_cost_voucher','moadian_inbox_batch','moadian_inbox_invoice'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_touch ON purchase.%s', t);
    EXECUTE format('CREATE TRIGGER trg_touch BEFORE UPDATE ON purchase.%s FOR EACH ROW EXECUTE FUNCTION core.touch_row()', t);
  END LOOP;
END $$;

-- ویو: کالای دریافتی صورتحساب‌نشده (GRNI)
CREATE OR REPLACE VIEW purchase.v_receipt_line_unbilled WITH (security_invoker = true) AS
SELECT rl.tenant_id, r.company_id, r.id AS receipt_id, rl.id AS receipt_line_id, r.supplier_party_id, rl.variant_id,
       rl.qty_base AS received_base,
       coalesce((SELECT sum(il.qty_base) FROM purchase.invoice_line il JOIN purchase.invoice i ON i.tenant_id = il.tenant_id AND i.id = il.invoice_id
                  WHERE il.tenant_id = rl.tenant_id AND il.receipt_line_id = rl.id AND i.status = 'posted' AND i.doc_kind = 'invoice'), 0) AS invoiced_base,
       rl.value_base
  FROM purchase.receipt_line rl JOIN purchase.receipt r ON r.tenant_id = rl.tenant_id AND r.id = rl.receipt_id
 WHERE r.status = 'posted';

-- =====================================================================
-- ۲۲. inventory — بازسازی مشتق‌ها پس از درون‌ریزی .hkx (قلاب صدور/ورود) و تعمیر
-- =====================================================================
CREATE OR REPLACE FUNCTION inventory.rebuild_derived(p_company_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_t uuid := inventory.require_tenant(); v_run uuid; p record; v_first record; n integer := 0; v_added integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM core.company c WHERE c.tenant_id = v_t AND c.id = p_company_id) THEN
    PERFORM core.raise_hk('HK_INV_COMPANY_NOT_FOUND', 'company not found in the current tenant');
  END IF;
  DELETE FROM inventory.stock_balance b WHERE b.tenant_id = v_t AND b.company_id = p_company_id;
  INSERT INTO inventory.stock_balance (tenant_id, company_id, warehouse_id, item_id, variant_id, batch_id, qty, last_move_date)
  SELECT v_t, m.company_id, m.warehouse_id, m.item_id, m.variant_id, m.batch_id, sum(m.qty_base), max(m.move_date)
    FROM inventory.stock_move m WHERE m.tenant_id = v_t AND m.company_id = p_company_id
   GROUP BY m.company_id, m.warehouse_id, m.item_id, m.variant_id, m.batch_id;
  SELECT min(m.move_date) AS d INTO v_first FROM inventory.stock_move m WHERE m.tenant_id = v_t AND m.company_id = p_company_id;
  INSERT INTO inventory.repost_run (tenant_id, company_id, trigger_reason, gl_floor_date)
  VALUES (v_t, p_company_id, 'integrity', coalesce(v_first.d, current_date)) RETURNING id INTO v_run;
  FOR p IN SELECT c.id FROM inventory.cost_pool c WHERE c.tenant_id = v_t AND c.company_id = p_company_id ORDER BY c.id LOOP
    DELETE FROM inventory.pool_checkpoint k WHERE k.tenant_id = v_t AND k.pool_id = p.id;
    SELECT s.move_date, s.posting_seq INTO v_first FROM inventory.stock_move s
     WHERE s.tenant_id = v_t AND s.pool_id = p.id ORDER BY s.move_date, s.posting_seq LIMIT 1;
    IF FOUND THEN
      UPDATE inventory.cost_pool SET dirty_from_date = v_first.move_date, dirty_from_seq = v_first.posting_seq, dirty_since = now()
       WHERE id = p.id;
      v_added := inventory.repost_pool(p.id, v_run, v_first.move_date);
      IF v_added > 0 THEN
        PERFORM core.raise_hk('HK_INV_REBUILD_MISMATCH', format('pool %s replay disagrees with imported layers (%s corrections)', p.id, v_added));
      END IF;
    END IF;
    n := n + 1;
  END LOOP;
  UPDATE inventory.repost_run SET status = 'completed', finished_at = now() WHERE id = v_run;
  RETURN n;
END $$;
ALTER FUNCTION inventory.rebuild_derived(uuid) OWNER TO hk_inventory_definer;
COMMENT ON FUNCTION inventory.rebuild_derived(uuid) IS 'HK_DEFINER_REVIEWED: 05-commerce §5-3; import hook / repair, RLS-bound to app.tenant_id';
REVOKE ALL ON FUNCTION inventory.rebuild_derived(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION inventory.rebuild_derived(uuid) TO hk_app;

-- =====================================================================
-- ۲۳. دسترسی‌ها (grant)
-- =====================================================================
-- hk_app: پیکربندی و اسناد کامل؛ دفتر موجودی فقط‌افزودنی؛ مشتق‌ها فقط خواندنی
GRANT SELECT, INSERT, UPDATE, DELETE ON inventory.company_policy, inventory.warehouse, inventory.location, inventory.branch_default,
  inventory.reorder_rule, inventory.batch, inventory.tracking_bundle, inventory.tracking_bundle_entry, inventory.stock_doc,
  inventory.stock_doc_line, inventory.count_session, inventory.count_line, inventory.periodic_close, inventory.periodic_close_line TO hk_app;
GRANT SELECT, INSERT ON inventory.stock_move, inventory.serial_move, inventory.count_entry, inventory.serial TO hk_app;
GRANT UPDATE (notes, warranty_provider_party_id) ON inventory.serial TO hk_app;
GRANT SELECT, INSERT, UPDATE ON inventory.repost_run TO hk_app;
GRANT SELECT ON inventory.valuation_layer, inventory.cost_pool, inventory.fifo_layer, inventory.pool_checkpoint,
  inventory.stock_balance, inventory.stock_exception TO hk_app;
GRANT UPDATE (status, resolved_by, resolved_at, resolution_note) ON inventory.stock_exception TO hk_app;
GRANT USAGE ON SEQUENCE inventory.posting_seq TO hk_app;

-- hk_inventory_definer: کمینهٔ لازم برای موتور
GRANT SELECT ON ALL TABLES IN SCHEMA inventory TO hk_inventory_definer;
GRANT INSERT, UPDATE, DELETE ON inventory.cost_pool, inventory.fifo_layer, inventory.pool_checkpoint, inventory.stock_balance TO hk_inventory_definer;
GRANT INSERT ON inventory.valuation_layer, inventory.stock_exception TO hk_inventory_definer;
GRANT INSERT, UPDATE ON inventory.repost_run TO hk_inventory_definer;
GRANT UPDATE ON inventory.serial TO hk_inventory_definer;
GRANT SELECT ON core.company, ref.currency, catalog.item TO hk_inventory_definer;

GRANT SELECT, INSERT, UPDATE, DELETE ON sales.pricing_rule, sales.pricing_rule_tier, sales."order", sales.order_line, sales.delivery,
  sales.delivery_line, sales.gl_batch, sales.invoice, sales.invoice_line, sales.invoice_line_discount, sales.invoice_salesperson,
  sales.commission_plan, sales.commission_rule, sales.commission_assignment TO hk_app;
GRANT SELECT, INSERT ON sales.credit_check, sales.commission_entry TO hk_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON purchase."order", purchase.order_line, purchase.receipt, purchase.receipt_line, purchase.invoice,
  purchase.invoice_line, purchase.invoice_charge, purchase.landed_cost_voucher, purchase.landed_cost_line, purchase.cost_allocation,
  purchase.moadian_inbox_batch, purchase.moadian_inbox_invoice TO hk_app;

GRANT SELECT ON inventory.v_move_value, inventory.v_kardex, inventory.v_stock_on_hand, inventory.v_batch_availability,
  sales.v_invoice_current, sales.v_line_returnable, sales.v_order_line_progress, sales.v_invoice_line_margin,
  purchase.v_receipt_line_unbilled TO hk_app;
GRANT SELECT ON ALL TABLES IN SCHEMA inventory, sales, purchase TO hk_readonly;

-- =====================================================================
-- ۲۴. ثبت در کاتالوگ‌های ماژول‌های پایه (کلید نگاشت، زیردفتر، مجوز، تنظیم، رویداد، صدور، فیلد سفارشی)
-- =====================================================================
INSERT INTO ledger.posting_key (key, owner_module, expected_account_types, is_required, name_fa, introduced_in) VALUES
  ('purchase.grni',                  'purchase',  '{liability}',        false, 'کالای دریافتی صورتحساب‌نشده', '1.0'),
  ('purchase.price_difference',      'purchase',  '{expense,income}',   false, 'تفاوت قیمت خرید', '1.0'),
  ('purchase.purchases',             'purchase',  '{expense}',          false, 'خرید کالا (حالت ادواری)', '1.0'),
  ('purchase.returns',               'purchase',  '{expense,income}',   false, 'برگشت از خرید (حالت ادواری)', '1.0'),
  ('purchase.discount',              'purchase',  '{expense,income}',   false, 'تخفیفات خرید (حالت ادواری)', '1.0'),
  ('purchase.landed_cost_clearing',  'purchase',  '{liability,asset}',  false, 'واسط هزینه‌های جانبی خرید', '1.0'),
  ('inventory.waste',                'inventory', '{expense}',          false, 'ضایعات کالا', '1.0'),
  ('inventory.internal_consumption', 'inventory', '{expense}',          false, 'مصرف داخلی کالا', '1.0'),
  ('inventory.opening_stock',        'inventory', '{expense}',          false, 'موجودی ابتدای دوره (بستن ادواری)', '1.0'),
  ('sales.commission_expense',       'sales',     '{expense}',          false, 'هزینهٔ پورسانت فروش', '1.0'),
  ('sales.commission_payable',       'sales',     '{liability}',        false, 'پورسانت پرداختنی', '1.0')
ON CONFLICT (key) DO NOTHING;

INSERT INTO ledger.subledger_source (subledger_kind, owner_module, balance_function, dim_slot, compare_txn, introduced_in)
VALUES ('inventory', 'inventory', 'inventory.ledger_subledger_stock', NULL, false, '1.0')
ON CONFLICT (subledger_kind) DO NOTHING;

INSERT INTO core.permission (code, module, scope_dimensions, risk, allow_service_account, allow_impersonation_write, description_key, introduced_in) VALUES
  ('inventory.warehouse.read',     'inventory', '{company,warehouse}',         'normal',    true,  false, 'perm.inventory.warehouse.read', '1.0'),
  ('inventory.warehouse.manage',   'inventory', '{company}',                   'sensitive', false, false, 'perm.inventory.warehouse.manage', '1.0'),
  ('inventory.policy.manage',      'inventory', '{company}',                   'critical',  false, false, 'perm.inventory.policy.manage', '1.0'),
  ('inventory.stock.read',         'inventory', '{company,branch,warehouse}',  'normal',    true,  false, 'perm.inventory.stock.read', '1.0'),
  ('inventory.cost.read',          'inventory', '{company,warehouse}',         'sensitive', true,  false, 'perm.inventory.cost.read', '1.0'),
  ('inventory.doc.create',         'inventory', '{company,branch,warehouse}',  'normal',    true,  false, 'perm.inventory.doc.create', '1.0'),
  ('inventory.doc.post',           'inventory', '{company,branch,warehouse}',  'sensitive', true,  false, 'perm.inventory.doc.post', '1.0'),
  ('inventory.doc.cancel',         'inventory', '{company,branch,warehouse}',  'sensitive', false, false, 'perm.inventory.doc.cancel', '1.0'),
  ('inventory.count.manage',       'inventory', '{company,warehouse}',         'normal',    true,  false, 'perm.inventory.count.manage', '1.0'),
  ('inventory.count.post',         'inventory', '{company,warehouse}',         'sensitive', false, false, 'perm.inventory.count.post', '1.0'),
  ('inventory.cost.adjust',        'inventory', '{company}',                   'critical',  false, false, 'perm.inventory.cost.adjust', '1.0'),
  ('inventory.valuation.repost',   'inventory', '{company}',                   'sensitive', true,  false, 'perm.inventory.valuation.repost', '1.0'),
  ('inventory.serial.manage',      'inventory', '{company,warehouse}',         'normal',    true,  false, 'perm.inventory.serial.manage', '1.0'),
  ('inventory.exception.resolve',  'inventory', '{company,warehouse}',         'sensitive', false, false, 'perm.inventory.exception.resolve', '1.0'),
  ('inventory.periodic.close',     'inventory', '{company}',                   'critical',  false, false, 'perm.inventory.periodic.close', '1.0'),
  ('inventory.opening.import',     'inventory', '{company}',                   'critical',  true,  false, 'perm.inventory.opening.import', '1.0'),
  ('sales.pricing.read',           'sales',     '{company,branch}',            'normal',    true,  false, 'perm.sales.pricing.read', '1.0'),
  ('sales.pricing.manage',         'sales',     '{company}',                   'sensitive', false, false, 'perm.sales.pricing.manage', '1.0'),
  ('sales.order.create',           'sales',     '{company,branch}',            'normal',    true,  false, 'perm.sales.order.create', '1.0'),
  ('sales.order.confirm',          'sales',     '{company,branch}',            'normal',    true,  false, 'perm.sales.order.confirm', '1.0'),
  ('sales.order.cancel',           'sales',     '{company,branch}',            'sensitive', false, false, 'perm.sales.order.cancel', '1.0'),
  ('sales.delivery.post',          'sales',     '{company,branch,warehouse}',  'normal',    true,  false, 'perm.sales.delivery.post', '1.0'),
  ('sales.delivery.cancel',        'sales',     '{company,branch,warehouse}',  'sensitive', false, false, 'perm.sales.delivery.cancel', '1.0'),
  ('sales.invoice.read',           'sales',     '{company,branch}',            'normal',    true,  false, 'perm.sales.invoice.read', '1.0'),
  ('sales.invoice.create',         'sales',     '{company,branch}',            'normal',    true,  false, 'perm.sales.invoice.create', '1.0'),
  ('sales.invoice.post',           'sales',     '{company,branch}',            'sensitive', true,  false, 'perm.sales.invoice.post', '1.0'),
  ('sales.invoice.cancel',         'sales',     '{company,branch}',            'critical',  false, false, 'perm.sales.invoice.cancel', '1.0'),
  ('sales.return.post',            'sales',     '{company,branch}',            'sensitive', true,  false, 'perm.sales.return.post', '1.0'),
  ('sales.correction.post',        'sales',     '{company,branch}',            'sensitive', false, false, 'perm.sales.correction.post', '1.0'),
  ('sales.price.override',         'sales',     '{company,branch}',            'sensitive', false, false, 'perm.sales.price.override', '1.0'),
  ('sales.discount.manual',        'sales',     '{company,branch}',            'normal',    false, false, 'perm.sales.discount.manual', '1.0'),
  ('sales.credit.override',        'sales',     '{company}',                   'critical',  false, false, 'perm.sales.credit.override', '1.0'),
  ('sales.commission.read',        'sales',     '{company}',                   'normal',    true,  false, 'perm.sales.commission.read', '1.0'),
  ('sales.commission.manage',      'sales',     '{company}',                   'sensitive', false, false, 'perm.sales.commission.manage', '1.0'),
  ('sales.report.read',            'sales',     '{company,branch}',            'normal',    true,  false, 'perm.sales.report.read', '1.0'),
  ('sales.history.import',         'sales',     '{company}',                   'critical',  true,  false, 'perm.sales.history.import', '1.0'),
  ('purchase.order.create',        'purchase',  '{company,branch}',            'normal',    true,  false, 'perm.purchase.order.create', '1.0'),
  ('purchase.order.approve',       'purchase',  '{company,branch}',            'sensitive', false, false, 'perm.purchase.order.approve', '1.0'),
  ('purchase.order.cancel',        'purchase',  '{company,branch}',            'sensitive', false, false, 'perm.purchase.order.cancel', '1.0'),
  ('purchase.receipt.post',        'purchase',  '{company,branch,warehouse}',  'normal',    true,  false, 'perm.purchase.receipt.post', '1.0'),
  ('purchase.receipt.cancel',      'purchase',  '{company,branch,warehouse}',  'sensitive', false, false, 'perm.purchase.receipt.cancel', '1.0'),
  ('purchase.invoice.read',        'purchase',  '{company,branch}',            'normal',    true,  false, 'perm.purchase.invoice.read', '1.0'),
  ('purchase.invoice.create',      'purchase',  '{company,branch}',            'normal',    true,  false, 'perm.purchase.invoice.create', '1.0'),
  ('purchase.invoice.post',        'purchase',  '{company,branch}',            'sensitive', true,  false, 'perm.purchase.invoice.post', '1.0'),
  ('purchase.invoice.cancel',      'purchase',  '{company,branch}',            'critical',  false, false, 'perm.purchase.invoice.cancel', '1.0'),
  ('purchase.return.post',         'purchase',  '{company,branch}',            'sensitive', true,  false, 'perm.purchase.return.post', '1.0'),
  ('purchase.landed_cost.post',    'purchase',  '{company}',                   'sensitive', false, false, 'perm.purchase.landed_cost.post', '1.0'),
  ('purchase.inbox.import',        'purchase',  '{company}',                   'sensitive', true,  false, 'perm.purchase.inbox.import', '1.0'),
  ('purchase.inbox.match',         'purchase',  '{company}',                   'normal',    true,  false, 'perm.purchase.inbox.match', '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.role_template_permission (template_code, permission_code)
SELECT 'warehouse_keeper', code FROM core.permission WHERE code IN
  ('inventory.warehouse.read','inventory.stock.read','inventory.doc.create','inventory.doc.post','inventory.count.manage',
   'inventory.serial.manage','sales.delivery.post','purchase.receipt.post','purchase.order.create')
UNION ALL SELECT 'sales_clerk', code FROM core.permission WHERE code IN
  ('inventory.stock.read','sales.pricing.read','sales.order.create','sales.order.confirm','sales.invoice.read','sales.invoice.create',
   'sales.invoice.post','sales.return.post','sales.discount.manual','sales.delivery.post')
UNION ALL SELECT 'cashier', code FROM core.permission WHERE code IN
  ('inventory.stock.read','sales.pricing.read','sales.invoice.read','sales.invoice.create','sales.invoice.post','sales.return.post',
   'sales.discount.manual')
UNION ALL SELECT 'purchaser', code FROM core.permission WHERE code IN
  ('inventory.stock.read','purchase.order.create','purchase.receipt.post','purchase.invoice.read','purchase.invoice.create',
   'purchase.invoice.post','purchase.return.post','purchase.inbox.import','purchase.inbox.match')
UNION ALL SELECT 'accountant', code FROM core.permission WHERE module IN ('inventory','sales','purchase')
   AND code NOT IN ('inventory.policy.manage','sales.credit.override','sales.invoice.cancel','purchase.invoice.cancel')
UNION ALL SELECT 'auditor', code FROM core.permission WHERE code IN
  ('inventory.warehouse.read','inventory.stock.read','inventory.cost.read','sales.pricing.read','sales.invoice.read','sales.report.read',
   'sales.commission.read','purchase.invoice.read')
UNION ALL SELECT 'admin', code FROM core.permission WHERE module IN ('inventory','sales','purchase')
ON CONFLICT DO NOTHING;

INSERT INTO core.field_guard (resource, field, read_permission, write_permission, mask_style, is_secret) VALUES
  ('inventory.stock', 'unit_cost',        'inventory.cost.read', 'inventory.cost.adjust', 'omit', false),
  ('inventory.stock', 'value',            'inventory.cost.read', 'inventory.cost.adjust', 'omit', false),
  ('sales.invoice_line', 'cost_amount',   'inventory.cost.read', 'inventory.cost.adjust', 'omit', false),
  ('sales.invoice_line', 'margin_amount', 'inventory.cost.read', 'inventory.cost.adjust', 'omit', false)
ON CONFLICT DO NOTHING;

INSERT INTO core.setting_def (key, module, value_type, enum_values, min_value, max_value, allowed_levels, default_value,
                              read_permission, write_permission, description_key, introduced_in) VALUES
  ('inventory.expired_batch_sale',            'inventory', 'enum', '{warn,block}', NULL, NULL, '{tenant,company,branch}', '"warn"', NULL, 'inventory.policy.manage', 'setting.inventory.expired_batch_sale', '1.0'),
  ('inventory.repost.inline_limit',           'inventory', 'int', NULL, 0, 10000, '{tenant,company}', '200', NULL, 'inventory.policy.manage', 'setting.inventory.repost.inline_limit', '1.0'),
  ('inventory.fefo.enforce',                  'inventory', 'bool', NULL, NULL, NULL, '{tenant,company,branch}', 'false', NULL, 'inventory.policy.manage', 'setting.inventory.fefo.enforce', '1.0'),
  ('sales.discount.max_manual_percent',       'sales', 'decimal', NULL, 0, 100, '{tenant,company,branch}', '"10"', NULL, 'sales.pricing.manage', 'setting.sales.discount.max_manual_percent', '1.0'),
  ('sales.credit.check_on',                   'sales', 'enum', '{order,invoice,both}', NULL, NULL, '{tenant,company}', '"both"', NULL, 'sales.pricing.manage', 'setting.sales.credit.check_on', '1.0'),
  ('sales.cash_rounding.increment',           'sales', 'decimal', NULL, 0, 1000000, '{tenant,company,branch}', '"0"', NULL, 'sales.pricing.manage', 'setting.sales.cash_rounding.increment', '1.0'),
  ('sales.below_cost',                        'sales', 'enum', '{allow,warn,block}', NULL, NULL, '{tenant,company,branch}', '"warn"', NULL, 'sales.pricing.manage', 'setting.sales.below_cost', '1.0'),
  ('sales.invoice.max_backdate_days',         'sales', 'int', NULL, 0, 365, '{tenant,company}', '7', NULL, 'sales.pricing.manage', 'setting.sales.invoice.max_backdate_days', '1.0'),
  ('sales.return.window_days',                'sales', 'int', NULL, 0, 3650, '{tenant,company}', '0', NULL, 'sales.pricing.manage', 'setting.sales.return.window_days', '1.0'),
  ('purchase.receipt.over_receipt_percent',   'purchase', 'decimal', NULL, 0, 100, '{tenant,company}', '"0"', NULL, 'purchase.order.approve', 'setting.purchase.receipt.over_receipt_percent', '1.0'),
  ('purchase.invoice.price_tolerance_percent','purchase', 'decimal', NULL, 0, 100, '{tenant,company}', '"0"', NULL, 'purchase.order.approve', 'setting.purchase.invoice.price_tolerance_percent', '1.0')
ON CONFLICT (key) DO NOTHING;

INSERT INTO core.event_subscriber (subscriber, ordered, max_attempts, requires_webhook_endpoint, introduced_in) VALUES
  ('inventory.party_merge',  true,  25, false, '1.0'),
  ('sales.party_merge',      true,  25, false, '1.0'),
  ('purchase.party_merge',   true,  25, false, '1.0'),
  ('inventory.year_close',   true,  25, false, '1.0')
ON CONFLICT DO NOTHING;
INSERT INTO core.event_subscription (event_type, subscriber) VALUES
  ('parties.party.merged',       'inventory.party_merge'),
  ('parties.party.merged',       'sales.party_merge'),
  ('parties.party.merged',       'purchase.party_merge'),
  ('ledger.year.closed',         'inventory.year_close')
ON CONFLICT DO NOTHING;

INSERT INTO core.custom_field_entity (entity_type, module, table_name, json_column, max_fields, description_key) VALUES
  ('sales.invoice', 'sales', 'sales.invoice',   'custom', 50, 'custom_field.entity.sales.invoice'),
  ('sales.order',   'sales', 'sales."order"',   'custom', 50, 'custom_field.entity.sales.order')
ON CONFLICT (entity_type) DO NOTHING;

INSERT INTO core.export_table_registry (schema_name, table_name, module, mode, export_order, pii_columns, secret_columns, note) VALUES
  ('inventory','company_policy',        'inventory', 'rows', 500, '{}', '{}', NULL),
  ('inventory','warehouse',             'inventory', 'rows', 502, '{}', '{}', NULL),
  ('inventory','location',              'inventory', 'rows', 504, '{}', '{}', NULL),
  ('inventory','branch_default',        'inventory', 'rows', 506, '{}', '{}', NULL),
  ('inventory','reorder_rule',          'inventory', 'rows', 508, '{}', '{}', NULL),
  ('inventory','batch',                 'inventory', 'rows', 510, '{}', '{}', NULL),
  ('inventory','serial',                'inventory', 'rows', 512, '{}', '{}', 'state columns re-verified by inventory.verify_derived after import'),
  ('inventory','tracking_bundle',       'inventory', 'rows', 514, '{}', '{}', NULL),
  ('inventory','tracking_bundle_entry', 'inventory', 'rows', 516, '{}', '{}', NULL),
  ('inventory','count_session',         'inventory', 'rows', 518, '{}', '{}', NULL),
  ('inventory','stock_doc',             'inventory', 'rows', 520, '{}', '{}', NULL),
  ('inventory','stock_doc_line',        'inventory', 'rows', 522, '{}', '{}', NULL),
  ('inventory','cost_pool',             'inventory', 'rows', 524, '{}', '{}', 'derived numbers; recomputed by inventory.rebuild_derived in the import hook'),
  ('inventory','repost_run',            'inventory', 'rows', 526, '{}', '{}', NULL),
  ('inventory','stock_move',            'inventory', 'rows', 528, '{}', '{}', 'verbatim; import hook calls setval(inventory.posting_seq) and rebuild_derived'),
  ('inventory','serial_move',           'inventory', 'rows', 530, '{}', '{}', NULL),
  ('inventory','valuation_layer',       'inventory', 'rows', 532, '{}', '{}', 'verbatim; replay must reproduce it (HK_INV_REBUILD_MISMATCH otherwise)'),
  ('inventory','fifo_layer',            'inventory', 'skip', 0,   '{}', '{}', 'derived; rebuilt by inventory.rebuild_derived'),
  ('inventory','pool_checkpoint',       'inventory', 'skip', 0,   '{}', '{}', 'derived; recreated by the checkpoint job'),
  ('inventory','stock_balance',         'inventory', 'skip', 0,   '{}', '{}', 'derived; rebuilt by inventory.rebuild_derived'),
  ('inventory','stock_exception',       'inventory', 'rows', 534, '{}', '{}', NULL),
  ('inventory','count_line',            'inventory', 'rows', 536, '{}', '{}', NULL),
  ('inventory','count_entry',           'inventory', 'rows', 538, '{}', '{}', NULL),
  ('inventory','periodic_close',        'inventory', 'rows', 540, '{}', '{}', NULL),
  ('inventory','periodic_close_line',   'inventory', 'rows', 542, '{}', '{}', NULL),
  ('sales','pricing_rule',              'sales', 'rows', 600, '{}', '{}', NULL),
  ('sales','pricing_rule_tier',         'sales', 'rows', 602, '{}', '{}', NULL),
  ('sales','order',                     'sales', 'rows', 604, '{}', '{}', NULL),
  ('sales','order_line',                'sales', 'rows', 606, '{}', '{}', NULL),
  ('sales','delivery',                  'sales', 'rows', 608, '{}', '{}', NULL),
  ('sales','delivery_line',             'sales', 'rows', 610, '{}', '{}', NULL),
  ('sales','gl_batch',                  'sales', 'rows', 612, '{}', '{}', NULL),
  ('sales','credit_check',              'sales', 'rows', 614, '{}', '{}', NULL),
  ('sales','invoice',                   'sales', 'rows', 616, '{buyer_name,buyer_national_id,buyer_postal_code,buyer_passport_no}', '{}', NULL),
  ('sales','invoice_line',              'sales', 'rows', 618, '{}', '{}', NULL),
  ('sales','invoice_line_discount',     'sales', 'rows', 620, '{}', '{}', NULL),
  ('sales','invoice_salesperson',       'sales', 'rows', 622, '{}', '{}', NULL),
  ('sales','commission_plan',           'sales', 'rows', 626, '{}', '{}', NULL),
  ('sales','commission_rule',           'sales', 'rows', 628, '{}', '{}', NULL),
  ('sales','commission_assignment',     'sales', 'rows', 630, '{}', '{}', NULL),
  ('sales','commission_entry',          'sales', 'rows', 632, '{}', '{}', NULL),
  ('purchase','order',                  'purchase', 'rows', 700, '{}', '{}', NULL),
  ('purchase','order_line',             'purchase', 'rows', 702, '{}', '{}', NULL),
  ('purchase','receipt',                'purchase', 'rows', 704, '{}', '{}', NULL),
  ('purchase','receipt_line',           'purchase', 'rows', 706, '{}', '{}', NULL),
  ('purchase','invoice',                'purchase', 'rows', 708, '{}', '{}', NULL),
  ('purchase','invoice_line',           'purchase', 'rows', 710, '{}', '{}', NULL),
  ('purchase','invoice_charge',         'purchase', 'rows', 712, '{}', '{}', NULL),
  ('purchase','landed_cost_voucher',    'purchase', 'rows', 714, '{}', '{}', NULL),
  ('purchase','landed_cost_line',       'purchase', 'rows', 716, '{}', '{}', NULL),
  ('purchase','cost_allocation',        'purchase', 'rows', 718, '{}', '{}', NULL),
  ('purchase','moadian_inbox_batch',    'purchase', 'rows', 722, '{}', '{}', NULL),
  ('purchase','moadian_inbox_invoice',  'purchase', 'rows', 724, '{}', '{}', NULL)
ON CONFLICT DO NOTHING;
