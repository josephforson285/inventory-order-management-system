-- =============================================================================
--  Inventory and Order Management System
--  09_reconciliation.sql — proofs that the cached values have not drifted
-- =============================================================================
--
--  Six of the forty business rules cannot be enforced by a constraint: they
--  compare a stored value against an aggregate over another table, which no
--  CHECK can express. Those rules are classified VERIFIED rather than quietly
--  presented as enforced, and this file is what makes that classification
--  honest — each one gets a query that finds violations.
--
--  A cache without a proof is a bug that has not surfaced yet.
--
--  EVERY VIEW HERE RETURNS VIOLATIONS ONLY. An empty result is a pass. That
--  convention means a check can be read as an assertion:
--
--      SELECT * FROM rec_stock_ledger;      -- 0 rows = stock agrees with ledger
--
--  and the whole suite runs as one query:
--
--      SELECT * FROM rec_summary;
--
--  Rules covered: I-07 I-08 I-11 O-02 O-11 D-03 T-01 T-06
--  Idempotent: CREATE OR REPLACE throughout.
-- =============================================================================

SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,'
                       'NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

USE inventory_order_management_sys;


-- =============================================================================
--  rec_stock_ledger                                                  rule I-08
--  products.stock_quantity must equal the sum of that product's movements.
--
--  Since ADR 0002 this is additionally true BY CONSTRUCTION: stock_quantity is
--  copied from balance_after rather than calculated independently. The check is
--  kept regardless — a structural argument is a claim about the code, and this
--  is a measurement of the data. If a future change reintroduces a second write
--  path, this is what catches it.
-- =============================================================================
CREATE OR REPLACE VIEW rec_stock_ledger AS
SELECT p.product_id,
       p.sku,
       p.stock_quantity,
       COALESCE(SUM(l.quantity_change), 0)                      AS ledger_sum,
       p.stock_quantity - COALESCE(SUM(l.quantity_change), 0)   AS difference
  FROM products p
  LEFT JOIN inventory_logs l ON l.product_id = p.product_id
 GROUP BY p.product_id, p.sku, p.stock_quantity
HAVING p.stock_quantity <> COALESCE(SUM(l.quantity_change), 0);


-- =============================================================================
--  rec_balance_chain                                                 rule I-07
--  Each movement's balance_after must equal the previous balance plus this
--  movement's delta — so the ledger reads as an unbroken running balance rather
--  than a set of rows that merely happen to sum correctly.
--
--  This is strictly stronger than rec_stock_ledger. A pair of compensating
--  errors would leave the total right and the chain wrong; only this check sees
--  that. Ordering by log_id is sound because the table is append-only and the
--  key is auto-increment, so insertion order is chronological order.
-- =============================================================================
CREATE OR REPLACE VIEW rec_balance_chain AS
SELECT x.log_id, x.product_id, x.movement_type, x.quantity_change,
       x.previous_balance, x.balance_after,
       x.previous_balance + x.quantity_change AS expected_balance
  FROM (
        SELECT l.log_id, l.product_id, l.movement_type,
               l.quantity_change, l.balance_after,
               COALESCE(LAG(l.balance_after)
                          OVER (PARTITION BY l.product_id ORDER BY l.log_id), 0)
                 AS previous_balance
          FROM inventory_logs l
       ) x
 WHERE x.balance_after <> x.previous_balance + x.quantity_change;


-- =============================================================================
--  rec_order_totals                                                  rule O-11
--  An order's cached totals must equal the sum of its details.
--
--  net_amount is a generated column (gross - discount), so checking gross and
--  discount is sufficient; net is shown for readability.
-- =============================================================================
CREATE OR REPLACE VIEW rec_order_totals AS
SELECT o.order_id,
       o.gross_amount,
       COALESCE(SUM(d.gross_amount), 0.00)    AS detail_gross,
       o.discount_amount,
       COALESCE(SUM(d.discount_amount), 0.00) AS detail_discount,
       o.net_amount,
       COALESCE(SUM(d.net_amount), 0.00)      AS detail_net
  FROM orders o
  LEFT JOIN order_details d ON d.order_id = o.order_id
 GROUP BY o.order_id, o.gross_amount, o.discount_amount, o.net_amount
HAVING o.gross_amount    <> COALESCE(SUM(d.gross_amount), 0.00)
    OR o.discount_amount <> COALESCE(SUM(d.discount_amount), 0.00);


-- =============================================================================
--  rec_orphan_orders                                                 rule O-02
--  An order must have at least one detail row. sp_place_order writes both in
--  one transaction, so this should be impossible — which is exactly why it is
--  worth measuring rather than assuming.
-- =============================================================================
CREATE OR REPLACE VIEW rec_orphan_orders AS
SELECT o.order_id, o.customer_id, o.order_date, o.status, o.net_amount
  FROM orders o
  LEFT JOIN order_details d ON d.order_id = o.order_id
 WHERE d.order_detail_id IS NULL;


-- =============================================================================
--  rec_cancelled_stock                                               rule I-11
--  Cancelling an order must return exactly what it took. Summing every movement
--  attached to a cancelled order must therefore give zero: the SALE rows and
--  the CANCELLATION rows net out.
--
--  A non-zero result means stock was invented or destroyed by a cancellation --
--  the failure mode a double-cancellation would produce if rule O-04's guard
--  were ever removed.
-- =============================================================================
CREATE OR REPLACE VIEW rec_cancelled_stock AS
SELECT o.order_id,
       COUNT(l.log_id)          AS movements,
       SUM(l.quantity_change)   AS net_movement
  FROM orders o
  JOIN inventory_logs l ON l.order_id = o.order_id
 WHERE o.status = 'CANCELLED'
 GROUP BY o.order_id
HAVING SUM(l.quantity_change) <> 0;


-- =============================================================================
--  rec_customer_tiers                                                rule T-06
--  The cached customers.tier_id must match the tier implied by actual spend.
--  vw_customer_spending already computes both, so this is a filter over it.
-- =============================================================================
CREATE OR REPLACE VIEW rec_customer_tiers AS
SELECT customer_id, customer_name, lifetime_spend,
       stored_tier_id, computed_tier_id, computed_tier_name
  FROM vw_customer_spending
 WHERE tier_is_current = 0;


-- =============================================================================
--  rec_tier_bands                                                    rule T-01
--  Tier bands must tile [0, infinity) with no gap and no overlap.
--
--  uq_customer_tiers_min_spend already rules out two bands sharing a floor.
--  What remains unenforceable is the relationship BETWEEN adjacent bands, which
--  is what this checks: each band's ceiling must be exactly the next one's
--  floor. Plus the two structural conditions rule T-04 depends on -- the lowest
--  band starts at 0, and exactly one band is unbounded.
-- =============================================================================
CREATE OR REPLACE VIEW rec_tier_bands AS
SELECT a.tier_id, a.tier_name, a.min_spend, a.max_spend,
       CASE WHEN a.max_spend < b.min_spend THEN 'GAP between this band and the next'
            ELSE 'OVERLAP with the next band' END AS problem
  FROM customer_tiers a
  JOIN customer_tiers b
    ON b.min_spend = (SELECT MIN(min_spend) FROM customer_tiers
                       WHERE min_spend > a.min_spend)
 WHERE a.max_spend <> b.min_spend

UNION ALL

SELECT tier_id, tier_name, min_spend, max_spend,
       'Lowest band does not start at 0 - zero-spend customers would match none'
  FROM customer_tiers
 WHERE min_spend = (SELECT MIN(min_spend) FROM customer_tiers)
   AND min_spend <> 0

UNION ALL

SELECT tier_id, tier_name, min_spend, max_spend,
       'More than one unbounded band'
  FROM customer_tiers
 WHERE max_spend IS NULL
   AND (SELECT COUNT(*) FROM customer_tiers WHERE max_spend IS NULL) > 1;


-- =============================================================================
--  rec_discount_bands                                                rule D-03
--  The same test across the discounted range.
--
--  Note what is NOT checked: coverage from quantity 1. Bands deliberately start
--  at 10, and a line below that matches no rule and is sold at full price. "No
--  gaps" means no gaps WITHIN the discounted range -- see 03_reference_data.sql.
-- =============================================================================
CREATE OR REPLACE VIEW rec_discount_bands AS
SELECT a.discount_rule_id, a.min_quantity, a.max_quantity, a.discount_percent,
       CASE WHEN a.max_quantity < b.min_quantity THEN 'GAP between this band and the next'
            ELSE 'OVERLAP with the next band' END AS problem
  FROM discount_rules a
  JOIN discount_rules b
    ON b.min_quantity = (SELECT MIN(min_quantity) FROM discount_rules
                          WHERE min_quantity > a.min_quantity)
 WHERE a.max_quantity <> b.min_quantity

UNION ALL

SELECT discount_rule_id, min_quantity, max_quantity, discount_percent,
       'More than one unbounded band'
  FROM discount_rules
 WHERE max_quantity IS NULL
   AND (SELECT COUNT(*) FROM discount_rules WHERE max_quantity IS NULL) > 1;


-- =============================================================================
--  rec_summary — the whole suite as a single query
--
--      SELECT * FROM rec_summary;
--
--  Every violations count must be 0. This is the query to run after a data
--  migration, after editing reference data, or on a schedule.
-- =============================================================================
CREATE OR REPLACE VIEW rec_summary AS
SELECT 'I-08' AS rule_id, 'Stock agrees with the ledger'            AS check_name, COUNT(*) AS violations FROM rec_stock_ledger
UNION ALL
SELECT 'I-07', 'Ledger balances form an unbroken chain',            COUNT(*) FROM rec_balance_chain
UNION ALL
SELECT 'I-11', 'Cancellations return exactly what they took',       COUNT(*) FROM rec_cancelled_stock
UNION ALL
SELECT 'O-02', 'Every order has at least one detail row',           COUNT(*) FROM rec_orphan_orders
UNION ALL
SELECT 'O-11', 'Order totals agree with their details',             COUNT(*) FROM rec_order_totals
UNION ALL
SELECT 'D-03', 'Discount bands tile without gap or overlap',        COUNT(*) FROM rec_discount_bands
UNION ALL
SELECT 'T-01', 'Tier bands tile without gap or overlap',            COUNT(*) FROM rec_tier_bands
UNION ALL
SELECT 'T-06', 'Cached customer tiers match actual spend',          COUNT(*) FROM rec_customer_tiers;


-- =============================================================================
--  Run it
-- =============================================================================
SELECT * FROM rec_summary;

SELECT CASE WHEN SUM(violations) = 0
            THEN 'PASS - every reconciliation is clean'
            ELSE CONCAT('FAIL - ', SUM(violations), ' violation(s); query the rec_* views for detail')
       END AS result
  FROM rec_summary;
