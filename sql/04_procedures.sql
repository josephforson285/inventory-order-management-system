-- =============================================================================
--  Inventory and Order Management System
--  04_procedures.sql — the business API
-- =============================================================================
--
--  Three entry points:
--    sp_place_order       place a multi-product order          I-09 I-10 I-12 O-02 O-06 O-08 D-04 D-05
--    sp_cancel_order      cancel and return stock              I-11 O-04
--    sp_replenish_stock   top low stock up to target           I-13
--
--  TWO CONVENTIONS THESE PROCEDURES OBEY
--
--  1. They never touch products.stock_quantity. Stock is moved by inserting into
--     inventory_logs; a trigger applies it (ADR 0002). A procedure that did both
--     would double-count, and the products guard trigger would reject it anyway.
--
--  2. Products are locked in ascending product_id order, via an explicit cursor
--     loop. `SELECT ... ORDER BY product_id FOR UPDATE` is the usual shorthand,
--     but row ordering in a result set does not formally guarantee the order
--     locks are acquired in. A cursor that fetches in order and locks one row at
--     a time does. Without a consistent order, an order for products (5,9) and a
--     concurrent order for (9,5) can each hold one lock and wait for the other.
--
--  NOTE ON ERROR MESSAGES: MySQL truncates SIGNAL ... MESSAGE_TEXT at 128
--  characters, so diagnostic detail is deliberately terse.
--
--  Idempotent: every routine is dropped before creation.
-- =============================================================================

SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,'
                       'NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

USE inventory_order_management_sys;

DELIMITER $$

-- =============================================================================
--  sp_place_order
--
--  Multiple products in one order (Phase 2) arrive as a JSON array, because
--  MySQL has no table-valued parameters -- there is no way to pass a set of rows
--  to a procedure. JSON_TABLE expands it back into rows.
--
--      CALL sp_place_order(1, '[{"product_id":1,"quantity":12},
--                               {"product_id":4,"quantity":60}]', @order_id);
--
--  Sequence: validate input -> lock every product in id order -> validate stock
--  for ALL lines -> only then write. Nothing is mutated until every line is
--  known to be satisfiable, which is rule I-12.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_place_order$$

CREATE PROCEDURE sp_place_order(
  IN  p_customer_id INT UNSIGNED,
  IN  p_lines       JSON,
  OUT p_order_id    INT UNSIGNED
)
BEGIN
  DECLARE v_done       TINYINT DEFAULT 0;
  DECLARE v_product_id INT UNSIGNED;
  DECLARE v_lock       INT UNSIGNED;
  DECLARE v_problem    TEXT DEFAULT NULL;
  DECLARE v_msg        VARCHAR(128);

  DECLARE cur_products CURSOR FOR
    SELECT product_id FROM tmp_order_lines ORDER BY product_id;

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

  -- Any failure rolls the whole order back. RESIGNAL preserves the original
  -- error so the caller sees which rule was broken, not a generic wrapper.
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    DROP TEMPORARY TABLE IF EXISTS tmp_order_lines;
    RESIGNAL;
  END;

  SET p_order_id = NULL;

  -- ---------------------------------------------------------------- shape ----
  IF p_lines IS NULL OR JSON_TYPE(p_lines) <> 'ARRAY' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'sp_place_order: p_lines must be a JSON array of {product_id, quantity}';
  END IF;

  IF JSON_LENGTH(p_lines) = 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Rule O-02: an order must contain at least one line';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rule O-01: unknown customer_id';
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_order_lines;
  CREATE TEMPORARY TABLE tmp_order_lines (
    product_id INT UNSIGNED NULL,
    quantity   BIGINT       NULL
  ) ENGINE = InnoDB;

  -- Repeated products collapse into one line with the quantities summed --
  -- rule O-06 and assumption A-05. Doing it here rather than letting the unique
  -- constraint reject the insert is what makes "two of the same item" work.
  INSERT INTO tmp_order_lines (product_id, quantity)
  SELECT jt.product_id, SUM(jt.quantity)
    FROM JSON_TABLE(p_lines, '$[*]' COLUMNS (
           product_id INT UNSIGNED PATH '$.product_id',
           quantity   BIGINT       PATH '$.quantity'
         )) AS jt
   GROUP BY jt.product_id;

  IF EXISTS (SELECT 1 FROM tmp_order_lines
              WHERE product_id IS NULL OR quantity IS NULL) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'sp_place_order: every line needs a product_id and a quantity';
  END IF;

  IF EXISTS (SELECT 1 FROM tmp_order_lines WHERE quantity <= 0) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rule O-07: line quantity must be positive';
  END IF;

  SELECT GROUP_CONCAT(t.product_id ORDER BY t.product_id) INTO v_problem
    FROM tmp_order_lines t
    LEFT JOIN products p ON p.product_id = t.product_id
   WHERE p.product_id IS NULL;

  IF v_problem IS NOT NULL THEN
    SET v_msg = LEFT(CONCAT('sp_place_order: unknown product_id(s): ', v_problem), 128);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;

  START TRANSACTION;

  -- ----------------------------------------------------------------- lock ----
  -- One row at a time, ascending product_id. See the header note on why this is
  -- a cursor rather than a single ORDER BY ... FOR UPDATE.
  OPEN cur_products;
  lock_loop: LOOP
    FETCH cur_products INTO v_product_id;
    IF v_done = 1 THEN LEAVE lock_loop; END IF;

    SELECT product_id INTO v_lock
      FROM products
     WHERE product_id = v_product_id
       FOR UPDATE;
  END LOOP;
  CLOSE cur_products;
  SET v_done = 0;

  -- ------------------------------------------------------------- validate ----
  -- Every line checked against locked, current stock BEFORE anything is written.
  SELECT GROUP_CONCAT(p.sku ORDER BY p.sku) INTO v_problem
    FROM tmp_order_lines t
    JOIN products p ON p.product_id = t.product_id
   WHERE p.is_active = FALSE;

  IF v_problem IS NOT NULL THEN
    SET v_msg = LEFT(CONCAT('sp_place_order: product not for sale: ', v_problem), 128);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;

  SELECT GROUP_CONCAT(CONCAT(p.sku, ' want ', t.quantity, ' have ', p.stock_quantity)
                      ORDER BY p.sku SEPARATOR '; ') INTO v_problem
    FROM tmp_order_lines t
    JOIN products p ON p.product_id = t.product_id
   WHERE p.stock_quantity < t.quantity;

  -- rule I-12: all or nothing. No partial fulfilment, no backorder.
  IF v_problem IS NOT NULL THEN
    SET v_msg = LEFT(CONCAT('Rule I-12: order rejected, insufficient stock: ', v_problem), 128);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
  END IF;

  -- ---------------------------------------------------------------- write ----
  INSERT INTO orders (customer_id) VALUES (p_customer_id);
  -- Captured immediately: inserting details would move LAST_INSERT_ID().
  SET p_order_id = LAST_INSERT_ID();

  -- unit_price and discount_percent_applied are SNAPSHOTS (rules O-08, D-05) --
  -- what this customer was charged today, not what the product costs later.
  --
  -- The discount band is resolved from each line's OWN quantity (rule D-04).
  -- ORDER BY min_quantity DESC LIMIT 1 takes the highest matching band, so the
  -- resolution is deterministic even if the bands were mis-configured to
  -- overlap. A line matching no band gets NULL: sold at full price.
  INSERT INTO order_details
        (order_id, product_id, quantity, unit_price, discount_percent_applied, discount_rule_id)
  SELECT p_order_id,
         t.product_id,
         t.quantity,
         p.unit_price,
         COALESCE((SELECT dr.discount_percent
                     FROM discount_rules dr
                    WHERE dr.is_active = TRUE
                      AND t.quantity >= dr.min_quantity
                      AND (dr.max_quantity IS NULL OR t.quantity < dr.max_quantity)
                    ORDER BY dr.min_quantity DESC
                    LIMIT 1), 0.00),
         (SELECT dr.discount_rule_id
            FROM discount_rules dr
           WHERE dr.is_active = TRUE
             AND t.quantity >= dr.min_quantity
             AND (dr.max_quantity IS NULL OR t.quantity < dr.max_quantity)
           ORDER BY dr.min_quantity DESC
           LIMIT 1)
    FROM tmp_order_lines t
    JOIN products p ON p.product_id = t.product_id;

  -- Stock moves here, and only here. The trigger on inventory_logs computes
  -- balance_after and applies it to products.
  INSERT INTO inventory_logs (product_id, movement_type, quantity_change, order_id)
  SELECT t.product_id, 'SALE', -t.quantity, p_order_id
    FROM tmp_order_lines t
   ORDER BY t.product_id;

  COMMIT;
  DROP TEMPORARY TABLE IF EXISTS tmp_order_lines;
END$$


-- =============================================================================
--  sp_cancel_order                                            rules I-11, O-04
--  Returns every unit to stock as a CANCELLATION movement, then marks the order
--  cancelled -- which fires the tier refresh, since cancelled orders do not
--  count toward lifetime spend (rule T-03).
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_cancel_order$$

CREATE PROCEDURE sp_cancel_order(IN p_order_id INT UNSIGNED)
BEGIN
  DECLARE v_done       TINYINT DEFAULT 0;
  DECLARE v_status     VARCHAR(20) DEFAULT NULL;
  DECLARE v_product_id INT UNSIGNED;
  DECLARE v_lock       INT UNSIGNED;

  DECLARE cur_products CURSOR FOR
    SELECT product_id FROM order_details WHERE order_id = p_order_id ORDER BY product_id;

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SELECT status INTO v_status
    FROM orders
   WHERE order_id = p_order_id
     FOR UPDATE;

  IF v_status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'sp_cancel_order: unknown order_id';
  END IF;

  -- rule O-04: cancelling an already-cancelled order would return its stock a
  -- second time, inventing units that never existed.
  IF v_status <> 'PLACED' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Rule O-04: only a PLACED order can be cancelled';
  END IF;

  SET v_done = 0;
  OPEN cur_products;
  lock_loop: LOOP
    FETCH cur_products INTO v_product_id;
    IF v_done = 1 THEN LEAVE lock_loop; END IF;

    SELECT product_id INTO v_lock
      FROM products
     WHERE product_id = v_product_id
       FOR UPDATE;
  END LOOP;
  CLOSE cur_products;

  -- Positive movements: stock coming back in. The sign constraint
  -- (chk_inventory_logs_sign_matches_type) enforces that a CANCELLATION cannot
  -- be negative.
  INSERT INTO inventory_logs (product_id, movement_type, quantity_change, order_id)
  SELECT product_id, 'CANCELLATION', quantity, p_order_id
    FROM order_details
   WHERE order_id = p_order_id
   ORDER BY product_id;

  -- cancelled_at is not optional here: chk_orders_cancelled_at_consistent
  -- requires it to be set exactly when status is CANCELLED.
  UPDATE orders
     SET status       = 'CANCELLED',
         cancelled_at = NOW()
   WHERE order_id = p_order_id;

  COMMIT;
END$$


-- =============================================================================
--  sp_replenish_stock                                              rule I-13
--
--  Tops every low product up to target_stock_level. Triggered at stock <=
--  reorder_level (assumption A-06: at or below, not strictly below).
--
--  Top-up rather than a fixed reorder quantity (assumption A-07): a product that
--  crashed to zero would still be below its threshold after a fixed-size
--  delivery. Because chk_products_target_above_reorder guarantees
--  target > reorder >= stock, the top-up is always positive -- which matters,
--  since a REPLENISHMENT of zero or less would violate two constraints.
--
--  Self-limiting: after topping up, stock > reorder_level, so a second run finds
--  nothing. Safe to schedule as often as desired.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_replenish_stock$$

CREATE PROCEDURE sp_replenish_stock(OUT p_products_replenished INT)
BEGIN
  DECLARE v_done       TINYINT DEFAULT 0;
  DECLARE v_product_id INT UNSIGNED;
  DECLARE v_top_up     INT;
  DECLARE v_count      INT DEFAULT 0;
  DECLARE v_lock       INT UNSIGNED;

  DECLARE cur_low CURSOR FOR
    SELECT product_id, top_up FROM tmp_replenish ORDER BY product_id;

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    DROP TEMPORARY TABLE IF EXISTS tmp_replenish;
    RESIGNAL;
  END;

  DROP TEMPORARY TABLE IF EXISTS tmp_replenish;
  CREATE TEMPORARY TABLE tmp_replenish (
    product_id INT UNSIGNED NOT NULL,
    top_up     INT          NOT NULL
  ) ENGINE = InnoDB;

  START TRANSACTION;

  -- Snapshot the candidates first. Looping over a cursor on products while the
  -- ledger trigger writes to products is asking for trouble; a temporary table
  -- decouples the read from the writes.
  --
  -- needs_reorder is the generated column, so this uses
  -- idx_products_needs_reorder rather than scanning the catalogue.
  INSERT INTO tmp_replenish (product_id, top_up)
  SELECT product_id, target_stock_level - stock_quantity
    FROM products
   WHERE is_active     = TRUE
     AND needs_reorder = TRUE;

  OPEN cur_low;
  replenish_loop: LOOP
    FETCH cur_low INTO v_product_id, v_top_up;
    IF v_done = 1 THEN LEAVE replenish_loop; END IF;

    SELECT product_id INTO v_lock
      FROM products
     WHERE product_id = v_product_id
       FOR UPDATE;

    INSERT INTO inventory_logs (product_id, movement_type, quantity_change, notes)
    VALUES (v_product_id, 'REPLENISHMENT', v_top_up, 'Automatic top-up to target_stock_level');

    SET v_count = v_count + 1;
  END LOOP;
  CLOSE cur_low;

  SET p_products_replenished = v_count;

  COMMIT;
  DROP TEMPORARY TABLE IF EXISTS tmp_replenish;
END$$

DELIMITER ;
