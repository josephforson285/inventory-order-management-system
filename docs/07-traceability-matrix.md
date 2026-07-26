# Traceability Matrix

Each of the 40 rules in the [business rules catalogue](02-business-rules.md) mapped to the
database object that owns it. This is the bridge between the analysis and the implementation:
a rule with no object is unimplemented, and an object serving no rule is unjustified.

**Legend:** ✅ implemented and verified · ◐ partially implemented · ○ designed, not yet built

Every constraint, trigger, and routine name below is the real identifier in the schema, not a
description. Objects are explicitly named precisely so that a violation reports which business
rule it broke — `Rule I-03: inventory_logs is append-only` rather than `products_chk_2`.

---

## Section I — Inventory movement

| Rule | Object | Type | File | Status |
|---|---|---|---|---|
| I-01 | `INT UNSIGNED` + `chk_products_stock_non_negative` + `STRICT_TRANS_TABLES`; `trg_inventory_logs_before_insert` rejects the movement first with a rule-named error | `CONSTRAINT` + `TRIGGER` | `01_schema.sql` / `02_triggers.sql` | ✅ |
| I-02 | `trg_inventory_logs_after_insert`, guarded by `trg_products_before_insert` and `trg_products_before_update` — see [ADR 0002](adr/0002-ledger-is-the-write-path.md) | `TRIGGER` | `02_triggers.sql` | ✅ |
| I-03 | `trg_inventory_logs_before_update`, `trg_inventory_logs_before_delete` | `TRIGGER` | `02_triggers.sql` | ◐ |
| I-04 | `inventory_logs.movement_type NOT NULL ENUM` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| I-05 | `chk_inventory_logs_sign_matches_type` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| I-06 | `chk_inventory_logs_change_non_zero` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| I-07 | `balance_after`, computed by `trg_inventory_logs_before_insert` and copied into `products` | `TRIGGER` | `02_triggers.sql` | ✅ |
| I-08 | Asserted in `tests/04_procedures_test.sql` (every product, diff 0); reusable `rec_stock_ledger` still to come | `VERIFIED` | `09_reconciliation.sql` | ◐ |
| I-09 | `ENGINE=InnoDB` + explicit `START TRANSACTION` / `ROLLBACK` in `sp_place_order` | `CONSTRAINT` | `01_schema.sql` / `04_procedures.sql` | ✅ |
| I-10 | `SELECT … FOR UPDATE` in `trg_inventory_logs_before_insert` (any caller); explicit cursor loop in ascending `product_id` order in `sp_place_order` and `sp_cancel_order` (deadlock avoidance) | `PROCEDURE` + `TRIGGER` | `02_triggers.sql` / `04_procedures.sql` | ✅ |
| I-11 | `sp_cancel_order` writes `CANCELLATION` movements; stock returns via the ledger | `PROCEDURE` | `04_procedures.sql` | ✅ |
| I-12 | `sp_place_order` locks, validates every line, then writes — nothing mutates until all lines are satisfiable | `PROCEDURE` | `04_procedures.sql` | ✅ |
| I-13 | `sp_replenish_stock` tops up to `target_stock_level`; scheduling awaits `ev_replenish_stock` | `PROCEDURE` | `04_procedures.sql` / `06_events.sql` | ◐ |
| I-14 | `chk_products_target_above_reorder` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| I-15 | `trg_products_before_insert` — a product cannot be created holding stock | `TRIGGER` | `02_triggers.sql` | ✅ |

**I-03 is partial by design.** The triggers are in place and tested, but a trigger does not
constrain a sufficiently privileged user. The second half — revoking `UPDATE` and `DELETE` on
`inventory_logs`, and column-level `UPDATE` on `products.stock_quantity` — lives in
`10_grants.sql`.

## Section II — Order lifecycle

| Rule | Object | Type | File | Status |
|---|---|---|---|---|
| O-01 | `fk_orders_customers` (`ON DELETE RESTRICT`) | `CONSTRAINT` | `01_schema.sql` | ✅ |
| O-02 | `sp_place_order` writes header and details atomically; `rec_orphan_orders` detects violations | `VERIFIED` | `04_procedures.sql` / `09_reconciliation.sql` | ◐ |
| O-03 | `orders.status ENUM('PLACED','CANCELLED')` + `chk_orders_cancelled_at_consistent` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| O-04 | `sp_cancel_order` rejects any order not in `PLACED` | `PROCEDURE` | `04_procedures.sql` | ✅ |
| O-05 | `trg_order_details_before_update`, `trg_order_details_before_delete` | `TRIGGER` | `02_triggers.sql` | ✅ |
| O-06 | `uq_order_details_order_product`; `sp_place_order` merges repeat products with `GROUP BY` before insert | `CONSTRAINT` | `01_schema.sql` / `04_procedures.sql` | ✅ |
| O-07 | `chk_order_details_quantity_positive` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| O-08 | `order_details.unit_price NOT NULL`, snapshotted from `products` by `sp_place_order` | `CONSTRAINT` | `01_schema.sql` / `04_procedures.sql` | ✅ |
| O-09 | `gross_amount`, `discount_amount`, `net_amount` as `STORED` generated columns | `GENERATED` | `01_schema.sql` | ✅ |
| O-10 | `trg_order_details_after_insert` — incremental, since details are immutable | `TRIGGER` | `02_triggers.sql` | ✅ |
| O-11 | Asserted in `tests/04_procedures_test.sql` (every order, diff 0.00); reusable `rec_order_totals` still to come | `VERIFIED` | `09_reconciliation.sql` | ◐ |
| O-12 | `DECIMAL(12,2)` / `DECIMAL(14,2)` throughout | `CONSTRAINT` | `01_schema.sql` | ✅ |
| O-13 | `trg_orders_before_insert` — a trigger because MySQL forbids `NOW()` in a `CHECK` | `TRIGGER` | `02_triggers.sql` | ✅ |

## Section III — Pricing and discounts

| Rule | Object | Type | File | Status |
|---|---|---|---|---|
| D-01 | `chk_discount_rules_percent` + `chk_order_details_discount_percent` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| D-02 | `chk_discount_rules_band` | `CONSTRAINT` | `01_schema.sql` | ✅ |
| D-03 | `uq_discount_rules_min_quantity` rules out shared floors; band-tiling checks in `03_reference_data.sql`; `rec_discount_bands` still to come | `VERIFIED` | `01_schema.sql` / `03_reference_data.sql` / `09_reconciliation.sql` | ◐ |
| D-04 | `sp_place_order` resolves each detail row against `discount_rules` from that row's own quantity, highest matching band first | `PROCEDURE` | `04_procedures.sql` | ✅ |
| D-05 | `order_details.discount_percent_applied` + `discount_rule_id`, both written by `sp_place_order` | `CONSTRAINT` | `01_schema.sql` / `04_procedures.sql` | ✅ |
| D-06 | **No object** — enforced by omission, recorded so it is not added later | *(documented)* | `02-business-rules.md` | ✅ |

D-06 is the only rule in the matrix deliberately without an implementing object. Tiers do not
affect price, so the correct implementation is the absence of one. It appears here because an
absence that is not written down is indistinguishable from an oversight.

## Section IV — Customer tiers

| Rule | Object | Type | File | Status |
|---|---|---|---|---|
| T-01 | `chk_customer_tiers_band` + `uq_customer_tiers_min_spend`; `sp_refresh_customer_tier` raises on a gap at runtime; `rec_tier_bands` still to come | `CONSTRAINT` + `VERIFIED` | `01_schema.sql` / `02_triggers.sql` / `09_reconciliation.sql` | ◐ |
| T-02 | `vw_customer_spending` is the definition; `sp_refresh_customer_tier` applies the same calculation | *(view definition)* | `05_views.sql` / `02_triggers.sql` | ✅ |
| T-03 | `o.status <> 'CANCELLED'` in the LEFT JOIN's **ON** clause of `vw_customer_spending` (in WHERE it would drop zero-spend customers entirely), and in `sp_refresh_customer_tier` | `VERIFIED` | `05_views.sql` / `02_triggers.sql` | ✅ |
| T-04 | Lowest band seeded at `min_spend = 0` in `03_reference_data.sql`; `COALESCE(SUM(...), 0)` in `sp_refresh_customer_tier` resolves a zero-spend customer | `CONSTRAINT` | `03_reference_data.sql` / `02_triggers.sql` | ✅ |
| T-05 | `trg_orders_after_insert`, `trg_orders_after_update`, both calling `sp_refresh_customer_tier` | `TRIGGER` | `02_triggers.sql` | ✅ |
| T-06 | `vw_customer_spending.tier_is_current` exposes the comparison directly; asserted in `tests/05_views_test.sql`. Reusable `rec_customer_tiers` still to come | `VERIFIED` | `05_views.sql` / `09_reconciliation.sql` | ◐ |

**On T-05's cascade.** When an order header is inserted its totals are still zero, so the tier
refresh at that moment is a no-op. The refresh that matters is triggered indirectly: inserting an
order detail updates the order's totals, and that update fires `trg_orders_after_update`, which
recalculates the tier against real figures. Three levels of trigger, verified end to end — a
customer was promoted to Silver at a spend of 2,996.40 and demoted to Bronze when the order was
cancelled.

---

## Coverage summary

| Status | Count |
|---|---|
| ✅ Implemented and verified | 32 |
| ◐ Partially implemented | 8 |
| ○ Designed, not yet built | 0 |
| **Total** | **40** |

Every rule has a named owner. Nothing is unassigned, and no object exists without a rule to
justify it.

**Every rule now has a working implementation.** The 32 complete rules cover everything
enforceable declaratively — constraints, types, generated columns — plus the entire trigger,
stored-procedure, and view layer.

The 8 partial rules are each waiting on exactly one artefact:

| Waiting on | Rules |
|---|---|
| A privilege grant (`10_grants.sql`) | I-03 |
| A scheduled event (`06_events.sql`) | I-13 |
| A reusable reconciliation query (`09_reconciliation.sql`) | I-08, O-02, O-11, D-03, T-01, T-06 |

Every one of those six reconciliation rules is already *asserted by a test* and passing. What is
missing is a named query a reviewer can run on demand — a real gap, but a narrower one than
"unimplemented".

## Enforcement mix

| Type | Rules |
|---|---|
| `CONSTRAINT` | 17 |
| `TRIGGER` | 8 |
| `PROCEDURE` | 6 |
| `VERIFIED` | 6 |
| `GENERATED` | 1 |
| *(view definition)* | 1 |
| *(documented only)* | 1 |

The shape of this distribution is itself a design statement. Constraints outnumber procedures
close to three to one, meaning most guarantees are **impossible to violate** rather than merely
*enforced by code that happens to run*. The six procedure-owned rules are exactly the ones that
genuinely need transactional logic — deterministic lock ordering, validating every line before
writing any, all-or-nothing rollback, and resolving a discount band per row. Nothing a constraint
or trigger could hold was left to a procedure.

The 6 `VERIFIED` rules are the honest residue: cross-table aggregates that no constraint can
express. Each gets a reconciliation query and a test rather than a claim. One of them, I-08, is
additionally true *by construction* since [ADR 0002](adr/0002-ledger-is-the-write-path.md) —
`stock_quantity` is copied from `balance_after` rather than calculated separately, so the query
verifies a structural property instead of reconciling two independent computations.
