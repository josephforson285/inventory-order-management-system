# Business Rules Catalogue

Every rule the system guarantees, with the  mechanism that owns it.

 

## Enforcement legend

A distinction worth making explicitly.

| Type | Meaning | Bypassable by direct DML? |
|---|---|---|
| `CONSTRAINT` | Declaratively impossible to violate | No |
| `GENERATED` | Computed by the engine | No |
| `TRIGGER` | Enforced automatically on any DML | No |
| `PRIVILEGE` | Enforced by the grant system | No |
| `PROCEDURE` | Enforced inside the transaction boundary | **Yes** — hence never the sole owner of a correctness invariant |
| `VERIFIED` | Not expressible as a constraint; detected after the fact by a reconciliation query and covered by a test | n/a |

 

---

## Section I — Inventory movement

*Status: agreed 2026-07-26.*

| # | Rule | Owner | Type | Traces to |
|---|---|---|---|---|
| I-01 | Stock may never fall below zero | `UNSIGNED` + `CHECK (stock_quantity >= 0)`; `trg_inventory_logs_before_insert` rejects the movement first, with an error naming this rule | `CONSTRAINT` | Phase 2 |
| I-02 | Stock cannot change except by inserting into `inventory_logs` — the ledger insert applies the movement to `products` | `trg_inventory_logs_after_insert`, with `trg_products_before_insert` and `trg_products_before_update` as guards. | `TRIGGER` | Phase 2 |
| I-03 | `inventory_logs` is append-only | `BEFORE UPDATE` / `BEFORE DELETE` triggers that `SIGNAL`, plus revoked `UPDATE`/`DELETE` grants | `TRIGGER` + `PRIVILEGE` | Phase 2 |
| I-04 | Every log row carries a reason code | `movement_type NOT NULL ENUM('SALE','RETURN','REPLENISHMENT','ADJUSTMENT','CANCELLATION','INITIAL_LOAD')` | `CONSTRAINT` | Phase 2 |
| I-05 | The sign of `quantity_change` must agree with `movement_type` — a `SALE` cannot be positive, a `REPLENISHMENT` cannot be negative | `CHECK` with a `CASE` expression | `CONSTRAINT` | Phase 2 |
| I-06 | A movement of zero is invalid | `CHECK (quantity_change <> 0)` | `CONSTRAINT` | Phase 2 |
| I-07 | Each log row records the resulting balance, not only the delta | `balance_after`, computed by `trg_inventory_logs_before_insert` and then copied into `products` | `TRIGGER` | Phase 2 |
| I-08 | `products.stock_quantity` always equals `SUM(inventory_logs.quantity_change)` for that product | `sql/09_reconciliation.sql` + test | `VERIFIED` | Phase 2 |
| I-09 | A stock change and its log row commit or fail together | `ENGINE=InnoDB` + explicit transaction in the procedure | `CONSTRAINT` | Phase 2 |
| I-10 | Concurrent orders cannot oversell the same unit | `SELECT … FOR UPDATE` on the product rows, ordered by `product_id`; I-01 as backstop | `PROCEDURE` + `CONSTRAINT` | Phase 2 |
| I-11 | Cancelling an order returns its stock | `sp_cancel_order` reverses stock; the I-02 trigger logs it as `CANCELLATION` | `PROCEDURE` + `TRIGGER` | Phase 2 |
| I-12 | An order is rejected **in full** if any line has insufficient stock — no partial fulfilment | `sp_place_order` validates every line before any mutation, then `ROLLBACK` | `PROCEDURE` | Phase 2 |
| I-13 | Replenishment triggers when `stock_quantity <= reorder_level` and tops stock up to `target_stock_level` | `sp_replenish_stock`, scheduled by `EVENT` | `PROCEDURE` | Phase 4 |
| I-14 | `target_stock_level` must exceed `reorder_level` | `CHECK (target_stock_level > reorder_level)` | `CONSTRAINT` | Phase 4 |
| I-15 | No stock may exist without a corresponding log entry — opening stock is loaded as `INITIAL_LOAD` | `trg_products_before_insert` rejects any product created with non-zero stock | `TRIGGER` | Phase 2 |

---

## Section II — Order lifecycle

*Status: agreed 2026-07-26.*

| # | Rule | Owner | Type | Traces to |
|---|---|---|---|---|
| O-01 | An order must reference a valid customer | `FK … ON DELETE RESTRICT` | `CONSTRAINT` | Phase 1 |
| O-02 | An order must have at least one line | `sp_place_order` creates header and lines in one transaction; orphan-header query in reconciliation | `VERIFIED` | Phase 2 |
| O-03 | An order is either `PLACED` or `CANCELLED` — no other state exists | `status NOT NULL ENUM('PLACED','CANCELLED') DEFAULT 'PLACED'` | `CONSTRAINT` | Phase 2 |
| O-04 | Only a `PLACED` order can be cancelled; cancelling twice is an error | Guard in `sp_cancel_order` | `PROCEDURE` | Phase 2 |
| O-05 | Order lines are immutable once written | `BEFORE UPDATE` / `BEFORE DELETE` triggers that `SIGNAL` | `TRIGGER` | Phase 2 |
| O-06 | A product appears at most once per order | `UNIQUE (order_id, product_id)`; the procedure merges repeat quantities before insert | `CONSTRAINT` | Phase 2 |
| O-07 | Line quantity must be positive | `CHECK (quantity > 0)` | `CONSTRAINT` | Phase 2 |
| O-08 | `unit_price` is the product's price at the moment of sale, never joined live from `products` | `NOT NULL` column written by `sp_place_order` | `CONSTRAINT` | Phase 2 |
| O-09 | A detail row's `gross_amount`, `discount_amount`, and `net_amount` follow arithmetically from `quantity`, `unit_price`, and `discount_percent_applied` | `GENERATED ALWAYS AS (…) STORED` | `GENERATED` | Phase 2 |
| O-10 | Order gross, discount, and net totals are maintained from the order's lines | `AFTER INSERT` trigger on `order_details` | `TRIGGER` | Phase 4 |
| O-11 | `orders.net_amount` equals the sum of its lines' net amounts | Reconciliation query + test | `VERIFIED` | Phase 4 |
| O-12 | All monetary values are `DECIMAL(12,2)` — never `FLOAT` or `DOUBLE` | Column type | `CONSTRAINT` | Phase 1 |
| O-13 | `order_date` may not lie in the future | `BEFORE INSERT` trigger | `TRIGGER` | Phase 1 |

### Notes

**O-03 — why only two states.**
Because stock is deducted at placement (I-12) and no reservation model exists yet, there is no
provisional state for an order to occupy — nothing about a placed order is pending. States
such as `SHIPPED` or `DELIVERED` would never be exercised by any procedure in this system,
and an unexercised lifecycle is decoration. `CANCELLED` exists solely because cancellation
must return stock.


---

## Section III — Pricing and discounts

*Status: agreed 2026-07-26.*

| # | Rule | Owner | Type | Traces to |
|---|---|---|---|---|
| D-01 | Discount percentages lie between 0 and 100 | `CHECK (discount_percent BETWEEN 0 AND 100)` | `CONSTRAINT` | Phase 3 |
| D-02 | A bulk-discount band's lower bound is below its upper bound | `CHECK (min_quantity < max_quantity)` | `CONSTRAINT` | Phase 3 |
| D-03 | Bulk-discount bands neither overlap nor leave gaps | Overlap-detection query + test | `VERIFIED` | Phase 3 |
| D-04 | The bulk discount for a line is determined by **that line's own quantity**, not the order's total quantity | `sp_place_order` resolves each line against `discount_rules` independently | `PROCEDURE` | Phase 3 |
| D-05 | The discount percentage applied to a line is stored on the line | `order_details.discount_percent_applied NOT NULL` | `CONSTRAINT` | Phase 3 |
| D-06 | Customer tiers never affect price | No mechanism — enforced by omission; recorded so it is not added later | *(documented)* | Phase 3 |



---

## Section IV — Customer tiers

*Status: agreed 2026-07-26.*

| # | Rule | Owner | Type | Traces to |
|---|---|---|---|---|
| T-01 | A tier band's lower bound is below its upper bound, and bands neither overlap nor leave gaps | `CHECK` + overlap-detection query | `CONSTRAINT` + `VERIFIED` | Phase 3 |
| T-02 | Lifetime spend is the sum of `net_amount` across a customer's non-cancelled orders | `vw_customer_spending` definition | *(definition)* | Phase 3 |
| T-03 | Cancelled orders are excluded from lifetime spend | `WHERE status <> 'CANCELLED'` in `vw_customer_spending` | `VERIFIED` | Phase 3 |
| T-04 | Every customer holds a tier, including one who has never ordered | Lowest band starts at 0; the view uses `LEFT JOIN` so zero-spend customers still resolve | `CONSTRAINT` | Phase 3 |
| T-05 | `customers.tier_id` is recalculated automatically when an order is placed or cancelled | `AFTER INSERT` / `AFTER UPDATE` trigger on `orders` | `TRIGGER` | Phase 4 |
| T-06 | `customers.tier_id` always agrees with the tier implied by `vw_customer_spending` | Reconciliation query + test | `VERIFIED` | Phase 4 |

### Notes


