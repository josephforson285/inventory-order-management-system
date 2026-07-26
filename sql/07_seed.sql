-- =============================================================================
--  Inventory and Order Management System
--  07_seed.sql — operational data at realistic volume
-- =============================================================================
--
--  Phase 5 asks that queries stay efficient "as the number of customers, orders,
--  and products grows". An index strategy demonstrated on forty rows
--  demonstrates nothing, so this generates enough data for EXPLAIN ANALYZE to
--  mean something.
--
--  REPRODUCIBLE. Every value is derived from the row number, either
--  arithmetically or through RAND(<seed> + n), so two runs of this file produce
--  byte-identical data. Nothing depends on the wall clock except order_date,
--  which is offset backwards from NOW().
--
--  RESPECTS ITS OWN RULES. Stock is not inserted; products are created empty and
--  opening stock arrives as INITIAL_LOAD ledger movements (rule I-15), sales
--  move stock through the ledger, and every trigger stays enabled throughout.
--  The load is therefore slower than a raw bulk insert would be — that is the
--  point. The reconciliation at the foot of this file proves the result is
--  consistent rather than merely present.
--
--  OPENING STOCK IS DERIVED FROM DEMAND. Each product is loaded with exactly
--  (total units it will ever sell + its target_stock_level), so after every
--  order has been placed each product sits precisely at target — a healthy
--  inventory rather than an arbitrary one. A final set of stock-take
--  ADJUSTMENTs then drives a handful of products low, so the low-stock report
--  and the replenishment event have something real to act on.
--
--  Tunable below. The tally table tops out at 100,000 rows; raising @n_orders
--  beyond that needs a sixth digit table.
-- =============================================================================

SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,'
                       'NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

USE inventory_order_management_sys;

-- ----------------------------------------------------------------- tunables --
SET @n_products  = 500;
SET @n_customers = 10000;
SET @n_orders    = 100000;
SET @seed        = 20260726;
-- ---------------------------------------------------------------------------

SELECT CONCAT('Seeding ', @n_products, ' products, ', @n_customers,
              ' customers, ', @n_orders, ' orders...') AS status;

-- =============================================================================
--  Tally: 1..100000, built by cross-joining five digit tables. A recursive CTE
--  would be tidier but MySQL caps cte_max_recursion_depth at 1000 by default.
-- =============================================================================
DROP TEMPORARY TABLE IF EXISTS tally;
CREATE TEMPORARY TABLE tally (n INT UNSIGNED NOT NULL PRIMARY KEY) ENGINE = InnoDB;

INSERT INTO tally (n)
WITH d AS (
  SELECT 0 AS i UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
  UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
  UNION ALL SELECT 8 UNION ALL SELECT 9
)
SELECT 1 + d1.i + d2.i*10 + d3.i*100 + d4.i*1000 + d5.i*10000
  FROM d d1, d d2, d d3, d d4, d d5;


-- =============================================================================
--  Products — created with zero stock, as rule I-15 requires
-- =============================================================================
INSERT INTO products (category_id, sku, product_name, unit_price,
                      reorder_level, target_stock_level)
SELECT
    1 + MOD(n - 1, 8),
    CONCAT('SKU-', LPAD(n, 5, '0')),
    CONCAT(ELT(1 + MOD(n - 1, 8),
               'Notebook','Handset','Headset','Keyboard',
               'Monitor','Drive','Router','Charger'),
           ' ', ELT(1 + MOD(n, 6), 'Pro','Lite','Max','Air','Studio','Edge'),
           ' ', LPAD(n, 4, '0')),
    ROUND(5 + RAND(@seed + n) * 2495, 2),
    5  + MOD(n * 3, 46),                       -- reorder_level      5..50
    60 + MOD(n * 7, 46) + MOD(n * 3, 46)       -- target > reorder always
  FROM tally
 WHERE n <= @n_products;


-- =============================================================================
--  Customers — all start Bronze; the T-05 trigger re-files them as orders land
-- =============================================================================
INSERT INTO customers (first_name, last_name, email, phone, tier_id)
SELECT
    ELT(1 + MOD(n,      12), 'Ama','Kofi','Esi','Yaw','Akua','Kwame',
                             'Abena','Kojo','Adwoa','Kwesi','Afia','Yaa'),
    ELT(1 + MOD(n * 5,  10), 'Mensah','Boateng','Owusu','Asante','Appiah',
                             'Darko','Agyeman','Frimpong','Ansah','Nkrumah'),
    CONCAT('customer', n, '@example.com'),
    CONCAT('02', LPAD(MOD(n * 7919, 100000000), 8, '0')),
    1
  FROM tally
 WHERE n <= @n_customers;


-- =============================================================================
--  Order headers — spread across the past two years
-- =============================================================================
INSERT INTO orders (customer_id, order_date)
SELECT
    1 + MOD(n * 7919, @n_customers),
    NOW() - INTERVAL MOD(n * 13, 730) DAY
          - INTERVAL MOD(n * 37, 86400) SECOND
  FROM tally
 WHERE n <= @n_orders;


-- =============================================================================
--  Order lines, staged
--
--  1-4 lines per order. Products are chosen 137 apart in modular space so the
--  lines of one order can never collide on the same product, which would breach
--  uq_order_details_order_product.
--
--  Quantities are mostly small with a periodic bulk line, so all three discount
--  bands and the no-band (full price) case are all exercised by real data.
-- =============================================================================
DROP TEMPORARY TABLE IF EXISTS tmp_lines;
CREATE TEMPORARY TABLE tmp_lines (
  order_id   INT UNSIGNED NOT NULL,
  product_id INT UNSIGNED NOT NULL,
  quantity   INT UNSIGNED NOT NULL,
  PRIMARY KEY (order_id, product_id),
  KEY (product_id)
) ENGINE = InnoDB;

INSERT INTO tmp_lines (order_id, product_id, quantity)
SELECT
    o.order_id,
    1 + MOD(o.order_id * 7 + k.k * 137, @n_products),
    CASE WHEN MOD(o.order_id + k.k, 11) = 0 THEN 50 + MOD(o.order_id * k.k, 80)
         WHEN MOD(o.order_id + k.k,  5) = 0 THEN 10 + MOD(o.order_id * k.k, 35)
         ELSE                                    1 + MOD(o.order_id * k.k,  8)
    END
  FROM orders o
  CROSS JOIN (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) k
 WHERE k.k <= 1 + MOD(o.order_id, 4);


-- =============================================================================
--  Opening stock = everything the product will ever sell, plus its target.
--  After all sales it therefore rests at exactly target_stock_level.
--
--  Two statements, not one: an INSERT INTO inventory_logs ... SELECT FROM
--  products fails with MySQL error 1442, because the ledger trigger updates
--  products and a trigger may not modify a table the invoking statement is
--  reading. Staging the figures first sidesteps it. See ADR 0002.
-- =============================================================================
DROP TEMPORARY TABLE IF EXISTS tmp_opening;
CREATE TEMPORARY TABLE tmp_opening (
  product_id INT UNSIGNED NOT NULL PRIMARY KEY,
  qty        INT UNSIGNED NOT NULL
) ENGINE = InnoDB;

INSERT INTO tmp_opening (product_id, qty)
SELECT p.product_id,
       p.target_stock_level + COALESCE((SELECT SUM(l.quantity)
                                          FROM tmp_lines l
                                         WHERE l.product_id = p.product_id), 0)
  FROM products p;

INSERT INTO inventory_logs (product_id, movement_type, quantity_change)
SELECT product_id, 'INITIAL_LOAD', qty
  FROM tmp_opening
 ORDER BY product_id;


-- =============================================================================
--  Order details — prices snapshotted, discount bands resolved from quantity
--
--  Reading `products` here is fine: order_details' trigger updates `orders`,
--  not `products`, so the 1442 restriction does not apply.
-- =============================================================================
INSERT INTO order_details (order_id, product_id, quantity, unit_price,
                           discount_percent_applied, discount_rule_id)
SELECT
    l.order_id,
    l.product_id,
    l.quantity,
    p.unit_price,
    COALESCE(dr.discount_percent, 0.00),
    dr.discount_rule_id
  FROM tmp_lines l
  JOIN products p
    ON p.product_id = l.product_id
  LEFT JOIN discount_rules dr
    ON dr.is_active     = TRUE
   AND l.quantity      >= dr.min_quantity
   AND (dr.max_quantity IS NULL OR l.quantity < dr.max_quantity);


-- =============================================================================
--  The sales themselves — stock moves only through the ledger
-- =============================================================================
INSERT INTO inventory_logs (product_id, movement_type, quantity_change, order_id)
SELECT product_id, 'SALE', -quantity, order_id
  FROM tmp_lines
 ORDER BY product_id, order_id;


-- =============================================================================
--  Stock-take adjustments — so the low-stock report has something to report
--
--  Every product currently sits at target. These bring a spread of products
--  down: some to exactly reorder_level (which must trigger, since rule I-13
--  fires at <= not <), some below it, and one to zero.
-- =============================================================================
DROP TEMPORARY TABLE IF EXISTS tmp_shrink;
CREATE TEMPORARY TABLE tmp_shrink (
  product_id INT UNSIGNED NOT NULL PRIMARY KEY,
  drop_by    INT UNSIGNED NOT NULL
) ENGINE = InnoDB;

INSERT INTO tmp_shrink (product_id, drop_by)
SELECT p.product_id,
       CASE MOD(p.product_id, 3)
         WHEN 0 THEN p.target_stock_level - p.reorder_level        -- exactly at the boundary
         WHEN 1 THEN p.target_stock_level - (p.reorder_level - 1)  -- just below it
         ELSE        p.target_stock_level                          -- stocked out
       END
  FROM products p
 WHERE MOD(p.product_id, 37) = 0
   AND p.reorder_level > 1;

INSERT INTO inventory_logs (product_id, movement_type, quantity_change, notes)
SELECT product_id, 'ADJUSTMENT', -drop_by, 'Stock-take correction'
  FROM tmp_shrink
 WHERE drop_by > 0
 ORDER BY product_id;

-- =============================================================================
--  Re-derive the tier thresholds from the data that now exists
--
--  Assumption A-13 recorded that the Bronze/Silver/Gold figures in
--  03_reference_data.sql were invented — the requirements supply none — and that
--  they should be replaced with real percentiles once seed data existed. It now
--  does, and the invented figures turn out to be badly wrong for this
--  population: against a median spend of roughly 430,000 a Gold threshold of
--  10,000 files 99% of customers as Gold, which segments nothing.
--
--  Bottom 60% Bronze, next 30% Silver, top 10% Gold.
--
--  This is the argument for holding business rules as DATA rather than as a
--  hardcoded CASE expression, demonstrated rather than asserted: correcting a
--  materially wrong tier scheme is three UPDATE statements, not a schema
--  migration and a redeployment.
--
--  Note what follows from it. Moving the bands invalidates every cached
--  customers.tier_id, so the caches must be recomputed — and if that step were
--  forgotten, rule T-06's check below would catch it rather than the error
--  sitting unnoticed in the reports. That is the whole point of pairing a cache
--  with a reconciliation.
--
--  03_reference_data.sql is deliberately left alone: its round numbers suit the
--  small scenarios in tests/, and this file overrides them for the seeded
--  population it actually measured.
-- =============================================================================
SET @p60 = (SELECT MAX(lifetime_spend) FROM (
              SELECT lifetime_spend, NTILE(10) OVER (ORDER BY lifetime_spend) AS b
                FROM vw_customer_spending) x WHERE b <= 6);
SET @p90 = (SELECT MAX(lifetime_spend) FROM (
              SELECT lifetime_spend, NTILE(10) OVER (ORDER BY lifetime_spend) AS b
                FROM vw_customer_spending) x WHERE b <= 9);

-- Rounded to the nearest thousand: a threshold of 583,863.86 implies a
-- precision the underlying estimate does not have.
SET @silver_floor = ROUND(@p60 / 1000) * 1000;
SET @gold_floor   = ROUND(@p90 / 1000) * 1000;

SELECT @silver_floor AS derived_silver_floor, @gold_floor AS derived_gold_floor;

-- Updated top-down. uq_customer_tiers_min_spend forbids two bands sharing a
-- floor, so raising Gold before Silver keeps every intermediate state legal.
UPDATE customer_tiers SET min_spend = @gold_floor,   max_spend = NULL          WHERE tier_name = 'Gold';
UPDATE customer_tiers SET min_spend = @silver_floor, max_spend = @gold_floor   WHERE tier_name = 'Silver';
UPDATE customer_tiers SET min_spend = 0,             max_spend = @silver_floor WHERE tier_name = 'Bronze';

-- Refresh every cached tier against the new bands. Staged through a temporary
-- table because MySQL will not update `customers` while reading a view that
-- itself reads `customers`.
DROP TEMPORARY TABLE IF EXISTS tmp_retier;
CREATE TEMPORARY TABLE tmp_retier (
  customer_id INT UNSIGNED NOT NULL PRIMARY KEY,
  tier_id     TINYINT UNSIGNED NOT NULL
) ENGINE = InnoDB;

INSERT INTO tmp_retier (customer_id, tier_id)
SELECT customer_id, computed_tier_id FROM vw_customer_spending;

UPDATE customers c
  JOIN tmp_retier r ON r.customer_id = c.customer_id
   SET c.tier_id = r.tier_id;

DROP TEMPORARY TABLE IF EXISTS tally;
DROP TEMPORARY TABLE IF EXISTS tmp_lines;
DROP TEMPORARY TABLE IF EXISTS tmp_opening;
DROP TEMPORARY TABLE IF EXISTS tmp_shrink;
DROP TEMPORARY TABLE IF EXISTS tmp_retier;


-- =============================================================================
--  Post-load verification — volume, then correctness
-- =============================================================================
SELECT 'products'       AS entity, COUNT(*) AS rows_loaded FROM products
UNION ALL SELECT 'customers',      COUNT(*) FROM customers
UNION ALL SELECT 'orders',         COUNT(*) FROM orders
UNION ALL SELECT 'order_details',  COUNT(*) FROM order_details
UNION ALL SELECT 'inventory_logs', COUNT(*) FROM inventory_logs;

SELECT 'Rule I-08: products whose stock disagrees with the ledger (must be 0)' AS check_name,
       COUNT(*) AS failures
  FROM (SELECT p.product_id
          FROM products p
          LEFT JOIN inventory_logs l ON l.product_id = p.product_id
         GROUP BY p.product_id, p.stock_quantity
        HAVING p.stock_quantity <> COALESCE(SUM(l.quantity_change), 0)) x;

SELECT 'Rule O-11: orders whose total disagrees with their details (must be 0)' AS check_name,
       COUNT(*) AS failures
  FROM (SELECT o.order_id
          FROM orders o
          LEFT JOIN order_details d ON d.order_id = o.order_id
         GROUP BY o.order_id, o.net_amount
        HAVING o.net_amount <> COALESCE(SUM(d.net_amount), 0)) x;

SELECT 'Rule T-06: customers whose cached tier is stale (must be 0)' AS check_name,
       COUNT(*) AS failures
  FROM vw_customer_spending WHERE tier_is_current = 0;

SELECT tier_name, COUNT(*) AS customers
  FROM vw_customer_spending v
  JOIN customer_tiers t ON t.tier_id = v.computed_tier_id
 GROUP BY t.tier_id, t.tier_name ORDER BY t.min_spend;

SELECT COUNT(*) AS products_needing_reorder FROM vw_low_stock;
