-- =============================================================================
--  Inventory and Order Management System
--  08_reports.sql — the reporting layer
-- =============================================================================
--
--  The conceptual model claimed the design could answer six business questions.
--  This file is where that claim is settled — one report per question, plus
--  three that fell out of the data being there.
--
--    Q1  What did each customer order, when, and for how much?        -> R1, R2
--    Q2  Which products have fallen to or below their reorder level?  -> R3
--    Q3  What is each customer's lifetime spend and tier?             -> R2, R4
--    Q4  For any product, the full stock history and why each moved?  -> R8
--    Q5  How much revenue was given away as discount, under which rule? -> R5
--    Q6  Which products sell fastest relative to the stock held?      -> R9
--
--  Everything reads. Nothing here writes, so it is safe to run at any time and
--  appropriate for the ims_readonly role.
--
--  Where a report could return thousands of rows it is capped, and the cap is
--  stated in the header rather than left for the reader to infer.
-- =============================================================================

SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,'
                       'NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

USE inventory_order_management_sys;

-- Which product R8 audits. Change to inspect a different one.
SET @audit_product_id = 1;

-- The span the data actually covers, measured rather than assumed. R9 needs it
-- to turn lifetime units into a daily rate, and hardcoding 730 would silently
-- lie the moment the seed volume or date range changed.
SET @span_days = (SELECT GREATEST(DATEDIFF(MAX(order_date), MIN(order_date)), 1)
                    FROM orders WHERE status <> 'CANCELLED');

SELECT CONCAT('Reporting over ', @span_days, ' days of order history') AS scope;


-- =============================================================================
--  R1  Order summaries — 20 most recent                            Phase 3, Q1
--
--  "Display summaries of orders — including order date, total amount, and
--   number of items — per customer"
--
--  line_count and item_count are both shown because the requirement's "number of
--  items" is ambiguous: an order of 60 headphones and 5 keyboards is 2 by one
--  reading and 65 by the other.
-- =============================================================================
SELECT '=== R1  Recent orders (20) ===' AS report;

SELECT order_id, order_date, customer_name, status,
       line_count, item_count, gross_amount, discount_amount, net_amount
  FROM vw_order_summary
 ORDER BY order_date DESC
 LIMIT 20;


-- =============================================================================
--  R2  Top customers by lifetime spend — 20                    Phase 3, Q1/Q3
--
--  Cancelled orders are excluded, because vw_customer_spending excludes them
--  (rule T-03) — a customer cannot buy their way into Gold and then cancel.
-- =============================================================================
SELECT '=== R2  Top customers by lifetime spend (20) ===' AS report;

SELECT customer_name, email, computed_tier_name AS tier,
       orders_placed, cancelled_orders,
       lifetime_spend,
       total_discount_received AS discount_received,
       ROUND(lifetime_spend / NULLIF(orders_placed, 0), 2) AS avg_order_value
  FROM vw_customer_spending
 ORDER BY lifetime_spend DESC
 LIMIT 20;


-- =============================================================================
--  R3  Low stock, needing replenishment                            Phase 3, Q2
--
--  "any product with stock below its reorder point should be flagged"
--
--  Ordered by urgency: stockouts first, then whatever is closest to running out.
--  units_to_order is exactly what sp_replenish_stock would order, so this report
--  doubles as a preview of the automated action.
-- =============================================================================
SELECT '=== R3  Products at or below reorder level ===' AS report;

SELECT sku, product_name, category_name,
       stock_quantity, reorder_level, target_stock_level,
       units_to_order, is_out_of_stock, value_at_list_price
  FROM vw_low_stock
 ORDER BY is_out_of_stock DESC, stock_quantity ASC, sku;


-- =============================================================================
--  R4  Tier distribution and revenue concentration               Phase 3, Q3
--
--  The business question behind tiers is not "how many Gold customers" but
--  "how much of the revenue do they represent". A tier scheme is working when
--  the top band is small and its revenue share is large.
--
--  CAVEAT ON THE SEEDED DATA. Against the generated dataset this reports Gold at
--  10% of customers and 21.7% of revenue — some concentration, but far less than
--  real retail, where the top decile commonly carries half or more. The reason is
--  that 07_seed.sql distributes orders across customers close to evenly, so the
--  population has no long tail. The report is correct; the data is flatter than
--  reality. Worth knowing before drawing a business conclusion from this row.
-- =============================================================================
SELECT '=== R4  Tier distribution and revenue share ===' AS report;

SELECT v.computed_tier_name                              AS tier,
       t.min_spend, t.max_spend,
       COUNT(*)                                          AS customers,
       ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM vw_customer_spending), 1) AS pct_of_customers,
       ROUND(SUM(v.lifetime_spend), 2)                   AS tier_revenue,
       ROUND(100 * SUM(v.lifetime_spend)
             / (SELECT SUM(lifetime_spend) FROM vw_customer_spending), 1)     AS pct_of_revenue,
       ROUND(AVG(v.lifetime_spend), 2)                   AS avg_spend
  FROM vw_customer_spending v
  JOIN customer_tiers t ON t.tier_id = v.computed_tier_id
 GROUP BY v.computed_tier_id, v.computed_tier_name, t.min_spend, t.max_spend
 ORDER BY t.min_spend;


-- =============================================================================
--  R5  Bulk discount effectiveness by band                         Phase 3, Q5
--
--  "Apply bulk discounts based on quantity ordered"
--
--  Answers what the discount policy actually costs, per band. The NULL row is
--  the no-band case — lines below the lowest breakpoint, sold at full price.
--  effective_pct should match the band's nominal rate; a gap between them would
--  mean discounts were applied inconsistently.
-- =============================================================================
SELECT '=== R5  Discount given, by quantity band ===' AS report;

SELECT COALESCE(CONCAT(dr.min_quantity, '-',
                       COALESCE(CAST(dr.max_quantity AS CHAR), 'up')),
                'no band (full price)')                   AS quantity_band,
       COALESCE(dr.discount_percent, 0.00)                AS nominal_pct,
       COUNT(*)                                           AS detail_rows,
       SUM(od.quantity)                                   AS units,
       ROUND(SUM(od.gross_amount), 2)                     AS gross_value,
       ROUND(SUM(od.discount_amount), 2)                  AS discount_given,
       ROUND(100 * SUM(od.discount_amount)
             / NULLIF(SUM(od.gross_amount), 0), 2)        AS effective_pct
  FROM order_details od
  JOIN orders o          ON o.order_id = od.order_id
  LEFT JOIN discount_rules dr ON dr.discount_rule_id = od.discount_rule_id
 WHERE o.status <> 'CANCELLED'
 GROUP BY dr.discount_rule_id, dr.min_quantity, dr.max_quantity, dr.discount_percent
 ORDER BY COALESCE(dr.min_quantity, 0);


-- =============================================================================
--  R6  Monthly sales trend — last 12 months
--
--  Reads `orders` alone. It never touches order_details, because the order total
--  is already cached there (rule O-10) — so this aggregates 100,000 rows instead
--  of joining to 250,000. That saving is the entire justification for the cached
--  total, and rule O-11's reconciliation is what makes trusting it reasonable.
-- =============================================================================
SELECT '=== R6  Monthly sales trend (12 months) ===' AS report;

SELECT DATE_FORMAT(order_date, '%Y-%m')       AS month,
       COUNT(*)                               AS orders,
       ROUND(SUM(gross_amount), 2)            AS gross,
       ROUND(SUM(discount_amount), 2)         AS discount,
       ROUND(SUM(net_amount), 2)              AS net_revenue,
       ROUND(AVG(net_amount), 2)              AS avg_order_value
  FROM orders
 WHERE status <> 'CANCELLED'
 GROUP BY DATE_FORMAT(order_date, '%Y-%m')
 ORDER BY month DESC
 LIMIT 12;


-- =============================================================================
--  R7  Category performance
-- =============================================================================
SELECT '=== R7  Revenue by category ===' AS report;

SELECT c.category_name,
       COUNT(DISTINCT p.product_id)           AS products_sold,
       SUM(od.quantity)                       AS units,
       ROUND(SUM(od.net_amount), 2)           AS revenue,
       ROUND(SUM(od.discount_amount), 2)      AS discount_given
  FROM order_details od
  JOIN orders o     ON o.order_id   = od.order_id
  JOIN products p   ON p.product_id = od.product_id
  JOIN categories c ON c.category_id = p.category_id
 WHERE o.status <> 'CANCELLED'
 GROUP BY c.category_id, c.category_name
 ORDER BY revenue DESC;


-- =============================================================================
--  R8  Stock movement audit trail for one product              Phase 2, Q4
--
--  "Ensure a full history of inventory changes is retrievable for auditing"
--
--  Every movement, in order, with its reason and the balance it produced. The
--  running balance means an auditor can read the stock level at any past moment
--  straight off the row, without summing the preceding history.
--
--  balance_after here is what rec_balance_chain verifies is unbroken.
-- =============================================================================
SELECT CONCAT('=== R8  Movement history for product ', @audit_product_id,
              ' (first 25 movements) ===') AS report;

SELECT p.sku, p.product_name, p.stock_quantity AS current_stock
  FROM products p WHERE p.product_id = @audit_product_id;

SELECT l.log_id, l.created_at, l.movement_type,
       l.quantity_change, l.balance_after,
       l.order_id, l.notes
  FROM inventory_logs l
 WHERE l.product_id = @audit_product_id
 ORDER BY l.log_id
 LIMIT 25;

SELECT movement_type,
       COUNT(*)                AS movements,
       SUM(quantity_change)    AS net_units
  FROM inventory_logs
 WHERE product_id = @audit_product_id
 GROUP BY movement_type
 ORDER BY movement_type;


-- =============================================================================
--  R9  Stock cover — which products will run out soonest         Phase 3, Q6
--
--  Sales velocity against stock on hand, giving days of cover. This is the
--  question reorder_level approximates with a fixed number, and this report is
--  where the approximation is exposed.
--
--  WHAT THIS REPORT FOUND. Compare two rows from a real run:
--
--    sku         stock  reorder_level  units/day  days_cover  flagged_low
--    SKU-00046      60              5      36.29         1.7            0
--    SKU-00407       0             30       3.76         0.0            1
--
--  SKU-00046 has under two days of stock left and is NOT flagged, because its
--  reorder_level of 5 is roughly three hours of its own sales. SKU-00407 sells
--  a tenth as fast and is flagged with a far more comfortable buffer.
--
--  The requirements specify a fixed reorder level per product (Phase 1) and that
--  is what has been built. But a fixed threshold encodes an assumption about
--  velocity, and when velocity varies tenfold across the catalogue the threshold
--  is wrong for most of it. A velocity-derived reorder point -- cover_days
--  multiplied by the recent daily rate -- would flag both products at the same
--  real risk.
--
--  Recorded rather than fixed: changing it would depart from a stated
--  requirement. It is noted as a candidate in docs/10-future-architecture.md,
--  and this report is the evidence for it.
--
--  Rate is computed over @span_days, measured from the data.
-- =============================================================================
SELECT '=== R9  Lowest days of stock cover (15) ===' AS report;

SELECT p.sku, p.product_name,
       p.stock_quantity                                       AS stock,
       p.reorder_level,
       SUM(od.quantity)                                       AS units_sold,
       ROUND(SUM(od.quantity) / @span_days, 2)                AS units_per_day,
       ROUND(p.stock_quantity
             / NULLIF(SUM(od.quantity) / @span_days, 0), 1)   AS days_of_cover,
       p.needs_reorder                                        AS flagged_low
  FROM products p
  JOIN order_details od ON od.product_id = p.product_id
  JOIN orders o         ON o.order_id    = od.order_id
 WHERE o.status <> 'CANCELLED'
   AND p.is_active = TRUE
 GROUP BY p.product_id, p.sku, p.product_name,
          p.stock_quantity, p.reorder_level, p.needs_reorder
 ORDER BY days_of_cover ASC
 LIMIT 15;
