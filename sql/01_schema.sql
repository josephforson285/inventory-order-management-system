-- =============================================================================
--  Inventory and Order Management System
--  01_schema.sql — base tables, constraints, and indexes
-- =============================================================================
--
--  Design references:
--    docs/02-business-rules.md   every constraint below cites the rule it owns
--    docs/04-logical-model.md    attributes, keys, normalisation
--    docs/05-physical-design.md  types, engine, charset, index strategy
--
--  Conventions:
--    * Every constraint is explicitly named, so violations report which rule
--      fired rather than an auto-generated label such as `products_chk_2`.
--    * Cached (denormalised) columns carry a COMMENT naming the rule that
--      proves they have not drifted.
--    * Surrogate primary keys are immutable, so every foreign key is
--      ON DELETE RESTRICT ON UPDATE RESTRICT — nothing here should ever cascade.
--      This is also a hard requirement rather than a preference: MySQL forbids a
--      column carrying a CASCADE referential action from appearing in a CHECK
--      constraint (error 3823), and chk_inventory_logs_order_presence depends on
--      inventory_logs.order_id.
--
--  Idempotent: safe to re-run. Tables are dropped in reverse dependency order.
--  Run order: 01_schema -> 02_reference_data -> ... -> 09_reconciliation
-- =============================================================================

-- The schema depends on STRICT_TRANS_TABLES: without it, writing a negative
-- value to an UNSIGNED column is clamped to 0 with a warning instead of
-- failing, which would silently defeat rule I-01. Set explicitly rather than
-- trusting the server default. See docs/05-physical-design.md §7.
SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,'
                       'NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

CREATE DATABASE IF NOT EXISTS inventory_order_management_sys
  CHARACTER SET utf8mb4
  COLLATE       utf8mb4_0900_ai_ci;

USE inventory_order_management_sys;

-- Reverse dependency order so foreign keys never block a drop.
DROP TABLE IF EXISTS inventory_logs;
DROP TABLE IF EXISTS order_details;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS discount_rules;
DROP TABLE IF EXISTS customer_tiers;
DROP TABLE IF EXISTS categories;


-- =============================================================================
--  categories
--  Exists to remove the transitive dependency product_id -> category_name.
--  See docs/04-logical-model.md §2 (third normal form).
-- =============================================================================
CREATE TABLE categories (
  category_id   SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  category_name VARCHAR(60)       NOT NULL,
  description   VARCHAR(255)          NULL,
  created_at    DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP
                                           ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (category_id),
  CONSTRAINT uq_categories_name UNIQUE (category_name)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = 'Product groupings. Case-insensitive collation prevents Electronics/electronics splitting.';


-- =============================================================================
--  customer_tiers                                          rules T-01, T-04
--  Spending bands held as DATA rather than a hardcoded CASE expression, so
--  finance can retier customers without a schema migration.
-- =============================================================================
CREATE TABLE customer_tiers (
  tier_id    TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tier_name  VARCHAR(20)      NOT NULL,
  min_spend  DECIMAL(12,2)    NOT NULL COMMENT 'Inclusive floor. Lowest band must be 0 - rule T-04',
  max_spend  DECIMAL(12,2)        NULL COMMENT 'Exclusive ceiling. NULL = unbounded top band',
  created_at DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP
                                       ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (tier_id),
  CONSTRAINT uq_customer_tiers_name UNIQUE (tier_name),
  -- rule T-01, partially enforced: two bands sharing a floor necessarily
  -- overlap, so uniqueness rules out one whole class of overlap declaratively.
  -- Full non-overlap still needs the reconciliation query.
  CONSTRAINT uq_customer_tiers_min_spend UNIQUE (min_spend),

  -- rule T-01: a band's floor lies below its ceiling
  CONSTRAINT chk_customer_tiers_band
    CHECK (max_spend IS NULL OR min_spend < max_spend),
  CONSTRAINT chk_customer_tiers_min_non_negative
    CHECK (min_spend >= 0)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = 'Tier definitions. Reporting only - tiers never affect price (rule D-06).';


-- =============================================================================
--  discount_rules                                    rules D-01, D-02, D-03
--  Bulk-discount breakpoints held as data. Resolved per order line from that
--  line's own quantity (rule D-04), never from the order's total quantity.
-- =============================================================================
CREATE TABLE discount_rules (
  discount_rule_id SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  min_quantity     INT UNSIGNED      NOT NULL COMMENT 'Inclusive floor',
  max_quantity     INT UNSIGNED          NULL COMMENT 'Exclusive ceiling. NULL = unbounded top band',
  discount_percent DECIMAL(5,2)      NOT NULL,
  is_active        BOOLEAN           NOT NULL DEFAULT TRUE,
  created_at       DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at       DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP
                                              ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (discount_rule_id),
  -- rule D-03, partially enforced: same reasoning as customer_tiers. Two bands
  -- sharing a floor overlap by definition.
  CONSTRAINT uq_discount_rules_min_quantity UNIQUE (min_quantity),

  -- rule D-01
  CONSTRAINT chk_discount_rules_percent
    CHECK (discount_percent BETWEEN 0 AND 100),
  -- rule D-02
  CONSTRAINT chk_discount_rules_band
    CHECK (max_quantity IS NULL OR min_quantity < max_quantity),
  CONSTRAINT chk_discount_rules_min_positive
    CHECK (min_quantity > 0)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = 'Quantity-based discount bands. Non-overlap is VERIFIED, not enforced - rule D-03.';


-- =============================================================================
--  products                                    rules I-01, I-14, Q2 (low stock)
-- =============================================================================
CREATE TABLE products (
  product_id         INT UNSIGNED      NOT NULL AUTO_INCREMENT,
  category_id        SMALLINT UNSIGNED NOT NULL,
  sku                VARCHAR(32)       NOT NULL COMMENT 'Natural key. Surrogate PK used because SKUs are mutable',
  product_name       VARCHAR(120)      NOT NULL,
  unit_price         DECIMAL(12,2)     NOT NULL,
  stock_quantity     INT UNSIGNED      NOT NULL DEFAULT 0
                     COMMENT 'CACHE of SUM(inventory_logs.quantity_change) - proven by rule I-08',
  reorder_level      INT UNSIGNED      NOT NULL DEFAULT 0
                     COMMENT 'Replenish at or BELOW this level (<=, not <) - rule I-13',
  target_stock_level INT UNSIGNED      NOT NULL
                     COMMENT 'Top-up destination for replenishment - rule I-13',
  is_active          BOOLEAN           NOT NULL DEFAULT TRUE
                     COMMENT 'Soft retirement. Products are never deleted (ON DELETE RESTRICT)',

  -- Phase 3 asks for low-stock products to be "flagged". A column-to-column
  -- comparison cannot be indexed, so the comparison becomes the column, and the
  -- column is what gets indexed. VIRTUAL => no row storage; the value is
  -- materialised only inside idx_products_needs_reorder.
  -- See docs/05-physical-design.md §5.1.
  needs_reorder      BOOLEAN GENERATED ALWAYS AS (stock_quantity <= reorder_level) VIRTUAL
                     COMMENT 'Phase 3 low-stock flag. Indexed; TRUE is rare, hence selective',

  created_at         DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at         DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (product_id),
  CONSTRAINT uq_products_sku UNIQUE (sku),
  KEY idx_products_category      (category_id),
  KEY idx_products_needs_reorder (needs_reorder),

  CONSTRAINT fk_products_categories
    FOREIGN KEY (category_id) REFERENCES categories (category_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,

  CONSTRAINT chk_products_price_positive
    CHECK (unit_price > 0),
  -- rule I-01. Redundant against INT UNSIGNED by design: the constraint names
  -- the business rule, and survives a future change of column type.
  CONSTRAINT chk_products_stock_non_negative
    CHECK (stock_quantity >= 0),
  -- rule I-14: replenishment needs somewhere above the threshold to aim for
  CONSTRAINT chk_products_target_above_reorder
    CHECK (target_stock_level > reorder_level)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = 'Sellable products. stock_quantity is a cache; inventory_logs is the ledger of record.';


-- =============================================================================
--  customers                                                      rule T-05
-- =============================================================================
CREATE TABLE customers (
  customer_id INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  first_name  VARCHAR(60)      NOT NULL COMMENT 'Split from the spec''s "name" for 1NF atomicity',
  last_name   VARCHAR(60)      NOT NULL,
  email       VARCHAR(160)     NOT NULL COMMENT 'Natural key. Case-insensitive collation is deliberate',
  phone       VARCHAR(20)          NULL COMMENT 'Text, never numeric - leading zeros are significant',
  tier_id     TINYINT UNSIGNED NOT NULL
              COMMENT 'CACHE of vw_customer_spending - maintained by T-05, proven by rule T-06',
  created_at  DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP
                                        ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (customer_id),
  CONSTRAINT uq_customers_email UNIQUE (email),
  KEY idx_customers_tier (tier_id),

  CONSTRAINT fk_customers_customer_tiers
    FOREIGN KEY (tier_id) REFERENCES customer_tiers (tier_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = 'Customers. Never deleted while orders exist (ON DELETE RESTRICT on orders).';


-- =============================================================================
--  orders                          rules O-01, O-03, O-10, O-11, O-12, O-13
-- =============================================================================
CREATE TABLE orders (
  order_id        INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  customer_id     INT UNSIGNED  NOT NULL,
  order_date      DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                  COMMENT 'Not future-dated - rule O-13, enforced by trigger (CHECK cannot use NOW())',
  status          ENUM('PLACED','CANCELLED') NOT NULL DEFAULT 'PLACED'
                  COMMENT 'Two states only - rule O-03. No reservation model, so nothing is provisional',

  gross_amount    DECIMAL(12,2) NOT NULL DEFAULT 0.00
                  COMMENT 'CACHE of SUM(order_details.gross_amount) - maintained by O-10, proven by O-11',
  discount_amount DECIMAL(12,2) NOT NULL DEFAULT 0.00
                  COMMENT 'CACHE of SUM(order_details.discount_amount) - maintained by O-10, proven by O-11',
  -- Arithmetic within one row, so the engine owns it and no trigger can get it
  -- wrong. gross/discount are aggregates across rows and cannot be generated.
  net_amount      DECIMAL(12,2) GENERATED ALWAYS AS (gross_amount - discount_amount) STORED
                  COMMENT 'Engine-owned; cannot drift',

  cancelled_at    DATETIME          NULL,
  created_at      DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                                         ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (order_id),
  -- Q1: a customer's order history, in date order
  KEY idx_orders_customer_date       (customer_id, order_date),
  -- Q3: lifetime spend. Covering - equality columns first, aggregate last, so
  -- the SUM is answered from the index without touching table rows.
  KEY idx_orders_customer_status_net (customer_id, status, net_amount),

  -- rule O-01
  CONSTRAINT fk_orders_customers
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,

  CONSTRAINT chk_orders_amounts_non_negative
    CHECK (gross_amount >= 0 AND discount_amount >= 0),
  CONSTRAINT chk_orders_discount_within_gross
    CHECK (discount_amount <= gross_amount),
  -- cancelled_at is populated exactly when the order is cancelled
  CONSTRAINT chk_orders_cancelled_at_consistent
    CHECK ((status = 'CANCELLED' AND cancelled_at IS NOT NULL)
        OR (status = 'PLACED'    AND cancelled_at IS NULL))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = 'Order headers. Totals are caches of order_details; net_amount is engine-generated.';


-- =============================================================================
--  order_details                       rules O-05, O-06, O-07, O-08, O-09, D-05
--  Named after the source requirements' vocabulary ("Order Details") rather
--  than the industry term "order lines", so every term in the spec maps to a
--  schema object without translation.
-- =============================================================================
CREATE TABLE order_details (
  order_detail_id          INT UNSIGNED      NOT NULL AUTO_INCREMENT,
  order_id                 INT UNSIGNED      NOT NULL,
  product_id               INT UNSIGNED      NOT NULL,
  quantity                 INT UNSIGNED      NOT NULL,

  -- TEMPORAL FACTS, not redundancy. These record what was charged on this date,
  -- which is a different fact from what the product costs now. Joining live to
  -- products/discount_rules would silently re-price every historical order
  -- whenever reference data changed. See docs/04-logical-model.md §1.
  unit_price               DECIMAL(12,2)     NOT NULL
                           COMMENT 'Price at time of sale - rule O-08. Never joined live from products',
  discount_percent_applied DECIMAL(5,2)      NOT NULL DEFAULT 0.00
                           COMMENT 'Rate granted at time of sale - rule D-05',
  discount_rule_id         SMALLINT UNSIGNED     NULL
                           COMMENT 'Which band fired. NULL = sold at full price',

  -- rule O-09: all three follow arithmetically from the row's own values, so
  -- the engine owns them and no reconciliation query is needed.
  gross_amount             DECIMAL(14,2)
                           GENERATED ALWAYS AS (quantity * unit_price) STORED,
  discount_amount          DECIMAL(14,2)
                           GENERATED ALWAYS AS (ROUND(gross_amount * discount_percent_applied / 100, 2)) STORED
                           COMMENT 'Rounded per detail row, not per order, so totals reconcile exactly',
  net_amount               DECIMAL(14,2)
                           GENERATED ALWAYS AS (gross_amount - discount_amount) STORED,

  created_at               DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (order_detail_id),
  -- rule O-06. Leading with order_id means this also satisfies the foreign
  -- key's index requirement, so no separate idx_order_details_order is created.
  CONSTRAINT uq_order_details_order_product UNIQUE (order_id, product_id),
  -- Q7: units sold per product
  KEY idx_order_details_product_qty    (product_id, quantity),
  -- Q6: discount given, grouped by rule
  KEY idx_order_details_discount_rule  (discount_rule_id),

  CONSTRAINT fk_order_details_orders
    FOREIGN KEY (order_id) REFERENCES orders (order_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_order_details_products
    FOREIGN KEY (product_id) REFERENCES products (product_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_order_details_discount_rules
    FOREIGN KEY (discount_rule_id) REFERENCES discount_rules (discount_rule_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,

  -- rule O-07
  CONSTRAINT chk_order_details_quantity_positive
    CHECK (quantity > 0),
  CONSTRAINT chk_order_details_price_positive
    CHECK (unit_price > 0),
  CONSTRAINT chk_order_details_discount_percent
    CHECK (discount_percent_applied BETWEEN 0 AND 100)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = 'Order line items. unit_price and discount are snapshots, never live lookups.';


-- =============================================================================
--  inventory_logs                          rules I-02, I-04, I-05, I-06, I-07
--  The LEDGER OF RECORD for stock. products.stock_quantity is merely a cached
--  balance over this table; rule I-08 proves the two agree.
--  Append-only: the immutability triggers live in 05_triggers.sql (rule I-03).
-- =============================================================================
CREATE TABLE inventory_logs (
  log_id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  product_id      INT UNSIGNED NOT NULL,
  movement_type   ENUM('SALE','RETURN','REPLENISHMENT','ADJUSTMENT',
                       'CANCELLATION','INITIAL_LOAD') NOT NULL
                  COMMENT 'Reason code - rule I-04. RETURN is reserved; not produced in this scope',

  -- The only signed integer in the schema. Negative = out, positive = in, which
  -- is what lets rule I-08 be a single SUM rather than a conditional aggregate.
  quantity_change INT          NOT NULL
                  COMMENT 'Signed delta: negative = stock out, positive = stock in',
  balance_after   INT UNSIGNED NOT NULL
                  COMMENT 'Resulting stock level - rule I-07. Makes point-in-time audit O(1)',

  order_id        INT UNSIGNED     NULL
                  COMMENT 'Cause of the movement. NULL for non-sale movements - see CHECK below',
  notes           VARCHAR(255)     NULL COMMENT 'Free text, for ADJUSTMENT',
  created_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (log_id),
  -- One index, two queries: Q4 (a product's history in time order) uses the
  -- first two parts; Q5 (reconciliation SUM per product) reads all three
  -- index-only. Two separate product_id-leading indexes would double write cost
  -- for nothing. See docs/05-physical-design.md §5.
  KEY idx_inventory_logs_product_time_qty (product_id, created_at, quantity_change),
  KEY idx_inventory_logs_order            (order_id),

  CONSTRAINT fk_inventory_logs_products
    FOREIGN KEY (product_id) REFERENCES products (product_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_inventory_logs_orders
    FOREIGN KEY (order_id) REFERENCES orders (order_id)
    ON DELETE RESTRICT ON UPDATE RESTRICT,

  -- rule I-06: a movement of zero is meaningless noise in an audit trail
  CONSTRAINT chk_inventory_logs_change_non_zero
    CHECK (quantity_change <> 0),

  -- rule I-05: the sign must agree with the reason code. A SALE cannot add
  -- stock; a REPLENISHMENT cannot remove it. ADJUSTMENT is the only movement
  -- permitted in either direction, which is precisely what makes it an
  -- adjustment.
  CONSTRAINT chk_inventory_logs_sign_matches_type
    CHECK ((movement_type = 'SALE' AND quantity_change < 0)
        OR (movement_type IN ('RETURN','REPLENISHMENT','CANCELLATION','INITIAL_LOAD')
            AND quantity_change > 0)
        OR (movement_type = 'ADJUSTMENT')),

  -- A conditional relationship: sales-related movements must name their order;
  -- stock-management movements must not. This is what makes the table a full
  -- stock history rather than merely a sales history.
  CONSTRAINT chk_inventory_logs_order_presence
    CHECK ((movement_type IN ('SALE','CANCELLATION','RETURN') AND order_id IS NOT NULL)
        OR (movement_type IN ('REPLENISHMENT','ADJUSTMENT','INITIAL_LOAD') AND order_id IS NULL))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = 'Immutable stock ledger. Append-only (rule I-03). The source of truth for stock.';
