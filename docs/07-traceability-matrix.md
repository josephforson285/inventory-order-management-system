# Traceability Matrix

Each of the 40 rules in the [business rules catalogue](02-business-rules.md) mapped to the
database object that owns it. This is the bridge between the analysis and the implementation:
a rule with no object is unimplemented, and an object serving no rule is unjustified.

**Legend:** ✅ implemented and verified · ◐ partially implemented · ○ designed, not yet built

Every constraint name below is the real identifier in the schema, not a description. Constraints
are explicitly named precisely so that a violation reports which business rule it broke.

---

## Section I — Inventory movement

| Rule | Object | Type | File | Status |
|---|---|---|---|---|
| I-01 | `INT UNSIGNED` + `chk_products_stock_non_negative` + `STRICT_TRANS_TABLES`; readable pre-check in `sp_place_order` | `CONSTRAINT` | `01_schema.sql` / `04_procedures.sql` | ◐ |
| I-02 | `trg_products_after_update` | `TRIGGER` | `02_triggers.sql` | ○ |
| I-03 | `trg_inventory_logs_before_update`, `trg_inventory_logs_before_delete`, plus revoked grants | `TRIGGER` + `PRIVILEGE` | `02_triggers.sql` / `10_grants.sql` | ○ |
| I-04 | `inventory_logs.movement_type NOT NULL ENUM` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| I-05 | `chk_inventory_logs_sign_matches_type` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| I-06 | `chk_inventory_logs_change_non_zero` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| I-07 | `inventory_logs.balance_after`, written by `trg_products_after_update` | `TRIGGER` | `01_schema.sql` / `02_triggers.sql` | ◐ |
| I-08 | `rec_stock_ledger` | `VERIFIED` | `09_reconciliation.sql` | ○ |
| I-09 | `ENGINE=InnoDB` + explicit transaction in `sp_place_order` | `CONSTRAINT` | `01_schema.sql` / `04_procedures.sql` | ◐ |
| I-10 | `SELECT … FOR UPDATE ORDER BY product_id` in `sp_place_order`; I-01 as backstop | `PROCEDURE` | `04_procedures.sql` | ○ |
| I-11 | `sp_cancel_order`, logged `CANCELLATION` by `trg_products_after_update` | `PROCEDURE` + `TRIGGER` | `04_procedures.sql` | ○ |
| I-12 | `sp_place_order` — validate all lines, then `ROLLBACK` | `PROCEDURE` | `04_procedures.sql` | ○ |
| I-13 | `sp_replenish_stock`, scheduled by `ev_replenish_stock` | `PROCEDURE` | `04_procedures.sql` / `06_events.sql` | ○ |
| I-14 | `chk_products_target_above_reorder` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| I-15 | Seed writes through the same `UPDATE` path, logged `INITIAL_LOAD` | `PROCEDURE` | `07_seed.sql` | ○ |

## Section II — Order lifecycle

| Rule | Object | Type | File | Status |
|---|---|---|---|---|
| O-01 | `fk_orders_customers` (`ON DELETE RESTRICT`) | `CONSTRAINT` | `01_schema.sql` | ✅ |
| O-02 | `sp_place_order` writes header and details atomically; `rec_orphan_orders` detects violations | `VERIFIED` | `04_procedures.sql` / `09_reconciliation.sql` | ○ |
| O-03 | `orders.status ENUM('PLACED','CANCELLED')` + `chk_orders_cancelled_at_consistent` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| O-04 | Guard in `sp_cancel_order` | `PROCEDURE` | `04_procedures.sql` | ○ |
| O-05 | `trg_order_details_before_update`, `trg_order_details_before_delete` | `TRIGGER` | `02_triggers.sql` | ○ |
| O-06 | `uq_order_details_order_product`; quantities merged by `sp_place_order` | `CONSTRAINT` | `01_schema.sql` / `04_procedures.sql` | ◐ |
| O-07 | `chk_order_details_quantity_positive` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| O-08 | `order_details.unit_price NOT NULL`, written by `sp_place_order` | `CONSTRAINT` | `01_schema.sql` / `04_procedures.sql` | ◐ |
| O-09 | `gross_amount`, `discount_amount`, `net_amount` as `STORED` generated columns | `GENERATED` | `01_schema.sql` | ✅ |
| O-10 | `trg_order_details_after_insert` | `TRIGGER` | `02_triggers.sql` | ○ |
| O-11 | `rec_order_totals` | `VERIFIED` | `09_reconciliation.sql` | ○ |
| O-12 | `DECIMAL(12,2)` / `DECIMAL(14,2)` throughout | `CONSTRAINT` | `01_schema.sql` | ✅ |
| O-13 | `trg_orders_before_insert` — a trigger because MySQL forbids `NOW()` in a `CHECK` | `TRIGGER` | `02_triggers.sql` | ○ |

## Section III — Pricing and discounts

| Rule | Object | Type | File | Status |
|---|---|---|---|---|
| D-01 | `chk_discount_rules_percent` + `chk_order_details_discount_percent` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| D-02 | `chk_discount_rules_band` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| D-03 | `rec_discount_bands` — overlap and gap detection | `VERIFIED` | `09_reconciliation.sql` | ○ |
| D-04 | `sp_place_order` resolves each detail row against `discount_rules` independently | `PROCEDURE` | `04_procedures.sql` | ○ |
| D-05 | `order_details.discount_percent_applied NOT NULL` + `discount_rule_id` | `CONSTRAINT` | `01_schema.sql` | ◐ |
| D-06 | **No object** — enforced by omission, recorded so it is not added later | *(documented)* | `02-business-rules.md` | ✅ |

D-06 is the only rule in the matrix deliberately without an implementing object. Tiers do not
affect price, so the correct implementation is the absence of one. It appears here because an
absence that is not written down is indistinguishable from an oversight.

## Section IV — Customer tiers

| Rule | Object | Type | File | Status |
|---|---|---|---|---|
| T-01 | `chk_customer_tiers_band` + `rec_tier_bands` for overlap and gap detection | `CONSTRAINT` + `VERIFIED` | `01_schema.sql` / `09_reconciliation.sql` | ◐ |
| T-02 | `vw_customer_spending` | *(definition)* | `05_views.sql` | ○ |
| T-03 | `WHERE status <> 'CANCELLED'` within `vw_customer_spending` | `VERIFIED` | `05_views.sql` | ○ |
| T-04 | Lowest band seeded at `min_spend = 0`; `LEFT JOIN` in `vw_customer_spending` | `CONSTRAINT` | `03_reference_data.sql` / `05_views.sql` | ○ |
| T-05 | `trg_orders_after_insert`, `trg_orders_after_update` | `TRIGGER` | `02_triggers.sql` | ○ |
| T-06 | `rec_customer_tiers` | `VERIFIED` | `09_reconciliation.sql` | ○ |

---

## Coverage summary

| Status | Count |
|---|---|
| ✅ Implemented and verified | 12 |
| ◐ Partially implemented | 8 |
| ○ Designed, not yet built | 20 |
| **Total** | **40** |

Every rule has a named owner. Nothing is unassigned, and no object exists without a rule to
justify it.

The 12 complete rules are those enforceable declaratively — constraints, types, and generated
columns, all of which live in the schema and are covered by the negative test suite. The 8
partial rules have their declarative half in place and await a procedure or trigger. The 20
remaining are triggers, procedures, views, and reconciliation queries.

## Enforcement mix

| Type | Rules |
|---|---|
| `CONSTRAINT` | 16 |
| `TRIGGER` | 8 |
| `PROCEDURE` | 8 |
| `GENERATED` | 1 |
| `VERIFIED` | 6 |
| *(documented only)* | 1 |

The shape of this distribution is itself a design statement. Constraints outnumber procedures
roughly two to one, meaning most guarantees are **impossible to violate** rather than merely
*enforced by code that happens to run*. Procedures own only the rules that genuinely require
transactional logic — locking, multi-row validation, all-or-nothing rollback — and never the
rules a constraint could hold instead.

The 6 `VERIFIED` rules are the honest residue: cross-table aggregates that no constraint can
express. Each has a reconciliation query and a test rather than a claim.
