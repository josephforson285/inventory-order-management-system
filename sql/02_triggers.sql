-- =============================================================================
--  Inventory and Order Management System
--  02_triggers.sql — automation and immutability
-- =============================================================================
--
--  WRITE DIRECTION
--  ---------------
--  Stock is changed by INSERTING INTO inventory_logs. A trigger then applies the
--  movement to products.stock_quantity. Never the other way round.
--
--      INSERT INTO inventory_logs (...)   <- the application writes here
--            |
--            +-- trg_inventory_logs_before_insert   computes balance_after
--            +-- trg_inventory_logs_after_insert    applies it to products
--
--  This is the opposite of the obvious design, and the reason matters. A trigger
--  on products sees only the row before and after: stock went 100 -> 88. It
--  cannot know whether that was a SALE (which requires an order_id) or an
--  ADJUSTMENT (which forbids one), so it cannot supply a correct movement_type.
--  Passing the intent in via a session variable works but is invisible and
--  survives the statement that set it, so a stale value silently mislabels the
--  next movement.
--
--  Inverting the direction removes the problem instead of managing it: intent is
--  part of the write. It also matches what the design already claims -- the
--  ledger is the source of truth and stock_quantity is a cache over it, so the
--  application should write to the truth and let the cache follow.
--
--  Rule I-02 therefore becomes structural rather than procedural: stock cannot
--  be changed except by writing to the ledger, because writing to the ledger is
--  the only mechanism that changes it. Three guards close the loop:
--
--    trg_products_before_insert   stock must start at zero
--    trg_products_before_update   stock_quantity is not directly writable
--    10_grants.sql                column-level UPDATE revoked from the app user
--
--  Because balance_after is computed once and then copied to products, the cache
--  agrees with the ledger BY CONSTRUCTION. Rule I-08's reconciliation query
--  verifies that rather than hoping for it.
--
--  CALLER RESTRICTION — a ledger insert may not read `products` in the same
--  statement. Because trg_inventory_logs_after_insert updates products, MySQL
--  rejects any statement that reads products while inserting into
--  inventory_logs (error 1442). So this fails:
--
--      INSERT INTO inventory_logs (product_id, movement_type, quantity_change)
--      SELECT product_id, 'ADJUSTMENT', -(stock_quantity - 10) FROM products ...
--
--  and this works:
--
--      SELECT stock_quantity - 10 INTO @adj FROM products WHERE product_id = 4;
--      INSERT INTO inventory_logs (...) VALUES (4, 'ADJUSTMENT', -@adj);
--
--  This is why sp_place_order stages its lines in a temporary table and inserts
--  ledger rows from there. See ADR 0002.
--
--  Rules owned here: I-01 I-02 I-03 I-07 I-15 O-05 O-10 O-13 T-05
--  Idempotent: every object is dropped before creation.
-- =============================================================================

SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,'
                       'NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

USE inventory_order_management_sys;

DELIMITER $$

-- =============================================================================
--  Internal helper — recalculate one customer's tier                 rule T-05
--  Lives here rather than in 04_procedures.sql because it is trigger
--  infrastructure, not part of the business API. Two triggers need it, and
--  duplicating the band-resolution logic between them would be a defect
--  waiting to happen.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_refresh_customer_tier$$

CREATE PROCEDURE sp_refresh_customer_tier(IN p_customer_id INT UNSIGNED)
BEGIN
  DECLARE v_spend DECIMAL(14,2);
  DECLARE v_tier  TINYINT UNSIGNED;

  -- rule T-02 / T-03: lifetime spend excludes cancelled orders
  SELECT COALESCE(SUM(net_amount), 0.00) INTO v_spend
    FROM orders
   WHERE customer_id = p_customer_id
     AND status <> 'CANCELLED';

  -- Bands are half-open: [min_spend, max_spend). NULL max_spend = unbounded.
  SELECT tier_id INTO v_tier
    FROM customer_tiers
   WHERE v_spend >= min_spend
     AND (max_spend IS NULL OR v_spend < max_spend)
   ORDER BY min_spend DESC
   LIMIT 1;

  -- rule T-01: bands must tile the range. Failing loudly here is deliberate --
  -- a gap in reference data would otherwise silently leave tiers stale.
  IF v_tier IS NULL THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Rule T-01: no tier band matches this spend - customer_tiers has a gap';
  END IF;

  UPDATE customers SET tier_id = v_tier WHERE customer_id = p_customer_id;
END$$


-- =============================================================================
--  inventory_logs BEFORE INSERT — compute the resulting balance   rules I-01 I-07
-- =============================================================================
DROP TRIGGER IF EXISTS trg_inventory_logs_before_insert$$

CREATE TRIGGER trg_inventory_logs_before_insert
BEFORE INSERT ON inventory_logs
FOR EACH ROW
BEGIN
  DECLARE v_current INT UNSIGNED;
  DECLARE v_result  BIGINT;

  -- FOR UPDATE locks the product row for the remainder of the transaction.
  -- sp_place_order already holds this lock (acquired in product_id order to
  -- avoid deadlock), so this is a no-op there. For a direct ledger insert it is
  -- what makes rule I-10 hold regardless of the caller.
  SELECT stock_quantity INTO v_current
    FROM products
   WHERE product_id = NEW.product_id
     FOR UPDATE;

  -- The foreign key is checked after this trigger runs, so an unknown product
  -- reaches us as a missing row rather than as an error.
  IF v_current IS NULL THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'inventory_logs: unknown product_id';
  END IF;

  SET v_result = CAST(v_current AS SIGNED) + NEW.quantity_change;

  -- rule I-01. Checked here so the error names the business rule; the UNSIGNED
  -- column and its CHECK would otherwise reject it with an arithmetic message.
  IF v_result < 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Rule I-01: movement would drive stock below zero';
  END IF;

  SET NEW.balance_after = v_result;
END$$


-- =============================================================================
--  inventory_logs AFTER INSERT — apply the movement to stock          rule I-02
-- =============================================================================
DROP TRIGGER IF EXISTS trg_inventory_logs_after_insert$$

CREATE TRIGGER trg_inventory_logs_after_insert
AFTER INSERT ON inventory_logs
FOR EACH ROW
BEGIN
  -- Latch that authorises the one legitimate write to stock_quantity. This is a
  -- local flag raised and lowered around a single statement, not a channel for
  -- business intent -- it cannot go stale across statements the way a
  -- movement_type variable would.
  SET @allow_stock_write = 1;

  -- balance_after, not a recomputation. Copying the value the ledger recorded is
  -- what makes the cache agree with the ledger by construction.
  UPDATE products
     SET stock_quantity = NEW.balance_after
   WHERE product_id = NEW.product_id;

  SET @allow_stock_write = NULL;
END$$


-- =============================================================================
--  inventory_logs — append-only                                      rule I-03
--  An audit trail that can be edited is not an audit trail. Triggers are the
--  portable half of this; 10_grants.sql revokes the privileges as well, because
--  a trigger does not constrain a sufficiently privileged user.
-- =============================================================================
DROP TRIGGER IF EXISTS trg_inventory_logs_before_update$$

CREATE TRIGGER trg_inventory_logs_before_update
BEFORE UPDATE ON inventory_logs
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Rule I-03: inventory_logs is append-only - rows cannot be updated';
END$$

DROP TRIGGER IF EXISTS trg_inventory_logs_before_delete$$

CREATE TRIGGER trg_inventory_logs_before_delete
BEFORE DELETE ON inventory_logs
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Rule I-03: inventory_logs is append-only - rows cannot be deleted';
END$$


-- =============================================================================
--  products — stock is writable only through the ledger        rules I-02 I-15
-- =============================================================================
DROP TRIGGER IF EXISTS trg_products_before_insert$$

CREATE TRIGGER trg_products_before_insert
BEFORE INSERT ON products
FOR EACH ROW
BEGIN
  -- rule I-15: a product created with stock already on it would hold stock that
  -- no ledger row accounts for, and rule I-08 would fail from the first row.
  -- Opening stock is loaded as an INITIAL_LOAD movement instead.
  IF NEW.stock_quantity <> 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Rule I-15: products must be created with zero stock - load opening stock as an INITIAL_LOAD movement';
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_products_before_update$$

CREATE TRIGGER trg_products_before_update
BEFORE UPDATE ON products
FOR EACH ROW
BEGIN
  -- Every other column stays freely editable; only stock_quantity is reserved
  -- to the ledger. Without this, a direct UPDATE would move stock without
  -- leaving an audit row.
  IF NEW.stock_quantity <> OLD.stock_quantity THEN
    IF COALESCE(@allow_stock_write, 0) <> 1 THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Rule I-02: stock_quantity may only change via an inventory_logs insert';
    END IF;

    -- Consume the latch immediately, making it single-use. User variables are
    -- not transactional: if the surrounding statement later fails, an
    -- uncleared latch would leave a subsequent manual UPDATE authorised.
    -- Spending the token here rather than after the write closes that window.
    SET @allow_stock_write = NULL;
  END IF;
END$$


-- =============================================================================
--  order_details — immutable once written                             rule O-05
--  Corrections are made by cancelling the order and re-placing it, which keeps
--  both the order history and the stock ledger honest. Amending a line in place
--  would silently invalidate the order totals and the stock already moved.
-- =============================================================================
DROP TRIGGER IF EXISTS trg_order_details_before_update$$

CREATE TRIGGER trg_order_details_before_update
BEFORE UPDATE ON order_details
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Rule O-05: order_details are immutable - cancel and re-place the order instead';
END$$

DROP TRIGGER IF EXISTS trg_order_details_before_delete$$

CREATE TRIGGER trg_order_details_before_delete
BEFORE DELETE ON order_details
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Rule O-05: order_details are immutable - cancel and re-place the order instead';
END$$


-- =============================================================================
--  order_details AFTER INSERT — maintain the order's totals           rule O-10
-- =============================================================================
DROP TRIGGER IF EXISTS trg_order_details_after_insert$$

CREATE TRIGGER trg_order_details_after_insert
AFTER INSERT ON order_details
FOR EACH ROW
BEGIN
  -- Incremental rather than re-aggregating the whole order: detail rows are
  -- immutable and never deleted (O-05), so adding the new row's contribution is
  -- both cheaper and exactly equivalent.
  --
  -- orders.net_amount is a generated column and follows automatically. Updating
  -- orders here also fires trg_orders_after_update, which is what refreshes the
  -- customer's tier once the totals are real -- at the moment the order header
  -- was inserted its totals were still zero.
  UPDATE orders
     SET gross_amount    = gross_amount    + NEW.gross_amount,
         discount_amount = discount_amount + NEW.discount_amount
   WHERE order_id = NEW.order_id;
END$$


-- =============================================================================
--  orders BEFORE INSERT — no future-dating                            rule O-13
--  A trigger rather than a CHECK because MySQL forbids non-deterministic
--  functions such as NOW() inside CHECK constraints.
-- =============================================================================
DROP TRIGGER IF EXISTS trg_orders_before_insert$$

CREATE TRIGGER trg_orders_before_insert
BEFORE INSERT ON orders
FOR EACH ROW
BEGIN
  IF NEW.order_date > NOW() THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Rule O-13: order_date may not be in the future';
  END IF;
END$$


-- =============================================================================
--  orders — keep the cached customer tier current                     rule T-05
-- =============================================================================
DROP TRIGGER IF EXISTS trg_orders_after_insert$$

CREATE TRIGGER trg_orders_after_insert
AFTER INSERT ON orders
FOR EACH ROW
BEGIN
  CALL sp_refresh_customer_tier(NEW.customer_id);
END$$

DROP TRIGGER IF EXISTS trg_orders_after_update$$

CREATE TRIGGER trg_orders_after_update
AFTER UPDATE ON orders
FOR EACH ROW
BEGIN
  -- Guarded: this trigger fires on every update to an order, including ones
  -- that cannot affect spend. Only a change in value or in cancellation status
  -- can move a customer between tiers.
  IF NEW.net_amount <> OLD.net_amount OR NEW.status <> OLD.status THEN
    CALL sp_refresh_customer_tier(NEW.customer_id);
  END IF;
END$$

DELIMITER ;
