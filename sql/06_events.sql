-- =============================================================================
--  Inventory and Order Management System
--  06_events.sql — scheduled automation
-- =============================================================================
--
--  "Minimize manual work while ensuring accuracy in inventory tracking and
--   order management" (Phase 4)
--
--  One event. sp_replenish_stock already does the work; this is only the
--  schedule, which is the last piece of rule I-13.
--
--  DEPENDENCY: the server must have event_scheduler = ON, otherwise the event is
--  created and then never fires — silently. The check at the foot of this file
--  reports the setting rather than assuming it.
--
--  Idempotent: the event is dropped before creation.
-- =============================================================================

SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,'
                       'NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

USE inventory_order_management_sys;

DELIMITER $$

-- =============================================================================
--  ev_replenish_stock                                                rule I-13
--
--  Hourly. The interval is a judgement call the requirements do not make, and
--  two properties of sp_replenish_stock make a frequent schedule safe:
--
--    * It is SELF-LIMITING. After topping a product up, stock exceeds
--      reorder_level, so the next run does not see it again. Running hourly on
--      an inventory with nothing low does no writes at all.
--
--    * It is CHEAP when idle. The candidate query filters on needs_reorder,
--      which is indexed, so an idle run is an index lookup returning nothing
--      rather than a scan of the catalogue.
--
--  Together those mean the cost of running too often is near zero, while the
--  cost of running too rarely is a stockout. The asymmetry argues for frequent.
--
--  ON COMPLETION PRESERVE keeps the event after execution -- without it a
--  recurring event is dropped once its schedule ends.
-- =============================================================================
DROP EVENT IF EXISTS ev_replenish_stock$$

CREATE EVENT ev_replenish_stock
  ON SCHEDULE EVERY 1 HOUR
  STARTS CURRENT_TIMESTAMP + INTERVAL 1 HOUR
  ON COMPLETION PRESERVE
  ENABLE
  COMMENT 'Rule I-13: top every low product up to target_stock_level'
DO
BEGIN
  DECLARE v_replenished INT DEFAULT 0;

  -- The OUT parameter is discarded: an event has no caller to return it to.
  -- The audit trail is the point — every top-up leaves a REPLENISHMENT row in
  -- inventory_logs with its quantity, balance, and timestamp, so what the event
  -- did is recoverable from the ledger rather than from a return value.
  CALL sp_replenish_stock(v_replenished);
END$$

DELIMITER ;


-- =============================================================================
--  Verification
-- =============================================================================

-- Must report ON. If it reports OFF the event will never fire; enable it with
--   SET GLOBAL event_scheduler = ON;          (runtime, lost on restart)
-- and add `event_scheduler=ON` to my.cnf to make it survive a restart.
SELECT @@event_scheduler AS event_scheduler_must_be_on;

SELECT event_name, status, interval_value, interval_field,
       starts, last_executed, event_comment
  FROM information_schema.events
 WHERE event_schema = 'inventory_order_management_sys';
