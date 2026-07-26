-- =============================================================================
--  tests/02_triggers_test.sql
--  Asserts the trigger layer behaves as the business rules claim.
--
--  PREREQUISITE: a freshly built schema. The fixture inserts are not idempotent,
--  so re-running against a populated database produces duplicate-key errors and
--  asserts against leftover rows. Always rebuild first:
--
--      mysql < sql/01_schema.sql
--      mysql < sql/02_triggers.sql
--      mysql < sql/03_reference_data.sql
--      mysql --force -t < tests/02_triggers_test.sql
--
--  Tiers and categories come from 03_reference_data.sql rather than being
--  seeded here, so every test suite shares one prerequisite stack. Seeding them
--  locally as well would collide on tier_name and min_spend.
--
--  --force is required so that expected failures do not abort the script.
--
--  Every block labelled MUST FAIL is expected to raise; a silent pass there is
--  the real failure. On a clean run there should be exactly 9 ERROR lines.
-- =============================================================================

USE inventory_order_management_sys;

-- ---------- fixture ----------
-- Tiers, categories, and discount bands come from 03_reference_data.sql.
INSERT INTO customers (first_name,last_name,email,tier_id)
  VALUES ('Ama','Mensah','ama@example.com',1);

SELECT '=== I-15: product must be created with zero stock ===' AS t;
INSERT INTO products (category_id,sku,product_name,unit_price,reorder_level,target_stock_level)
  VALUES (1,'SKU-001','Widget',25.00,20,600);
SELECT sku, stock_quantity FROM products;

SELECT '--- MUST FAIL: creating a product with opening stock ---' AS t;
INSERT INTO products (category_id,sku,product_name,unit_price,stock_quantity,reorder_level,target_stock_level)
  VALUES (1,'SKU-BAD','Preloaded',5.00,500,10,100);

SELECT '=== I-02/I-07: stock arrives only via the ledger ===' AS t;
INSERT INTO inventory_logs (product_id,movement_type,quantity_change)
  VALUES (1,'INITIAL_LOAD',500);
SELECT p.stock_quantity AS stock_now, l.quantity_change, l.balance_after
  FROM products p JOIN inventory_logs l ON l.product_id = p.product_id;

SELECT '--- MUST FAIL: direct write to stock_quantity ---' AS t;
UPDATE products SET stock_quantity = 999 WHERE product_id = 1;

SELECT '--- guard must NOT block other columns ---' AS t;
UPDATE products SET unit_price = 26.00 WHERE product_id = 1;
SELECT sku, unit_price, stock_quantity FROM products;

SELECT '=== O-10/T-05: totals and tier follow the details ===' AS t;
INSERT INTO orders (customer_id) VALUES (1);
INSERT INTO order_details (order_id,product_id,quantity,unit_price,discount_percent_applied,discount_rule_id)
  VALUES (1,1,12,26.00,5.00,1);
SELECT o.order_id, o.gross_amount, o.discount_amount, o.net_amount,
       c.tier_id, ct.tier_name
  FROM orders o JOIN customers c ON c.customer_id=o.customer_id
                JOIN customer_tiers ct ON ct.tier_id=c.tier_id;

SELECT '=== the sale moves stock through the ledger ===' AS t;
INSERT INTO inventory_logs (product_id,movement_type,quantity_change,order_id)
  VALUES (1,'SALE',-12,1);
SELECT stock_quantity FROM products;

SELECT '=== I-08: cache agrees with ledger (expect equal, diff 0) ===' AS t;
SELECT p.stock_quantity,
       SUM(l.quantity_change) AS ledger_sum,
       p.stock_quantity - SUM(l.quantity_change) AS diff
  FROM products p JOIN inventory_logs l ON l.product_id=p.product_id
 GROUP BY p.product_id, p.stock_quantity;

SELECT '=== T-05: tier promotion on a large order (expect Silver) ===' AS t;
INSERT INTO orders (customer_id) VALUES (1);
-- quantity 100 falls in the third band [100, unbounded) at 15%
INSERT INTO order_details (order_id,product_id,quantity,unit_price,discount_percent_applied,discount_rule_id)
  VALUES (2,1,100,30.00,15.00,3);
SELECT c.customer_id, ct.tier_name,
       (SELECT SUM(net_amount) FROM orders WHERE customer_id=1 AND status<>'CANCELLED') AS spend
  FROM customers c JOIN customer_tiers ct ON ct.tier_id=c.tier_id;

SELECT '=== T-03/T-05: cancelling demotes (expect Bronze) ===' AS t;
UPDATE orders SET status='CANCELLED', cancelled_at=NOW() WHERE order_id=2;
SELECT c.customer_id, ct.tier_name,
       (SELECT SUM(net_amount) FROM orders WHERE customer_id=1 AND status<>'CANCELLED') AS spend
  FROM customers c JOIN customer_tiers ct ON ct.tier_id=c.tier_id;

SELECT '=== IMMUTABILITY: all four MUST FAIL ===' AS t;
SELECT '--- I-03: update a log row ---' AS t;
UPDATE inventory_logs SET quantity_change = -1 WHERE log_id = 1;
SELECT '--- I-03: delete a log row ---' AS t;
DELETE FROM inventory_logs WHERE log_id = 1;
SELECT '--- O-05: update an order detail ---' AS t;
UPDATE order_details SET quantity = 5 WHERE order_detail_id = 1;
SELECT '--- O-05: delete an order detail ---' AS t;
DELETE FROM order_details WHERE order_detail_id = 1;

SELECT '=== O-13: MUST FAIL - future-dated order ===' AS t;
INSERT INTO orders (customer_id, order_date) VALUES (1, NOW() + INTERVAL 1 DAY);

SELECT '=== I-01: MUST FAIL - movement driving stock below zero ===' AS t;
INSERT INTO inventory_logs (product_id,movement_type,quantity_change,order_id)
  VALUES (1,'SALE',-99999,1);

SELECT '=== latch is single-use: MUST FAIL after a successful ledger write ===' AS t;
INSERT INTO inventory_logs (product_id,movement_type,quantity_change)
  VALUES (1,'REPLENISHMENT',10);
UPDATE products SET stock_quantity = 1 WHERE product_id = 1;

SELECT '=== final state ===' AS t;
SELECT p.stock_quantity,
       SUM(l.quantity_change) AS ledger_sum,
       p.stock_quantity - SUM(l.quantity_change) AS diff
  FROM products p JOIN inventory_logs l ON l.product_id=p.product_id
 GROUP BY p.product_id, p.stock_quantity;
SELECT log_id, movement_type, quantity_change, balance_after, order_id FROM inventory_logs ORDER BY log_id;

SELECT '=== END ===' AS t;
