# Business Rules Catalogue

Every rule the system guarantees, with the single mechanism that owns it.

Governing principle:

> **Every invariant has exactly one owner.** Where two mechanisms enforce the same rule they
> either conflict or duplicate — and duplication in stock accounting produces silently wrong
> numbers rather than errors.

A second principle, applied consistently in Sections II and III:

> **Snapshot anything that can change.** A value that describes a past event must be stored
> on that event, never looked up live. Otherwise history silently rewrites itself when
> reference data changes.

## Enforcement legend

A distinction worth making explicitly, because it is often blurred:

| Type | Meaning | Bypassable by direct DML? |
|---|---|---|
| `CONSTRAINT` | Declaratively impossible to violate | No |
| `GENERATED` | Computed by the engine; cannot drift | No |
| `TRIGGER` | Enforced automatically on any DML | No |
| `PRIVILEGE` | Enforced by the grant system | No |
| `PROCEDURE` | Enforced inside the transaction boundary | **Yes** — hence never the sole owner of a correctness invariant |
| `VERIFIED` | Not expressible as a constraint; detected after the fact by a reconciliation query and covered by a test | n/a |

`VERIFIED` is not a weaker form of `CONSTRAINT` — it is the honest classification for rules
that span rows or tables in ways SQL cannot declare. Labelling them as such, rather than
implying they are enforced, is deliberate.

---

## Section I — Inventory movement

*Status: agreed 2026-07-26.*

| # | Rule | Owner | Type | Traces to |
|---|---|---|---|---|
| I-01 | Stock may never fall below zero | `UNSIGNED` + `CHECK (stock_quantity >= 0)`; `trg_inventory_logs_before_insert` rejects the movement first, with an error naming this rule | `CONSTRAINT` | Phase 2 |
| I-02 | Stock cannot change except by inserting into `inventory_logs` — the ledger insert applies the movement to `products` | `trg_inventory_logs_after_insert`, with `trg_products_before_insert` and `trg_products_before_update` as guards. See [ADR 0002](adr/0002-ledger-is-the-write-path.md) | `TRIGGER` | Phase 2 |
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

### Notes on contested rules

**I-02 — why the ledger is the write path, not the product row.**
The obvious design has the application update `products.stock_quantity` while a trigger records
what happened. It cannot work. A trigger sees only the row before and the row after, so a drop
from 100 to 88 is indistinguishable between a sale and a damaged-goods write-off — yet the
`movement_type` it must supply determines whether an `order_id` is *required* or *forbidden*
(`chk_inventory_logs_order_presence`). A wrong guess does not produce a slightly inaccurate audit
entry; it fails the customer's order.

Inverting the direction makes the intent part of the write. Stock is changed by inserting into
`inventory_logs`, and `trg_inventory_logs_after_insert` copies the resulting balance into
`products`. Two guards make that the only path: `trg_products_before_insert` rejects a product
created with opening stock, and `trg_products_before_update` rejects any direct write to
`stock_quantity`.

The binding consequence inverts too: **stored procedures insert into `inventory_logs` and never
update `products.stock_quantity` themselves.** A procedure that does both would double-count.
Full reasoning, and the two options rejected along the way, are in
[ADR 0002](adr/0002-ledger-is-the-write-path.md).

**I-08 — why this is verified rather than enforced.**
The rule compares a scalar column against an aggregate over another table. No `CHECK`
constraint can express that, and enforcing it by trigger would mean re-aggregating the
entire log on every write. The correct engineering answer is a reconciliation query run as a
test, not a constraint that cannot exist. I-07's `balance_after` gives a second, cheaper
check: the newest log row's `balance_after` must equal the product's current
`stock_quantity`.

Since [ADR 0002](adr/0002-ledger-is-the-write-path.md), `stock_quantity` is *copied* from
`balance_after` rather than calculated independently, so the two agree **by construction**. The
reconciliation query therefore verifies a structural property rather than hoping that two
separate calculations arrived at the same answer.

**I-12 — deviation from the source document.**
The source requirements do not state what happens when stock is insufficient. All-or-nothing
rejection was chosen over partial fulfilment: partial fills require line-level status,
complicate the order total, and imply a backorder concept the requirements never mention.

**I-13 — deviation from the source document.**
The requirements say *"any product with stock below its reorder point"* (strictly below).
This system triggers at **`<=`** — reaching the reorder level is itself the signal to
reorder, which is standard inventory practice. Recorded here because it is a deliberate
departure from the wording, not an off-by-one error.

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
Because stock is deducted at placement (I-12) and no reservation model exists, there is no
provisional state for an order to occupy — nothing about a placed order is pending. States
such as `SHIPPED` or `DELIVERED` would never be exercised by any procedure in this system,
and an unexercised lifecycle is decoration. `CANCELLED` exists solely because cancellation
must return stock.

**O-09 — why a generated column rather than a trigger.**
A detail row's three money columns are arithmetic on values in that same row, which makes them
the one set of derived values the engine can own outright. A `STORED` generated column
cannot drift: there is no trigger to write incorrectly and no reconciliation query needed.
Where the engine can enforce an invariant, it should. Contrast O-10, where the aggregate
spans rows and a trigger is unavoidable.

**O-13 — why a trigger rather than a `CHECK`.**
MySQL prohibits non-deterministic functions inside `CHECK` constraints, so
`CHECK (order_date <= NOW())` is rejected at DDL time. The rule remains enforceable, just
not declaratively. Documented because the choice looks arbitrary otherwise.

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

### Notes

**D-04 — resolving an ambiguity in the source document.**
The requirements say *"apply bulk discounts based on quantity ordered — if a customer orders
in large quantities"*, which admits two readings. Given a rule of *10+ units → 5% off* and an
order of 12 units of Product A plus 8 units of Product B:

- **Per line** (chosen): Product A qualifies at 12 units and is discounted; Product B does
  not qualify at 8 units and is charged in full.
- **Per order**: total quantity is 20, so every line including Product B is discounted.

Per line was chosen because bulk pricing reflects the packaging and handling economics of a
specific product. The per-order reading rewards large mixed baskets, which is a basket
promotion rather than a bulk discount.

**D-05 — why the applied percentage is stored.**
The same reasoning as O-08. If the line's discount were recomputed from `discount_rules` at
read time, every historical order would silently re-price whenever the discount bands were
edited. The rate actually granted is a fact about a past transaction and belongs on it.

**D-06 — why tiers are explicitly excluded from pricing.**
The source document uses tiers only for categorisation and spending reports (Phase 3,
Customer insights) and for automated categorisation (Phase 4). It never states that a
higher tier earns a discount. A tier-based discount was considered and rejected as scope
creep; this rule exists to record that the omission is intentional.

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

**T-05 / T-06 — the cache-and-reconcile pattern, applied a second time.**
Two designs were available. A pure view recomputes each customer's total from every order on
every read: always correct, but it re-aggregates the whole orders table each time — precisely
the cost Phase 5 asks us to eliminate. A stored column is instant to read but can drift out
of step with reality.

The chosen design keeps both: `customers.tier_id` is a **cache**, `vw_customer_spending` is
the **definition of truth**, and T-06 is the query that proves they agree. This is the same
structure as `products.stock_quantity` (cache) against `inventory_logs` (truth) with I-08 as
the proof. Reusing one pattern for both derived values is deliberate — it means the system
has one story about derived data rather than two.

It also satisfies both requirements at once: Phase 4's *"automate customer tier
categorization"* is the T-05 trigger, and Phase 5's concern for growth is the cached column.

**T-04 — the edge case that breaks naive implementations.**
A customer with no orders has no rows in `orders`, so an `INNER JOIN` drops them from the
tier report entirely. They must still resolve to the lowest tier, which requires both a
`LEFT JOIN` and a lowest band whose floor is 0.
