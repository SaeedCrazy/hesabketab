-- =====================================================================
-- حساب‌کتاب — dev_roles.sql   (فقط توسعه و آزمون محلی؛ هرگز در استقرار)
-- مالک: یکپارچه‌ساز. R-ROLE در docs/design/change-requests.md.
--
-- 00_foundation.sql (و 70_platform.sql) نقش‌ها را NOLOGIN و بدون رمز می‌سازند. در استقرار،
-- hk migrate / hkctl رمز را از SecretStore می‌گیرد و «ALTER ROLE … LOGIN PASSWORD» اجرا می‌کند.
-- این اسکریپت برای خوشهٔ توسعه همان کار را با رمزهای شناخته‌شده (رمز = نام نقش) می‌کند تا
-- آزمون‌های پایتون/psycopg بتوانند مستقیم وصل شوند.
--
-- اجرا (بعد از 00_foundation.sql یا 70_platform.sql):
--   psql -v hk_dev_ok=1 -d <db> -f docs/design/sql/dev_roles.sql
-- بدون -v hk_dev_ok=1 با خطا متوقف می‌شود. نقش‌های مالک definer هرگز ورود نمی‌گیرند.
-- =====================================================================
\set ON_ERROR_STOP 1

\if :{?hk_dev_ok}
\else
DO $$ BEGIN
  RAISE EXCEPTION 'HK_DEV_ROLES_REFUSED: dev_roles.sql sets well-known passwords; run it only on a dev/test cluster with psql -v hk_dev_ok=1';
END $$;
\endif

DO $$
DECLARE r text;
BEGIN
  IF current_setting('hk.environment', true) = 'production' THEN
    RAISE EXCEPTION 'HK_DEV_ROLES_REFUSED: hk.environment = production';
  END IF;
  FOREACH r IN ARRAY ARRAY[
      -- صفحهٔ داده
      'hk_migrator', 'hk_app', 'hk_readonly', 'hk_reports', 'hk_dispatcher',
      -- صفحهٔ کنترل (70_platform.sql)
      'hk_platform_app', 'hk_platform_ingest', 'hk_partner_app', 'hk_platform_readonly'] LOOP
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L', r, r);
    END IF;
  END LOOP;
END $$;
