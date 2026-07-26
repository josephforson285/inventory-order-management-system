-- =============================================================================
--  Inventory and Order Management System
--  05_views.sql — reporting surface
-- =============================================================================
--
--  Three views, each answering a requirement directly:
--
--    vw_order_summary      Phase 3 and Phase 5 — order summaries per customer
--    vw_low_stock          Phase 3 and Phase 5 — products needing replenishment
--    vw_customer_spending  Phase 3 — spending reports, and the DEFINITION of
--                          lifetime spend that rules T-02 and T-03 refer to
--
--  vw_customer_spending is not merely a report. customers.tier_id is a cached
--  value; this view is the truth it is cached from. Rule T-06's reconciliation
--  compares the two, which is why the view exposes both the stored tier and the
--  computed one side by side.
--
--  Idempotent: CREATE OR REPLACE throughout.
-- =============================================================================

SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,'
                       'NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

USE inventory_order_management_sys;


-- =============================================================================
--  vw_order_summary
--  "Display summaries of orders — including order date, total amount, and
--   number of items — per customer" (Phase 3)
--
--  "Number of items" is ambiguous in the requirements: it could mean how many
--  distinct products the order contains, or how many units in total. An order of
--  60 headphones and 5 keyboards is 2 of the first and 65 of the second. Rather
--  than choose silently, both are exposed:
--
--      line_count  distinct products on the order
--      item_count  total units across those products
--
--  LEFT JOIN to order_details deliberately: rule O-02 says an order always has
--  at least one line, and an INNER JOIN here would hide any order that somehow
--  did not. A summary that silently omits broken rows cannot be used to find
--  them.
-- =============================================================================
CREATE OR REPLACE VIEW vw_order_summary AS
SELECT
    o.order_id,
    o.order_date,
    o.status,
    c.customer_id,
    CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
    c.email,
    COUNT(d.order_detail_id)               AS line_count,
    COALESCE(SUM(d.quantity), 0)           AS item_count,
    o.gross_amount,
    o.discount_amount,
    o.net_amount,
    o.cancelled_at
  FROM orders o
  JOIN customers c
    ON c.customer_id = o.customer_id
  LEFT JOIN order_details d
    ON d.order_id = o.order_id
 GROUP BY o.order_id, o.order_date, o.status,
          c.customer_id, c.first_name, c.last_name, c.email,
          o.gross_amount, o.discount_amount, o.net_amount, o.cancelled_at;


-- =============================================================================
--  vw_low_stock
--  "Generate reports identifying products that are low on stock and need
--   replenishment (any product with stock below its reorder point should be
--   flagged)" (Phase 3)
--
--  The filter is `needs_reorder`, the generated column — so this view uses
--  idx_products_needs_reorder rather than scanning the catalogue and evaluating
--  stock_quantity <= reorder_level per row. See docs/05-physical-design.md §5.1.
--
--  Retired products are excluded: is_active = FALSE means the product is no
--  longer sold, so letting it sit on a reorder report would be noise.
--
--  units_to_order matches exactly what sp_replenish_stock would order, so this
--  view is both the report and a preview of the automated action.
-- =============================================================================
CREATE OR REPLACE VIEW vw_low_stock AS
SELECT
    p.product_id,
    p.sku,
    p.product_name,
    cat.category_name,
    p.stock_quantity,
    p.reorder_level,
    p.target_stock_level,
    p.target_stock_level - p.stock_quantity          AS units_to_order,
    (p.stock_quantity = 0)                           AS is_out_of_stock,
    p.unit_price,
    -- Value at LIST price, not cost. This system holds no purchase cost --
    -- that belongs to supplier_products, which is out of scope (assumption
    -- A-24). Naming it honestly avoids it being read as a procurement budget.
    (p.target_stock_level - p.stock_quantity) * p.unit_price AS value_at_list_price
  FROM products p
  JOIN categories cat
    ON cat.category_id = p.category_id
 WHERE p.is_active     = TRUE
   AND p.needs_reorder = TRUE;


-- =============================================================================
--  vw_customer_spending                              rules T-02, T-03, T-06
--  "Categorize customers based on total spending (e.g., Bronze, Silver, Gold
--   tiers) and generate spending reports" (Phase 3)
--
--  This view is the definition of lifetime spend. customers.tier_id is a cache
--  maintained by trigger; what this computes is what that cache is supposed to
--  hold, which is what makes rule T-06 checkable.
--
--  Two details carry the correctness of the whole view:
--
--  1. `o.status <> 'CANCELLED'` sits in the ON clause, NOT in a WHERE clause.
--     In a WHERE clause it would filter out the NULL rows produced by the LEFT
--     JOIN, silently converting it to an INNER JOIN — and a customer whose only
--     orders were cancelled would vanish from the report entirely rather than
--     appearing with a spend of zero. This is rule T-03 and rule T-04 depending
--     on the same line.
--
--  2. COALESCE(..., 0.00) so a customer who has never ordered scores 0 and
--     resolves to the lowest band, rather than to NULL and no band at all
--     (rule T-04). This is why the lowest tier must start at min_spend = 0.
-- =============================================================================
CREATE OR REPLACE VIEW vw_customer_spending AS
SELECT
    s.customer_id,
    s.customer_name,
    s.email,
    s.orders_placed,
    s.cancelled_orders,
    s.lifetime_spend,
    s.total_discount_received,
    t.tier_id                          AS computed_tier_id,
    t.tier_name                        AS computed_tier_name,
    s.stored_tier_id,
    (s.stored_tier_id = t.tier_id)     AS tier_is_current
  FROM (
        SELECT
            c.customer_id,
            CONCAT(c.first_name, ' ', c.last_name)                     AS customer_name,
            c.email,
            c.tier_id                                                  AS stored_tier_id,
            COUNT(o.order_id)                                          AS orders_placed,
            COALESCE(SUM(o.net_amount), 0.00)                          AS lifetime_spend,
            COALESCE(SUM(o.discount_amount), 0.00)                     AS total_discount_received,
            (SELECT COUNT(*) FROM orders x
              WHERE x.customer_id = c.customer_id
                AND x.status = 'CANCELLED')                            AS cancelled_orders
          FROM customers c
          LEFT JOIN orders o
            ON o.customer_id = c.customer_id
           AND o.status     <> 'CANCELLED'     -- ON, not WHERE. See note above.
         GROUP BY c.customer_id, c.first_name, c.last_name, c.email, c.tier_id
       ) AS s
  JOIN customer_tiers t
    ON s.lifetime_spend >= t.min_spend
   AND (t.max_spend IS NULL OR s.lifetime_spend < t.max_spend);
