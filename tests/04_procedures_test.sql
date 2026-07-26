-- =============================================================================
--  tests/04_procedures_test.sql
--
--  PREREQUISITE: a freshly built schema with reference data.
--      mysql < sql/01_schema.sql
--      mysql < sql/02_triggers.sql
--      mysql < sql/03_reference_data.sql
--      mysql < sql/04_procedures.sql
--      mysql --force -t < tests/04_procedures_test.sql
--
--  --force is required: blocks labelled MUST FAIL are expected to raise, and a
--  silent pass there is the real failure. On a clean run: exactly 6 ERROR lines.
-- =============================================================================

USE inventory_order_management_sys;

-- ---------- fixture: products created empty, stock loaded via the ledger ----
INSERT INTO products (category_id, sku, product_name, unit_price, reorder_level, target_stock_level) VALUES
  (1,'SKU-LAP-001','Portable Workstation', 4500.00,  5,  50),
  (2,'SKU-PHN-001','Handset X',            1200.00, 10, 100),
  (3,'SKU-AUD-001','Studio Headphones',     250.00, 20, 200),
  (4,'SKU-PER-001','Mechanical Keyboard',   180.00, 15, 150);

INSERT INTO inventory_logs (product_id, movement_type, quantity_change) VALUES
  (1,'INITIAL_LOAD', 40),
  (2,'INITIAL_LOAD', 80),
  (3,'INITIAL_LOAD',150),
  (4,'INITIAL_LOAD',120);

INSERT INTO customers (first_name,last_name,email,tier_id)
  VALUES ('Ama','Mensah','ama@example.com',1);

SELECT '=== opening stock (expect 40 / 80 / 150 / 120) ===' AS t;
SELECT sku, stock_quantity, reorder_level, target_stock_level, needs_reorder FROM products ORDER BY product_id;

-- =============================================================================
SELECT '=== ORDER A: duplicate product merged, two discount bands ===' AS t;
SELECT 'lines: P3 x60, P4 x5, P3 x5  -> P3 should merge to 65' AS t;
-- =============================================================================
CALL sp_place_order(1, '[{"product_id":3,"quantity":60},
                         {"product_id":4,"quantity":5},
                         {"product_id":3,"quantity":5}]', @order_a);
SELECT @order_a AS order_a_id;

SELECT 'detail rows: expect 2 (merged), P3 at 10% band, P4 at full price' AS t;
SELECT p.sku, d.quantity, d.unit_price, d.discount_percent_applied AS pct,
       d.discount_rule_id AS rule, d.gross_amount, d.discount_amount, d.net_amount
  FROM order_details d JOIN products p ON p.product_id=d.product_id
 WHERE d.order_id=@order_a ORDER BY p.sku;

-- 16250.00 (P3) + 900.00 (P4) = 17150.00 gross; less 1625.00 = 15525.00 net
SELECT 'order totals: expect gross 17150.00, discount 1625.00, net 15525.00' AS t;
SELECT gross_amount, discount_amount, net_amount, status FROM orders WHERE order_id=@order_a;

SELECT 'stock after: P3 85, P4 115' AS t;
SELECT sku, stock_quantity FROM products WHERE product_id IN (3,4) ORDER BY product_id;

SELECT 'tier: net 15525 -> Gold (>= 10000)' AS t;
SELECT ct.tier_name FROM customers c JOIN customer_tiers ct ON ct.tier_id=c.tier_id WHERE c.customer_id=1;

-- =============================================================================
SELECT '=== I-12: MUST FAIL - one bad line rejects the whole order ===' AS t;
-- =============================================================================
SELECT (SELECT COUNT(*) FROM orders) AS orders_before, (SELECT stock_quantity FROM products WHERE product_id=1) AS p1_before;
CALL sp_place_order(1, '[{"product_id":1,"quantity":10},{"product_id":2,"quantity":999}]', @bad);
SELECT (SELECT COUNT(*) FROM orders) AS orders_after, (SELECT stock_quantity FROM products WHERE product_id=1) AS p1_after,
       'both must be unchanged - P1 must NOT have been deducted' AS note;

SELECT '=== MUST FAIL: unknown product ===' AS t;
CALL sp_place_order(1, '[{"product_id":9999,"quantity":1}]', @bad);

SELECT '=== MUST FAIL: empty order (rule O-02) ===' AS t;
CALL sp_place_order(1, '[]', @bad);

SELECT '=== MUST FAIL: unknown customer (rule O-01) ===' AS t;
CALL sp_place_order(9999, '[{"product_id":1,"quantity":1}]', @bad);

-- =============================================================================
SELECT '=== ORDER B: 5% band ===' AS t;
-- =============================================================================
CALL sp_place_order(1, '[{"product_id":1,"quantity":12}]', @order_b);
SELECT 'expect pct 5.00, gross 54000.00, discount 2700.00, net 51300.00' AS t;
SELECT d.quantity, d.discount_percent_applied AS pct, d.gross_amount, d.discount_amount, d.net_amount
  FROM order_details d WHERE d.order_id=@order_b;
SELECT sku, stock_quantity FROM products WHERE product_id=1;

SELECT '=== MUST FAIL: retired product cannot be ordered ===' AS t;
UPDATE products SET is_active = FALSE WHERE product_id = 4;
CALL sp_place_order(1, '[{"product_id":4,"quantity":1}]', @bad);
UPDATE products SET is_active = TRUE WHERE product_id = 4;

-- =============================================================================
SELECT '=== I-11: cancellation returns stock ===' AS t;
-- =============================================================================
CALL sp_cancel_order(@order_a);
SELECT 'stock restored: P3 150, P4 120' AS t;
SELECT sku, stock_quantity FROM products WHERE product_id IN (3,4) ORDER BY product_id;
SELECT movement_type, quantity_change, balance_after FROM inventory_logs
 WHERE order_id=@order_a ORDER BY log_id;

SELECT '=== O-04: MUST FAIL - cancelling twice ===' AS t;
CALL sp_cancel_order(@order_a);

SELECT '=== T-03/T-05: cancel order B too -> spend 0 -> Bronze ===' AS t;
CALL sp_cancel_order(@order_b);
SELECT ct.tier_name,
       (SELECT COALESCE(SUM(net_amount),0) FROM orders WHERE customer_id=1 AND status<>'CANCELLED') AS live_spend
  FROM customers c JOIN customer_tiers ct ON ct.tier_id=c.tier_id WHERE c.customer_id=1;

-- =============================================================================
SELECT '=== I-13: replenishment ===' AS t;
-- =============================================================================
SELECT 'drain P2 to 5 (reorder_level 10) with an order of 75' AS t;
CALL sp_place_order(1, '[{"product_id":2,"quantity":75}]', @order_c);
SELECT sku, stock_quantity, reorder_level, needs_reorder FROM products WHERE product_id=2;

CALL sp_replenish_stock(@n);
SELECT @n AS products_replenished, 'expect 1' AS note;
SELECT 'P2 topped up to target 100' AS t;
SELECT sku, stock_quantity, needs_reorder FROM products WHERE product_id=2;
SELECT movement_type, quantity_change, balance_after, notes FROM inventory_logs
 WHERE product_id=2 ORDER BY log_id;

SELECT '=== self-limiting: second run finds nothing (expect 0) ===' AS t;
CALL sp_replenish_stock(@n2);
SELECT @n2 AS products_replenished_again;

-- =============================================================================
SELECT '=== I-08: full reconciliation - every diff must be 0 ===' AS t;
-- =============================================================================
SELECT p.sku, p.stock_quantity, COALESCE(SUM(l.quantity_change),0) AS ledger_sum,
       p.stock_quantity - COALESCE(SUM(l.quantity_change),0) AS diff
  FROM products p LEFT JOIN inventory_logs l ON l.product_id=p.product_id
 GROUP BY p.product_id, p.sku, p.stock_quantity ORDER BY p.sku;

SELECT '=== O-11: order totals vs their details - every diff must be 0 ===' AS t;
SELECT o.order_id, o.net_amount, COALESCE(SUM(d.net_amount),0) AS detail_sum,
       o.net_amount - COALESCE(SUM(d.net_amount),0) AS diff
  FROM orders o LEFT JOIN order_details d ON d.order_id=o.order_id
 GROUP BY o.order_id, o.net_amount ORDER BY o.order_id;

SELECT '=== END ===' AS t;
