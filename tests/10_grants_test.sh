#!/usr/bin/env bash
# =============================================================================
#  tests/10_grants_test.sh
#
#  The only test here that is not plain SQL, because proving a privilege model
#  requires connecting AS the restricted accounts. A script running as root
#  cannot demonstrate what a limited role is unable to do.
#
#  PREREQUISITE: the full stack, including sql/10_grants.sql.
#
#      bash tests/10_grants_test.sh
#
#  Creates two throwaway localhost accounts, exercises them, drops them again.
#  Their password is generated at runtime and never leaves this process, so
#  nothing secret is committed.
#
#  TWO DESIGN NOTES, both learned the hard way on the first run:
#
#  1. CONNECTIVITY IS CHECKED BEFORE ANYTHING ELSE. A "denied" result means
#     nothing unless the account can connect at all -- if user creation fails,
#     every statement is denied for the wrong reason and a negative-only suite
#     reports a clean pass over a completely broken setup. The precheck below
#     aborts instead.
#
#  2. EVERY ROLE HAS BOTH DENY AND ALLOW ASSERTIONS. A privilege model that
#     denies everything is not secure, it is broken. The allow() cases are what
#     distinguish the two, and they are what caught the failure in note 1.
#
#  Rules under test:
#    I-02  stock_quantity may change only through the ledger
#    I-03  inventory_logs is append-only
#    T-05  the cached customer tier is not application-writable
# =============================================================================
set -uo pipefail

DB=inventory_order_management_sys
PASS=0
FAIL=0

# Runtime-generated; satisfies validate_password without ever being stored.
PW="$(openssl rand -base64 18)Aa1!"

cleanup() {
  mysql -e "DROP USER IF EXISTS 'ims_test_app'@'localhost';
            DROP USER IF EXISTS 'ims_test_maint'@'localhost';" 2>/dev/null
}
trap cleanup EXIT

run_as() { mysql -u "$1" -p"$PW" -D "$DB" -e "$2" 2>&1; }

deny() {
  local user="$1" label="$2" sql="$3" out
  out=$(run_as "$user" "$sql")
  if [[ $? -ne 0 ]]; then
    echo "  PASS  denied:  $label"
    echo "                 $(echo "$out" | head -1 | cut -c1-108)"
    PASS=$((PASS+1))
  else
    echo "  FAIL  ALLOWED but should have been denied:  $label"
    FAIL=$((FAIL+1))
  fi
}

allow() {
  local user="$1" label="$2" sql="$3" out
  out=$(run_as "$user" "$sql")
  if [[ $? -eq 0 ]]; then
    echo "  PASS  allowed: $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL  DENIED but should have been allowed:  $label"
    echo "                 $(echo "$out" | head -1 | cut -c1-108)"
    FAIL=$((FAIL+1))
  fi
}

echo "=== creating throwaway accounts ==="
if ! mysql -e "
  DROP USER IF EXISTS 'ims_test_app'@'localhost';
  DROP USER IF EXISTS 'ims_test_maint'@'localhost';
  CREATE USER 'ims_test_app'@'localhost'   IDENTIFIED BY '${PW}';
  CREATE USER 'ims_test_maint'@'localhost' IDENTIFIED BY '${PW}';
  GRANT ims_app         TO 'ims_test_app'@'localhost';
  GRANT ims_maintenance TO 'ims_test_maint'@'localhost';
  SET DEFAULT ROLE ims_app         TO 'ims_test_app'@'localhost';
  SET DEFAULT ROLE ims_maintenance TO 'ims_test_maint'@'localhost';"; then
  echo "ABORT: could not create the test accounts."; exit 1
fi

# --- precheck: without this, every assertion below is meaningless -----------
echo "=== precheck: both accounts can connect and see the schema ==="
for u in ims_test_app ims_test_maint; do
  if ! run_as "$u" "SELECT 1;" >/dev/null; then
    echo "ABORT: $u cannot connect. Denials would be false positives."
    exit 1
  fi
  echo "  ok    $u connected"
done

echo
echo "=== ims_maintenance: rule I-02, stock is not directly writable ==="
deny  ims_test_maint "UPDATE products SET stock_quantity" \
      "UPDATE products SET stock_quantity = 1 WHERE product_id = 1;"
allow ims_test_maint "UPDATE products SET unit_price (a column it should own)" \
      "UPDATE products SET unit_price = unit_price WHERE product_id = 1;"

echo
echo "=== ims_maintenance: rule I-03, the ledger is append-only ==="
deny  ims_test_maint "UPDATE inventory_logs" \
      "UPDATE inventory_logs SET quantity_change = 1 WHERE log_id = 1;"
deny  ims_test_maint "DELETE FROM inventory_logs" \
      "DELETE FROM inventory_logs WHERE log_id = 1;"
allow ims_test_maint "INSERT INTO inventory_logs (the supported route for a stock-take)" \
      "INSERT INTO inventory_logs (product_id, movement_type, quantity_change, notes)
       VALUES (1, 'ADJUSTMENT', 1, 'grants test');"

echo
echo "=== ims_app: writes nothing directly, yet can still place an order ==="
deny  ims_test_app "INSERT INTO orders" \
      "INSERT INTO orders (customer_id) VALUES (1);"
deny  ims_test_app "INSERT INTO inventory_logs" \
      "INSERT INTO inventory_logs (product_id, movement_type, quantity_change)
       VALUES (1, 'ADJUSTMENT', 1);"
deny  ims_test_app "UPDATE products SET stock_quantity" \
      "UPDATE products SET stock_quantity = 1 WHERE product_id = 1;"
allow ims_test_app "CALL sp_place_order (permitted via the procedure's DEFINER rights)" \
      "CALL sp_place_order(1, '[{\"product_id\":1,\"quantity\":2}]', @o);"

echo
echo "=== ims_app: rule T-05, the cached tier is not application-writable ==="
deny  ims_test_app "UPDATE customers SET tier_id" \
      "UPDATE customers SET tier_id = 3 WHERE customer_id = 1;"
allow ims_test_app "UPDATE customers SET phone (a column it should own)" \
      "UPDATE customers SET phone = phone WHERE customer_id = 1;"

echo
echo "==================================="
echo "  passed: $PASS    failed: $FAIL"
echo "==================================="
[[ $FAIL -eq 0 ]] || exit 1
