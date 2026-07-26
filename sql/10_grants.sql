-- =============================================================================
--  Inventory and Order Management System
--  10_grants.sql — privilege model
-- =============================================================================
--
--  Two rules are only half-enforced by triggers, because a trigger does not
--  constrain a user who has the privilege to drop it:
--
--    I-02  stock_quantity may change only through the ledger
--    I-03  inventory_logs is append-only
--
--  This file supplies the other half. Where the triggers make the rules hard to
--  break by accident, the privileges make them hard to break on purpose.
--
--  ROLES, NOT USERS. This script creates roles and grants privileges to them.
--  It deliberately creates no user accounts, because a committed CREATE USER
--  statement means a committed password. The operator creates accounts
--  out-of-band and grants them a role:
--
--      -- run by the DBA, never committed:
--      CREATE USER 'shopapp'@'%' ...;
--      GRANT ims_app TO 'shopapp'@'%';
--      SET DEFAULT ROLE ims_app TO 'shopapp'@'%';
--
--  The last line matters: a granted role is inactive until it is activated for
--  the session, and SET DEFAULT ROLE does that automatically at login.
--
--  Idempotent: roles are dropped before creation.
-- =============================================================================

SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,'
                       'NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

USE inventory_order_management_sys;

DROP ROLE IF EXISTS ims_app, ims_maintenance, ims_readonly;
CREATE ROLE ims_app, ims_maintenance, ims_readonly;


-- =============================================================================
--  ims_app — the application
--
--  Writes NOTHING directly. Orders are placed by calling a procedure, and the
--  procedure runs with its DEFINER's privileges, so it can write tables the
--  caller cannot touch. That single fact is what lets the application have no
--  INSERT on orders, no INSERT on inventory_logs, and no UPDATE on products at
--  all, while still being able to place an order.
--
--  It also means rules I-02 and I-12 cannot be circumvented by the application
--  even in principle: the only way it can move stock is sp_place_order, which
--  validates every line first.
-- =============================================================================
GRANT EXECUTE ON PROCEDURE inventory_order_management_sys.sp_place_order     TO ims_app;
GRANT EXECUTE ON PROCEDURE inventory_order_management_sys.sp_cancel_order    TO ims_app;
GRANT EXECUTE ON PROCEDURE inventory_order_management_sys.sp_replenish_stock TO ims_app;

-- Reading is unrestricted; nothing here is sensitive within the application.
GRANT SELECT ON inventory_order_management_sys.* TO ims_app;

-- Customer registration and profile edits are ordinary DML, not a business
-- transaction, so they do not need a procedure.
GRANT INSERT ON inventory_order_management_sys.customers TO ims_app;

-- Column-level UPDATE: everything a customer may change about themselves, and
-- nothing else. tier_id is deliberately absent -- it is a cache maintained by
-- the T-05 trigger, and an application that could write it could silently
-- promote customers. Same reasoning as stock_quantity, applied to the other
-- cached value in the schema.
GRANT UPDATE (first_name, last_name, email, phone)
   ON inventory_order_management_sys.customers TO ims_app;


-- =============================================================================
--  ims_maintenance — back-office corrections
--
--  Direct DML, for the things no procedure covers: adding products, correcting
--  a price, retiring a line, recording a stock-take. Still cannot break the two
--  rules above.
-- =============================================================================
GRANT SELECT ON inventory_order_management_sys.* TO ims_maintenance;

GRANT INSERT ON inventory_order_management_sys.products       TO ims_maintenance;
GRANT INSERT ON inventory_order_management_sys.categories     TO ims_maintenance;
GRANT INSERT ON inventory_order_management_sys.customer_tiers TO ims_maintenance;
GRANT INSERT ON inventory_order_management_sys.discount_rules TO ims_maintenance;

-- rule I-02, enforced by privilege: every product column is writable EXCEPT
-- stock_quantity. A back-office user can correct a price, recategorise an item,
-- or retire it, but cannot move stock without leaving a ledger entry.
-- (product_id is omitted too: surrogate keys are immutable.)
GRANT UPDATE (category_id, sku, product_name, unit_price,
              reorder_level, target_stock_level, is_active)
   ON inventory_order_management_sys.products TO ims_maintenance;

GRANT UPDATE ON inventory_order_management_sys.categories     TO ims_maintenance;
GRANT UPDATE ON inventory_order_management_sys.customer_tiers TO ims_maintenance;
GRANT UPDATE ON inventory_order_management_sys.discount_rules TO ims_maintenance;

-- rule I-03, enforced by privilege: INSERT but never UPDATE or DELETE. This is
-- also the supported route for a stock-take -- insert an ADJUSTMENT movement and
-- let the trigger apply it.
GRANT SELECT, INSERT ON inventory_order_management_sys.inventory_logs TO ims_maintenance;

GRANT EXECUTE ON PROCEDURE inventory_order_management_sys.sp_replenish_stock TO ims_maintenance;


-- =============================================================================
--  ims_readonly — reporting and analytics
--  The views only. No base tables, so a report cannot be written against an
--  unmaintained assumption about raw columns.
-- =============================================================================
GRANT SELECT ON inventory_order_management_sys.vw_order_summary     TO ims_readonly;
GRANT SELECT ON inventory_order_management_sys.vw_low_stock         TO ims_readonly;
GRANT SELECT ON inventory_order_management_sys.vw_customer_spending TO ims_readonly;

-- The reconciliation suite: an auditor should be able to verify the caches
-- without being able to alter what they measure.
GRANT SELECT ON inventory_order_management_sys.rec_summary          TO ims_readonly;
GRANT SELECT ON inventory_order_management_sys.rec_stock_ledger     TO ims_readonly;
GRANT SELECT ON inventory_order_management_sys.rec_balance_chain    TO ims_readonly;
GRANT SELECT ON inventory_order_management_sys.rec_order_totals     TO ims_readonly;
GRANT SELECT ON inventory_order_management_sys.rec_orphan_orders    TO ims_readonly;
GRANT SELECT ON inventory_order_management_sys.rec_cancelled_stock  TO ims_readonly;
GRANT SELECT ON inventory_order_management_sys.rec_customer_tiers   TO ims_readonly;
GRANT SELECT ON inventory_order_management_sys.rec_tier_bands       TO ims_readonly;
GRANT SELECT ON inventory_order_management_sys.rec_discount_bands   TO ims_readonly;

FLUSH PRIVILEGES;


-- =============================================================================
--  What this does NOT protect against
--
--  None of this constrains the schema owner. root, and whoever the procedures
--  and triggers are DEFINEd as, can still drop a trigger or update stock
--  directly -- privileges bound accounts, not administrators.
--
--  That is not a flaw to be engineered away; it is where enforcement stops and
--  auditing begins. It is the reason rule I-08's reconciliation exists as a
--  measurement of the data rather than as an argument about the code: if an
--  administrator does bypass the ledger, rec_stock_ledger is what notices.
-- =============================================================================

SELECT 'ims_app'         AS role_name, GRANTEE FROM information_schema.user_privileges WHERE GRANTEE LIKE "'ims_app'%" LIMIT 1;

SHOW GRANTS FOR ims_app;
SHOW GRANTS FOR ims_maintenance;
SHOW GRANTS FOR ims_readonly;
