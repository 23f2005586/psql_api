#!/usr/bin/env bash
# Integration tests for the SQL Runner API.
# Usage: ./scripts/test-api.sh [base_url]
# Requires API_KEY in the environment or in api/.env

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_URL="${1:-http://127.0.0.1:3000}"

if [ -z "${API_KEY:-}" ] && [ -f "$ROOT/api/.env" ]; then
  # shellcheck disable=SC1091
  set -a
  # Only load API_KEY from api/.env if needed
  API_KEY="$(grep -E '^API_KEY=' "$ROOT/api/.env" | head -1 | cut -d= -f2-)"
  set +a
fi

if [ -z "${API_KEY:-}" ]; then
  echo "API_KEY is not set. Export it or put it in api/.env"
  exit 1
fi

pass=0
fail=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }

assert_http() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" = "$expected" ]; then
    green "PASS: $name (HTTP $actual)"
    pass=$((pass + 1))
  else
    red "FAIL: $name (expected HTTP $expected, got $actual)"
    fail=$((fail + 1))
  fi
}

assert_json_field() {
  local name="$1"
  local body="$2"
  local python_expr="$3"
  if python3 -c "import json,sys; d=json.load(sys.stdin); assert ($python_expr)" <<<"$body" 2>/dev/null; then
    green "PASS: $name"
    pass=$((pass + 1))
  else
    red "FAIL: $name"
    echo "  body: $body"
    fail=$((fail + 1))
  fi
}

run_sql() {
  local query="$1"
  local key="${2:-$API_KEY}"
  curl -sS -o /tmp/sql-runner-body.json -w "%{http_code}" \
    -X POST "$BASE_URL/api/run-sql" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$query")"
}

echo "=== Health ==="
code="$(curl -sS -o /tmp/sql-runner-body.json -w "%{http_code}" "$BASE_URL/health")"
body="$(cat /tmp/sql-runner-body.json)"
assert_http "GET /health" "200" "$code"
assert_json_field "health ok" "$body" "d.get('ok') is True"

echo "=== 1. SELECT ==="
code="$(run_sql 'SELECT * FROM employees ORDER BY id')"
body="$(cat /tmp/sql-runner-body.json)"
assert_http "SELECT employees" "200" "$code"
assert_json_field "SELECT success" "$body" "d.get('success') is True and d.get('rowCount',0) > 0"

echo "=== 2. INSERT + ROLLBACK check ==="
code="$(run_sql "INSERT INTO employees (name, department, salary) VALUES ('TempUser', 'IT', 1) RETURNING id, name")"
body="$(cat /tmp/sql-runner-body.json)"
assert_http "INSERT" "200" "$code"
assert_json_field "INSERT returns row" "$body" "d.get('success') is True and d.get('rowCount') == 1"

code="$(run_sql "SELECT COUNT(*)::int AS c FROM employees WHERE name = 'TempUser'")"
body="$(cat /tmp/sql-runner-body.json)"
assert_json_field "INSERT was rolled back" "$body" "d.get('success') is True and d['rows'][0][0] == 0"

echo "=== 3. UPDATE + ROLLBACK check ==="
code="$(run_sql "UPDATE employees SET salary = 1 WHERE name = 'John' RETURNING name, salary")"
body="$(cat /tmp/sql-runner-body.json)"
assert_http "UPDATE" "200" "$code"

code="$(run_sql "SELECT salary FROM employees WHERE name = 'John'")"
body="$(cat /tmp/sql-runner-body.json)"
assert_json_field "UPDATE was rolled back" "$body" "d.get('success') is True and d['rows'][0][0] != 1"

echo "=== 4. DELETE + ROLLBACK check ==="
code="$(run_sql "DELETE FROM employees WHERE name = 'John' RETURNING name")"
body="$(cat /tmp/sql-runner-body.json)"
assert_http "DELETE" "200" "$code"

code="$(run_sql "SELECT COUNT(*)::int AS c FROM employees WHERE name = 'John'")"
body="$(cat /tmp/sql-runner-body.json)"
assert_json_field "DELETE was rolled back" "$body" "d.get('success') is True and d['rows'][0][0] == 1"

echo "=== 5. GROUP BY ==="
code="$(run_sql 'SELECT department, AVG(salary) FROM employees GROUP BY department ORDER BY department')"
body="$(cat /tmp/sql-runner-body.json)"
assert_http "GROUP BY" "200" "$code"
assert_json_field "GROUP BY success" "$body" "d.get('success') is True and d.get('rowCount',0) >= 1"

echo "=== 6. JOIN ==="
code="$(run_sql 'SELECT e.name, d.name AS dept FROM employees e JOIN departments d ON e.department = d.name ORDER BY e.id LIMIT 5')"
body="$(cat /tmp/sql-runner-body.json)"
assert_http "JOIN" "200" "$code"
assert_json_field "JOIN success" "$body" "d.get('success') is True and d.get('rowCount',0) >= 1"

echo "=== 7. Invalid SQL ==="
code="$(run_sql 'SELEC broken FROM nowhere')"
body="$(cat /tmp/sql-runner-body.json)"
assert_http "invalid SQL" "400" "$code"
assert_json_field "invalid SQL error message" "$body" "d.get('success') is False and isinstance(d.get('error'), str) and len(d['error']) > 0"

echo "=== 8. Statement timeout (>3s) ==="
code="$(run_sql "SELECT pg_sleep(5)")"
body="$(cat /tmp/sql-runner-body.json)"
assert_http "timeout" "408" "$code"
assert_json_field "timeout error" "$body" "d.get('success') is False"

echo "=== 9. More than 1000 rows (truncated in Node) ==="
code="$(run_sql 'SELECT g FROM generate_series(1, 1500) AS g')"
body="$(cat /tmp/sql-runner-body.json)"
assert_http "large result" "200" "$code"
assert_json_field "row cap 1000" "$body" "d.get('success') is True and d.get('rowCount') == 1000 and d.get('truncated') is True"

echo "=== 10. Unauthorized ==="
code="$(run_sql 'SELECT 1' 'wrong-key')"
body="$(cat /tmp/sql-runner-body.json)"
assert_http "unauthorized" "401" "$code"
assert_json_field "unauthorized body" "$body" "d.get('success') is False"

echo
echo "Results: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
