-- =============================================================================
--  tests/05_views_test.sql
--
--  PREREQUISITE: a freshly built schema with reference data.
--      mysql < sql/01_schema.sql
--      mysql < sql/02_triggers.sql
--      mysql < sql/03_reference_data.sql
--      mysql < sql/04_procedures.sql
--      mysql < sql/05_views.sql
--      mysql --force -t < tests/05_views_test.sql
--
--  No block here is expected to fail: a clean run produces 0 ERROR lines.
--  The assertions are about what the views RETURN, especially for customers
--  who should appear with a spend of zero rather than not appear at all.
-- =============================================================================

USE inventory_order_management_sys;

-- ---------- fixture ----------
INSERT INTO products (category_id, sku, product_name, unit_price, reorder_level, target_stock_level) VALUES
  (1,'SKU-LAP-001','Portable Workstation', 4500.00,  5,  50),
  (2,'SKU-PHN-001','Handset X',            1200.00, 10, 100),
  (3,'SKU-AUD-001','Studio Headphones',     250.00, 20, 200),
  (4,'SKU-PER-001','Mechanical Keyboard',   180.00, 15, 150);

INSERT INTO inventory_logs (product_id, movement_type, quantity_change) VALUES
  (1,'INITIAL_LOAD', 40),(2,'INITIAL_LOAD', 80),
  (3,'INITIAL_LOAD',150),(4,'INITIAL_LOAD',120);

-- Three customers covering the three cases the view must handle.
INSERT INTO customers (first_name,last_name,email,tier_id) VALUES
  ('Ama','Mensah','ama@example.com',1),    -- 1: has live orders
  ('Kofi','Boateng','kofi@example.com',1), -- 2: ONLY a cancelled order
  ('Esi','Owusu','esi@example.com',1);     -- 3: has never ordered

CALL sp_place_order(1, '[{"product_id":3,"quantity":65}]', @o1);
CALL sp_place_order(2, '[{"product_id":1,"quantity":12}]', @o2);
CALL sp_cancel_order(@o2);

-- =============================================================================
SELECT '=== vw_customer_spending: ALL THREE customers must appear ===' AS t;
SELECT 'Ama Gold/14625 | Kofi Bronze/0 with 1 cancelled | Esi Bronze/0 with 0 orders' AS t;
-- =============================================================================
SELECT customer_name, orders_placed, cancelled_orders, lifetime_spend,
       total_discount_received AS discount_recd, computed_tier_name, tier_is_current
  FROM vw_customer_spending ORDER BY customer_id;

SELECT '--- the trap this checks ---' AS t;
SELECT 'If status<>CANCELLED were in WHERE not ON, Kofi would vanish entirely.' AS note
 UNION ALL
SELECT 'If SUM were not COALESCEd, Esi would score NULL and match no tier band.';

SELECT '=== T-06: stored tier must equal computed tier for everyone ===' AS t;
SELECT COUNT(*) AS customers_with_stale_tier
  FROM vw_customer_spending WHERE tier_is_current = 0;

-- =============================================================================
SELECT '=== vw_order_summary ===' AS t;
SELECT 'Ama: 1 line / 65 items / net 14625. Kofi: CANCELLED, 1 line / 12 items' AS t;
-- =============================================================================
SELECT order_id, customer_name, status, line_count, item_count,
       gross_amount, discount_amount, net_amount
  FROM vw_order_summary ORDER BY order_id;

SELECT '=== line_count vs item_count on a multi-product order ===' AS t;
CALL sp_place_order(1, '[{"product_id":3,"quantity":30},{"product_id":4,"quantity":12}]', @o3);
SELECT 'expect line_count 2, item_count 42' AS t;
SELECT order_id, customer_name, line_count, item_count, net_amount
  FROM vw_order_summary WHERE order_id = @o3;

-- =============================================================================
SELECT '=== vw_low_stock: empty until something runs low ===' AS t;
-- =============================================================================
SELECT COUNT(*) AS low_stock_rows_initially FROM vw_low_stock;

SELECT '--- drain phones from 80 to 5 (reorder_level 10) ---' AS t;
CALL sp_place_order(1, '[{"product_id":2,"quantity":75}]', @o4);
SELECT sku, stock_quantity, reorder_level, units_to_order, is_out_of_stock, value_at_list_price
  FROM vw_low_stock ORDER BY sku;

SELECT '--- take the last 5: is_out_of_stock must flip to 1 ---' AS t;
CALL sp_place_order(1, '[{"product_id":2,"quantity":5}]', @o5);
SELECT sku, stock_quantity, units_to_order, is_out_of_stock FROM vw_low_stock ORDER BY sku;

SELECT '=== retired products are excluded ===' AS t;
-- Derive the adjustment from current stock rather than hardcoding it: keyboards
-- have already been sold on order 3, so a fixed figure would either overshoot
-- into negative stock or undershoot the reorder level.
--
-- The read MUST be a separate statement from the insert. Writing this as
-- INSERT INTO inventory_logs ... SELECT ... FROM products fails with MySQL
-- error 1442: the ledger trigger updates products, and a trigger may not modify
-- a table the invoking statement is already reading. See ADR 0002.
SELECT stock_quantity - 10 INTO @adj FROM products WHERE product_id = 4;

INSERT INTO inventory_logs (product_id, movement_type, quantity_change, notes)
  VALUES (4, 'ADJUSTMENT', -@adj, 'Damaged in transit');
SELECT 'keyboards now 10 vs reorder_level 15 -> expect 2 rows' AS t;
SELECT sku, stock_quantity, reorder_level FROM vw_low_stock ORDER BY sku;

UPDATE products SET is_active = FALSE WHERE product_id = 4;
SELECT 'keyboards retired -> expect 1 row, keyboards gone' AS t;
SELECT sku, stock_quantity, reorder_level FROM vw_low_stock ORDER BY sku;
UPDATE products SET is_active = TRUE WHERE product_id = 4;

SELECT '=== units_to_order must match what sp_replenish_stock does ===' AS t;
SELECT sku, units_to_order AS view_says FROM vw_low_stock ORDER BY sku;
CALL sp_replenish_stock(@n);
SELECT @n AS products_replenished, 'expect 2' AS note;
SELECT p.sku, p.stock_quantity, p.target_stock_level, l.quantity_change AS actually_ordered
  FROM products p
  JOIN inventory_logs l ON l.product_id = p.product_id AND l.movement_type='REPLENISHMENT'
 ORDER BY p.sku;
SELECT COUNT(*) AS low_stock_rows_after_replenish FROM vw_low_stock;

-- =============================================================================
SELECT '=== reconciliation still clean ===' AS t;
-- =============================================================================
SELECT p.sku, p.stock_quantity - COALESCE(SUM(l.quantity_change),0) AS stock_diff
  FROM products p LEFT JOIN inventory_logs l ON l.product_id=p.product_id
 GROUP BY p.product_id, p.sku, p.stock_quantity ORDER BY p.sku;

SELECT o.order_id, o.net_amount - COALESCE(SUM(d.net_amount),0) AS total_diff
  FROM orders o LEFT JOIN order_details d ON d.order_id=o.order_id
 GROUP BY o.order_id, o.net_amount ORDER BY o.order_id;

SELECT '=== END ===' AS t;
