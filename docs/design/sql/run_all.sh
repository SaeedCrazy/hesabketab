#!/usr/bin/env bash
# =====================================================================
# حساب‌کتاب — run_all.sh : هارنس یکپارچه‌سازی SQL طراحی (مالک: یکپارچه‌ساز)
#
# چه می‌کند:
#   (a) برای هر بخش دارای SQL یک پایگاه تازهٔ <PREFIX>_<key> می‌سازد، زنجیرهٔ مستقل
#       همان بخش را اعمال و فایل آزمونش را اجرا می‌کند. platform تنها و روی پایگاه جدا
#       (پایگاه کنترل؛ بدون 00_foundation) اعمال می‌شود.
#   (b) پایگاه یکپارچهٔ صفحهٔ داده <PREFIX>_all: 00,10,20,25,30,40,50,60,80 سپس 99_cross_fk.sql،
#       سپس core.security_lint() (+ lint تکمیلی هارنس) و tests/99_integration_test.sql (lint سراسری، نشت
#       بین‌مستأجری، جریان‌های سرتاسری؛ مالک: یکپارچه‌ساز بخش ۲). گام d روی همین پایگاه و با دادهٔ همین آزمون اجرا می‌شود.
#   (c) همان زنجیره با ترتیب دوم (00,10,25,20,30,40,50,60,80,99) روی <PREFIX>_all2.
#   (d) اعمال دوبارهٔ همهٔ فایل‌ها روی <PREFIX>_all (اثبات idempotency) و lint دوباره.
#   (e) جدول نهایی PASS/FAIL با مسیر لاگ‌ها؛ کد خروج ≠ ۰ اگر چیزی شکست؛ حذف پایگاه‌ها مگر KEEP_DBS=1.
#
# ترتیب‌های الزامی (مستند؛ HK_PREREQ در خود فایل‌ها):
#   - 00_foundation همیشه اول (پایگاه UTF8؛ HK_ENCODING).
#   - 30_commerce، 40_treasury_pos، 50_compliance پیش‌نیاز 10، 20 و 25 را دارند.
#   - 60_migration و 80_assistant به 10 (و 60 به 20 و 25) نیاز دارند.
#   - 20_ledger و 25_masterdata نسبت به هم مستقل‌اند (ترتیب دوم همین را می‌سنجد).
#   - 30 پیش از 40 و 50 در زنجیرهٔ یکپارچه می‌آید چون 40/50 در غیاب 30 هم اعمال می‌شوند ولی
#     FKهای مشترک فقط در 99 ساخته می‌شوند؛ ترتیب 30/40/50/60/80 بین خودشان آزموده نمی‌شود.
#   - 99_cross_fk.sql همیشه آخر و پیش از هر دادهٔ آزمون (FKهای کنشگر به عضویت؛ C-L18).
#   - 70_platform فقط روی پایگاه جدای کنترل (HK_PLT_WRONG_DATABASE روی پایگاه داده).
#
# استفاده:
#   PREFIX=hk_it docs/design/sql/run_all.sh                 # همه
#   PREFIX=hk_it docs/design/sql/run_all.sh core ledger     # فقط این بخش‌ها
#   گام‌های قابل انتخاب: core ledger masterdata commerce treasury_pos compliance migration
#                        platform assistant integrated order2 idempotency
#   (idempotency به integrated نیاز دارد و با آن اجرا می‌شود.)
# متغیرها: PGHOST PGPORT PGUSER PGPASSWORD PREFIX KEEP_DBS=1 LOG_ROOT
#          INTEGRATED_TESTS=1 (اختیاری: آزمون هر بخش روی کپی پایگاه یکپارچه پس از 99)
# =====================================================================
set -euo pipefail

: "${PGHOST:=localhost}"
: "${PGPORT:=5433}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGUSER PGPASSWORD
PREFIX="${PREFIX:-hk_it}"
DBP="${PREFIX%_}"                       # PREFIX=it_ → it_core ، PREFIX=hk_it → hk_it_core
KEEP_DBS="${KEEP_DBS:-0}"
INTEGRATED_TESTS="${INTEGRATED_TESTS:-0}"

SQL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SQL_DIR/../../.." && pwd)"
LOG_ROOT="${LOG_ROOT:-${TMPDIR:-/tmp}/hk-harness-logs}"
LOG_DIR="$LOG_ROOT/$PREFIX"
mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*.log

# آزمون‌ها مسیر فایل‌های بردار را نسبت به ریشهٔ مخزن می‌خوانند.
cd "$REPO_ROOT"
REL_SQL="${SQL_DIR#"$REPO_ROOT"/}"

PSQL=(psql -X -q -v ON_ERROR_STOP=1)

# ---------- زنجیره‌ها ----------
declare -A CHAIN TEST
CHAIN[core]="00_foundation 10_core";                                   TEST[core]=10_core_test
CHAIN[ledger]="00_foundation 20_ledger";                               TEST[ledger]=20_ledger_test
CHAIN[masterdata]="00_foundation 25_masterdata";                       TEST[masterdata]=25_masterdata_test
CHAIN[commerce]="00_foundation 10_core 20_ledger 25_masterdata 30_commerce";         TEST[commerce]=30_commerce_test
CHAIN[treasury_pos]="00_foundation 10_core 20_ledger 25_masterdata 40_treasury_pos"; TEST[treasury_pos]=40_treasury_pos_test
CHAIN[compliance]="00_foundation 10_core 20_ledger 25_masterdata 50_compliance";     TEST[compliance]=50_compliance_test
CHAIN[migration]="00_foundation 10_core 20_ledger 25_masterdata 60_migration";       TEST[migration]=60_migration_test
CHAIN[platform]="70_platform";                                         TEST[platform]=70_platform_test
CHAIN[assistant]="00_foundation 10_core 20_ledger 25_masterdata 80_assistant";       TEST[assistant]=80_assistant_test
SECTIONS=(core ledger masterdata commerce treasury_pos compliance migration platform assistant)

DATA_PLANE_ORDER1="00_foundation 10_core 20_ledger 25_masterdata 30_commerce 40_treasury_pos 50_compliance 60_migration 80_assistant 99_cross_fk"
DATA_PLANE_ORDER2="00_foundation 10_core 25_masterdata 20_ledger 30_commerce 40_treasury_pos 50_compliance 60_migration 80_assistant 99_cross_fk"

# ---------- allowlist یافته‌های core.security_lint() ----------
# قالب: "object|problem|دلیل". فقط با دلیل صریح و شناسهٔ یافته/تصمیم.
LINT_ALLOW=(
)

# ---------- ثبت نتیجه ----------
R_NAME=(); R_STATUS=(); R_LOG=()
record() { R_NAME+=("$1"); R_STATUS+=("$2"); R_LOG+=("$3"); }
ANY_FAIL=0
CREATED_DBS=()

log_for() { echo "$LOG_DIR/$1.log"; }

# اجرای یک فرمان؛ خروجی در لاگ؛ PASS اگر کد ۰
run_cmd() {   # name logfile cmd...
  local name="$1" log="$2"; shift 2
  if "$@" >"$log" 2>&1; then record "$name" PASS "$log"; return 0
  else record "$name" FAIL "$log"; ANY_FAIL=1; return 1; fi
}

skip() { record "$1" SKIP "-"; }

create_db() {  # db logfile
  local db="$1" log="$2"
  {
    psql -X -q -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" &&
    psql -X -q -d postgres -v ON_ERROR_STOP=1 \
      -c "CREATE DATABASE \"$db\" ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8'"
  } >"$log" 2>&1
  local rc=$?
  [[ $rc -eq 0 ]] && CREATED_DBS+=("$db")
  return $rc
}

clone_db() {  # src dst logfile
  local src="$1" dst="$2" log="$3"
  {
    psql -X -q -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$dst\" WITH (FORCE)" &&
    psql -X -q -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$dst\" TEMPLATE \"$src\""
  } >"$log" 2>&1
  local rc=$?
  [[ $rc -eq 0 ]] && CREATED_DBS+=("$dst")
  return $rc
}

apply_file() {  # db file(base name w/o .sql) stepname
  local db="$1" f="$2" step="$3"
  local log; log="$(log_for "$step")"
  run_cmd "$step" "$log" "${PSQL[@]}" -d "$db" -f "$REL_SQL/$f.sql"
}

run_test() {  # db testbase stepname
  local db="$1" t="$2" step="$3"
  local log; log="$(log_for "$step")"
  local rc=0
  "${PSQL[@]}" -d "$db" -f "$REL_SQL/tests/$t.sql" >"$log" 2>&1 || rc=$?
  if [[ $rc -eq 0 ]] && grep -q "TESTS PASSED" "$log" && ! grep -q "TEST FAILED" "$log"; then
    record "$step" PASS "$log"; return 0
  fi
  echo "[harness] exit=$rc" >>"$log"
  record "$step" FAIL "$log"; ANY_FAIL=1; return 1
}

# lint: core.security_lint() + بررسی تکمیلی هارنس روی همهٔ اسکیماهای غیرسیستمی
# (security_lint فهرست ثابت اسکیما دارد و مثلاً assistant را نمی‌بیند؛ یافتهٔ C-AS-04)
lint_db() {  # db stepname
  local db="$1" step="$2"
  local log; log="$(log_for "$step")"
  local rc=0
  {
    echo "== core.security_lint()"
    psql -X -At -d "$db" -v ON_ERROR_STOP=1 -c "SELECT object || '|' || problem FROM core.security_lint() ORDER BY 1" \
      > "$log.rows" || rc=$?
    cat "$log.rows"
    echo "== harness_lint (all non-system schemas)"
    psql -X -At -d "$db" -v ON_ERROR_STOP=1 >> "$log.rows" <<'SQL' || rc=$?
WITH sch AS (
  SELECT n.oid, n.nspname FROM pg_namespace n
   WHERE n.nspname NOT IN ('pg_catalog','information_schema','public','pg_toast')
     AND n.nspname NOT LIKE 'pg\_%'
), tt AS (
  SELECT c.oid, c.oid::regclass::text AS name, c.relrowsecurity, c.relforcerowsecurity
    FROM pg_class c JOIN sch ON sch.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
   WHERE c.relkind IN ('r','p')
)
SELECT name || '|harness:rls_not_enabled_or_forced' FROM tt WHERE NOT relrowsecurity OR NOT relforcerowsecurity
UNION ALL
SELECT name || '|harness:rls_no_policy' FROM tt WHERE NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = tt.oid)
UNION ALL
SELECT c.oid::regclass::text || '|harness:view_without_security_invoker'
  FROM pg_class c JOIN sch ON sch.oid = c.relnamespace
 WHERE c.relkind = 'v'
   AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(c.reloptions, '{}')) o
                    WHERE lower(o) IN ('security_invoker=true','security_invoker=on','security_invoker=1'))
UNION ALL
SELECT r.rolname || '|harness:runtime_role_privileged' FROM pg_roles r
 WHERE r.rolname IN ('hk_app','hk_readonly','hk_dispatcher','hk_reports','hk_audit_writer','hk_core_definer',
                     'hk_ledger_definer','hk_inventory_definer')
   AND (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb)
UNION ALL
SELECT c.oid::regclass::text || '|harness:runtime_role_owns_relation'
  FROM pg_class c JOIN sch ON sch.oid = c.relnamespace JOIN pg_roles r ON r.oid = c.relowner
 WHERE r.rolname IN ('hk_app','hk_readonly','hk_dispatcher','hk_reports')
ORDER BY 1
SQL
    sed -n '/harness:/p' "$log.rows"
  } >"$log" 2>&1
  if [[ $rc -ne 0 ]]; then record "$step" FAIL "$log"; ANY_FAIL=1; rm -f "$log.rows"; return 1; fi
  local bad=0 line allowed a
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    allowed=0
    for a in "${LINT_ALLOW[@]+"${LINT_ALLOW[@]}"}"; do
      [[ "${a%|*}" == "$line" ]] && allowed=1 && break
    done
    if [[ $allowed -eq 1 ]]; then echo "ALLOWED: $line" >>"$log"; else echo "NOT ALLOWED: $line" >>"$log"; bad=$((bad+1)); fi
  done < "$log.rows"
  rm -f "$log.rows"
  echo "[harness] lint findings not on allowlist: $bad" >>"$log"
  if [[ $bad -eq 0 ]]; then record "$step" PASS "$log"; return 0; fi
  record "$step" FAIL "$log"; ANY_FAIL=1; return 1
}

apply_chain() {  # db "files" label  → returns 1 at first failure (rest SKIP)
  local db="$1" files="$2" label="$3" f failed=0
  for f in $files; do
    if [[ $failed -eq 1 ]]; then skip "$label:$f"; continue; fi
    if [[ ! -f "$SQL_DIR/$f.sql" ]]; then record "$label:$f" FAIL "(missing $f.sql)"; ANY_FAIL=1; failed=1; continue; fi
    apply_file "$db" "$f" "$label:$f" || failed=1
  done
  return $failed
}

# ---------- انتخاب گام‌ها ----------
declare -A WANT
if [[ $# -eq 0 ]]; then
  for s in "${SECTIONS[@]}" integrated order2 idempotency; do WANT[$s]=1; done
else
  for a in "$@"; do
    case "$a" in
      core|ledger|masterdata|commerce|treasury_pos|compliance|migration|platform|assistant|integrated|order2) WANT[$a]=1 ;;
      idempotency) WANT[integrated]=1; WANT[idempotency]=1 ;;
      *) echo "unknown step: $a" >&2; exit 2 ;;
    esac
  done
fi

psql -X -q -d postgres -c "SELECT 1" >/dev/null || { echo "cannot connect to $PGHOST:$PGPORT as $PGUSER" >&2; exit 2; }

# ---------- (a) هر بخش جدا ----------
for s in "${SECTIONS[@]}"; do
  [[ -n "${WANT[$s]:-}" ]] || continue
  db="${DBP}_${s}"
  echo ">> section $s → $db"
  if ! create_db "$db" "$(log_for "$s:createdb")"; then record "$s:createdb" FAIL "$(log_for "$s:createdb")"; ANY_FAIL=1; continue; fi
  if apply_chain "$db" "${CHAIN[$s]}" "$s"; then
    run_test "$db" "${TEST[$s]}" "$s:test" || true
    if [[ "$s" == "platform" ]]; then
      apply_file "$db" 70_platform "platform:reapply(idempotency)" || true
    fi
  else
    skip "$s:test"
  fi
done

# ---------- (b) + (d) پایگاه یکپارچه ----------
if [[ -n "${WANT[integrated]:-}" ]]; then
  db="${DBP}_all"
  echo ">> integrated → $db"
  if create_db "$db" "$(log_for "all:createdb")"; then
    if apply_chain "$db" "$DATA_PLANE_ORDER1" "all"; then
      lint_db "$db" "all:security_lint" || true
      if [[ "$INTEGRATED_TESTS" == "1" ]]; then
        for s in core ledger masterdata commerce treasury_pos compliance migration assistant; do
          c="${DBP}_all_t_${s}"
          if clone_db "$db" "$c" "$(log_for "all+test:$s:clone")"; then
            run_test "$c" "${TEST[$s]}" "all+test:$s" || true
          else record "all+test:$s" FAIL "$(log_for "all+test:$s:clone")"; ANY_FAIL=1; fi
        done
      fi
      if [[ -f "$SQL_DIR/tests/99_integration_test.sql" ]]; then
        run_test "$db" 99_integration_test "all:99_integration_test" || true
      fi
      if [[ -n "${WANT[idempotency]:-}" ]]; then
        echo ">> idempotency (re-apply on $db)"
        for f in $DATA_PLANE_ORDER1; do apply_file "$db" "$f" "idem:$f" || true; done
        lint_db "$db" "idem:security_lint" || true
      fi
    fi
  else
    record "all:createdb" FAIL "$(log_for "all:createdb")"; ANY_FAIL=1
  fi
fi

# ---------- (c) ترتیب دوم ----------
if [[ -n "${WANT[order2]:-}" ]]; then
  db="${DBP}_all2"
  echo ">> order2 → $db"
  if create_db "$db" "$(log_for "order2:createdb")"; then
    if apply_chain "$db" "$DATA_PLANE_ORDER2" "order2"; then
      lint_db "$db" "order2:security_lint" || true
    fi
  else
    record "order2:createdb" FAIL "$(log_for "order2:createdb")"; ANY_FAIL=1
  fi
fi

# ---------- (e) گزارش ----------
echo
printf '%-44s %-6s %s\n' "STEP" "RESULT" "LOG"
printf '%-44s %-6s %s\n' "----" "------" "---"
for i in "${!R_NAME[@]}"; do
  printf '%-44s %-6s %s\n' "${R_NAME[$i]}" "${R_STATUS[$i]}" "${R_LOG[$i]}"
done
npass=0; nfail=0; nskip=0
for st in "${R_STATUS[@]}"; do
  case "$st" in PASS) npass=$((npass+1));; FAIL) nfail=$((nfail+1));; SKIP) nskip=$((nskip+1));; esac
done
echo
echo "PASS=$npass FAIL=$nfail SKIP=$nskip  (logs: $LOG_DIR)"
# خلاصهٔ شکست آزمون یکپارچه (هر بررسی با شناسهٔ یافته و مسئول؛ جدول کامل در لاگ همان گام)
for i in "${!R_NAME[@]}"; do
  if [[ "${R_NAME[$i]}" == "all:99_integration_test" && "${R_STATUS[$i]}" == "FAIL" ]]; then
    echo
    grep -o 'TEST FAILED: .*' "${R_LOG[$i]}" | head -1 | sed -e 's/ failed: / failed:\n  - /' -e 's/; /\n  - /g'
  fi
done

if [[ "$KEEP_DBS" != "1" ]]; then
  for db in "${CREATED_DBS[@]+"${CREATED_DBS[@]}"}"; do
    psql -X -q -d postgres -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" >/dev/null 2>&1 || true
  done
else
  echo "KEEP_DBS=1: kept ${CREATED_DBS[*]+"${CREATED_DBS[*]}"}"
fi

if [[ $ANY_FAIL -ne 0 || $nskip -ne 0 ]]; then exit 1; fi
exit 0
