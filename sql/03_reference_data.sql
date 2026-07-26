-- =============================================================================
--  Inventory and Order Management System
--  03_reference_data.sql — business rules held as data
-- =============================================================================
--
--  These three tables are the reason [ADR 0001] added tables beyond the five the
--  requirements name. Tier thresholds and discount breakpoints could have been a
--  hardcoded CASE expression inside a view; holding them as rows means finance
--  changes a threshold with an UPDATE rather than a schema migration and a
--  redeployment.
--
--  Contains reference data only. Products, customers, and orders are operational
--  data and belong to 07_seed.sql.
--
--  Idempotent: keyed on natural keys via ON DUPLICATE KEY UPDATE, so re-running
--  refreshes values without creating duplicates and without deleting rows that
--  customers or order details already reference.
-- =============================================================================

SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,'
                       'NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

USE inventory_order_management_sys;


-- =============================================================================
--  categories
-- =============================================================================
INSERT INTO categories (category_name, description) VALUES
  ('Laptops',      'Portable computers and notebooks'),
  ('Phones',       'Mobile handsets and accessories'),
  ('Audio',        'Headphones, speakers, and microphones'),
  ('Peripherals',  'Keyboards, mice, and input devices'),
  ('Displays',     'Monitors and projectors'),
  ('Storage',      'Drives, memory cards, and enclosures'),
  ('Networking',   'Routers, switches, and adapters'),
  ('Power',        'Chargers, batteries, and surge protection')
ON DUPLICATE KEY UPDATE description = VALUES(description);


-- =============================================================================
--  customer_tiers                                       rules T-01, T-04, A-13
--
--  Bands are half-open: [min_spend, max_spend). NULL max_spend = unbounded.
--
--  The lowest band MUST start at 0 (rule T-04) so that a customer who has never
--  ordered still resolves to a tier rather than to none.
--
--  IMPORTANT — these figures are invented. The requirements say only
--  "e.g. Bronze, Silver, Gold" and supply no thresholds. See assumption A-13:
--  once 07_seed.sql exists these should be re-derived from actual spend
--  percentiles, because a scheme where 98% of customers are Bronze segments
--  nothing. Revising them is an UPDATE here, not a migration.
-- =============================================================================
INSERT INTO customer_tiers (tier_name, min_spend, max_spend) VALUES
  ('Bronze',      0.00,   2000.00),
  ('Silver',   2000.00,  10000.00),
  ('Gold',    10000.00,      NULL)
ON DUPLICATE KEY UPDATE max_spend = VALUES(max_spend);


-- =============================================================================
--  discount_rules                                 rules D-01, D-02, D-03, D-04
--
--  Bands are half-open on quantity: [min_quantity, max_quantity).
--  Resolved PER ORDER DETAIL ROW from that row's own quantity (rule D-04) --
--  never from the order's total quantity across products.
--
--  Deliberately no band below 10. Quantities of 1-9 match no rule, and such a
--  line carries discount_rule_id = NULL meaning "sold at full price". This is
--  the optionality the conceptual model argued for: inventing a 0% band would
--  create a row that means "no discount", which is what NULL already says.
--
--  "No gaps" (rule D-03) therefore means no gaps WITHIN the discounted range,
--  from 10 upward. The reconciliation query checks that, not coverage from 1.
-- =============================================================================
INSERT INTO discount_rules (min_quantity, max_quantity, discount_percent) VALUES
  ( 10,   50,  5.00),
  ( 50,  100, 10.00),
  (100, NULL, 15.00)
ON DUPLICATE KEY UPDATE
  max_quantity     = VALUES(max_quantity),
  discount_percent = VALUES(discount_percent);


-- =============================================================================
--  Verification — bands must tile their range
--  Both queries must return zero rows. Systematic versions live in
--  09_reconciliation.sql; these are here so a bad edit to this file is caught
--  where it was made.
-- =============================================================================

-- Tier bands: each band's ceiling must be the next band's floor.
SELECT 'TIER BAND GAP/OVERLAP' AS problem, a.tier_name AS band, a.max_spend, b.tier_name AS next_band, b.min_spend
  FROM customer_tiers a
  JOIN customer_tiers b
    ON b.min_spend = (SELECT MIN(min_spend) FROM customer_tiers WHERE min_spend > a.min_spend)
 WHERE a.max_spend <> b.min_spend;

-- Discount bands: same test across the discounted range.
SELECT 'DISCOUNT BAND GAP/OVERLAP' AS problem, a.min_quantity AS band_from, a.max_quantity, b.min_quantity AS next_from
  FROM discount_rules a
  JOIN discount_rules b
    ON b.min_quantity = (SELECT MIN(min_quantity) FROM discount_rules WHERE min_quantity > a.min_quantity)
 WHERE a.max_quantity <> b.min_quantity;

SELECT tier_name, min_spend, max_spend FROM customer_tiers ORDER BY min_spend;
SELECT discount_rule_id, min_quantity, max_quantity, discount_percent FROM discount_rules ORDER BY min_quantity;
