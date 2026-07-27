# Physical Design

Where the [logical model](04-logical-model.md) decided *what* is stored, this document decides
*how* — engine, character set, exact types, and the index strategy. Every index here is
justified by a query the [requirements](00-requirements.md) actually ask for; none is added
speculatively.

The [entity relationship diagram](03-conceptual-model.md#diagram) shows the eight tables, their
columns, and the eight foreign keys between them.

---

## 1. Target environment

Captured from the development server rather than assumed:

| Setting | Value | Consequence for this design |
|---|---|---|
| Version | `8.4.10` (Ubuntu 26.04) | `CHECK` constraints, functional indexes, and window functions are all available |
| `sql_mode` | `ONLY_FULL_GROUP_BY, STRICT_TRANS_TABLES, NO_ZERO_IN_DATE, NO_ZERO_DATE, ERROR_FOR_DIVISION_BY_ZERO, NO_ENGINE_SUBSTITUTION` | **Load-bearing — see §7** |
| Default engine | `InnoDB` | Matches our requirement; no override needed |
| Server charset | `utf8mb4` | Matches our requirement |
| Server collation | `utf8mb4_0900_ai_ci` | Accent- and case-insensitive; see §3 |
| `event_scheduler` | `ON` | Required for rule I-13's scheduled replenishment. Confirmed available |
| Row format | `dynamic` | InnoDB default; appropriate for variable-length `VARCHAR` |
| Isolation | `REPEATABLE-READ` | Relevant to rule I-10; see §6 |
| Time zone | `SYSTEM` → `CAT` | See §4 on `DATETIME` |

`event_scheduler = ON` is worth verifying before designing around it. Had it been `OFF`,
rule I-13's automation would need a different mechanism, and discovering that after writing
the procedure would be wasted work.

## 2. Database and naming conventions

Database: **`inventory_order_management_sys`**. Named distinctly so it cannot collide with the
pre-existing `inventory_order_management` schema on this server.

| Object | Convention | Example |
|---|---|---|
| Table | plural, `snake_case` | `order_details` |
| Column | singular, `snake_case` | `unit_price` |
| Primary key | `<singular_table>_id` | `order_detail_id` |
| Foreign key constraint | `fk_<child>_<parent>` | `fk_order_details_products` |
| Unique constraint | `uq_<table>_<columns>` | `uq_order_details_order_product` |
| Check constraint | `chk_<table>_<rule>` | `chk_products_stock_non_negative` |
| Index | `idx_<table>_<columns>` | `idx_orders_customer_date` |
| View | `vw_<subject>` | `vw_customer_spending` |
| Procedure | `sp_<verb>_<subject>` | `sp_place_order` |
| Trigger | `trg_<table>_<timing><event>` | `trg_products_after_update` |
| Event | `ev_<verb>_<subject>` | `ev_replenish_stock` |

Every constraint is **explicitly named**. MySQL will auto-generate names otherwise, and
auto-generated names appear in error messages — a constraint violation that reports
`chk_products_stock_non_negative` tells the reader which rule fired; one that reports
`products_chk_2` does not.

## 3. Engine, character set, collation

**`ENGINE=InnoDB`** — not the default-by-accident, but required by three rules:

- Rule I-09 needs transactions so a stock change and its log row commit together
- Rule I-10 needs row-level locking for `SELECT … FOR UPDATE`
- Rules O-01 and the `ON DELETE RESTRICT` policy need real foreign key enforcement

MyISAM offers none of these; it would silently accept every one of these constructs and
enforce nothing.

**`CHARSET=utf8mb4`** — the only correct choice. MySQL's legacy `utf8` is a three-byte
encoding that cannot represent characters outside the Basic Multilingual Plane, so it truncates
on any four-byte character. `utf8mb4` is genuine UTF-8.

**`COLLATE=utf8mb4_0900_ai_ci`** — case- and accent-insensitive, which is deliberate for the
unique constraints:

- `customers.email` — `Joseph@Example.com` and `joseph@example.com` must collide, because they
  are the same mailbox. A case-*sensitive* collation would permit both rows and create a
  duplicate customer.
- `categories.category_name` — `Electronics` and `electronics` must collide, or the category
  list fragments.

This is a case where the insensitive default is not laziness but the required behaviour.

## 4. Data type decisions

### Money — `DECIMAL`, never floating point

All monetary columns are `DECIMAL(12,2)`; the derived per-row amounts on `order_details` widen
to `DECIMAL(14,2)` to accommodate `quantity × unit_price` without overflow.

`FLOAT` and `DOUBLE` are binary approximations: `0.1 + 0.2` is not `0.3`, and a `SUM` over
300,000 rows accumulates that error. Rule O-11 requires `orders.net_amount` to equal the sum of
its details **exactly**, which is only achievable with exact-precision arithmetic. This is not a
performance trade-off — it is the difference between the reconciliation passing and failing.

`DECIMAL(12,2)` accommodates values up to 9,999,999,999.99.

### Integers and key width — a revision from the logical model

The logical model marked `order_id`, `order_detail_id`, and `log_id` as `BIGINT UNSIGNED`. That
is revised here to **`INT UNSIGNED`**, and the reasoning matters:

In InnoDB the primary key is **clustered**, and every secondary index entry stores the primary
key as its row pointer. An oversized primary key therefore inflates not just the table but
*every index on it*. Choosing `BIGINT` over `INT` costs four bytes per row **plus** four bytes
per entry in every secondary index.

`INT UNSIGNED` ceilings at 4,294,967,295 rows. Against the seed volumes below — and even at
100,000 orders per year, indefinitely — that is not a limit this system will approach.

| Table | Type | Ceiling | Actual seeded rows | Rationale |
|---|---|---|---|---|
| `customer_tiers` | `TINYINT UNSIGNED` | 255 | 3 | Three tiers; 255 is already generous |
| `categories` | `SMALLINT UNSIGNED` | 65,535 | 8 | |
| `discount_rules` | `SMALLINT UNSIGNED` | 65,535 | 3 | |
| `products` | `INT UNSIGNED` | 4.29 bn | 500 | |
| `customers` | `INT UNSIGNED` | 4.29 bn | 10,000 | |
| `orders` | `INT UNSIGNED` | 4.29 bn | 100,000 | |
| `order_details` | `INT UNSIGNED` | 4.29 bn | 250,000 | 2.5 details per order |
| `inventory_logs` | `INT UNSIGNED` | 4.29 bn | 250,513 | Fastest-growing table; append-only, never purged |

`inventory_logs` is the one to watch, since it is never pruned. The seed produced 250,513 rows
for 100,000 orders — roughly 2.5 movements per order — so at that rate `INT UNSIGNED` gives some
seventeen thousand years of headroom. If that assumption ever changes, the migration path is
a single `ALTER TABLE` — deferring it costs nothing today, whereas over-sizing every index
costs something on every write forever.

Reference-table keys are sized down for the same reason in reverse: `customers.tier_id` as
`TINYINT` rather than `INT` saves three bytes on every one of 10,000 customer rows and in every
index containing it.

**`quantity_change` is the sole signed integer** in the schema (`INT`, not `INT UNSIGNED`).
Negative means stock out, positive means stock in. This is what allows rule I-08 to be a single
`SUM` rather than a conditional aggregation.

### Dates — `DATETIME`, not `TIMESTAMP`

`DATETIME` throughout, with `DEFAULT CURRENT_TIMESTAMP` where appropriate.

`TIMESTAMP` has two properties that disqualify it here: it stores as a Unix epoch value and
therefore **ends in 2038**, and it silently converts between the session and server time zones
on read and write. This server reports `time_zone = SYSTEM` resolving to `CAT`, so a client
connecting from a different zone would read back different values than were written.
`DATETIME` stores exactly what it is given, which is what an audit trail requires.

The trade-off is that `DATETIME` carries no zone information, so it is a convention rather than
a guarantee that all values are server-local. Recorded here as an assumption.

### `ENUM` versus lookup tables

`orders.status` and `inventory_logs.movement_type` are `ENUM`. Internally MySQL stores these as
integers, so they cost one or two bytes and read like text — cheaper than a join to a lookup
table.

The cost is that adding a value requires `ALTER TABLE`. That is acceptable for these two
columns because their value sets are closed by design: rule O-03 fixes the order states at two,
and the six movement types enumerate every way stock can move. Contrast `customer_tiers` and
`discount_rules`, which are lookup **tables** precisely because their contents are expected to
change — that was the whole argument for holding business rules as data.

## 5. Index strategy

Every index is derived from a query the requirements demand. The queries first:

| # | Query | Phase |
|---|---|---|
| Q1 | Order summary per customer — date, total, item count | 3 |
| Q2 | Products at or below reorder level | 3 |
| Q3 | Lifetime spend per customer, excluding cancelled orders | 3 |
| Q4 | Full stock movement history for one product, chronological | 2 |
| Q5 | Reconciliation — `SUM(quantity_change)` per product | 2 |
| Q6 | Discount given, grouped by rule | 3 |
| Q7 | Units sold per product | 3 |

### The resulting indexes

| Table | Index | Serves | Note |
|---|---|---|---|
| `products` | `uq_products_sku` | Lookup by SKU | Natural key |
| `products` | `idx_products_category` | Category reports | FK requirement |
| `products` | `idx_products_needs_reorder` | **Q2** | See §5.1 |
| `customers` | `uq_customers_email` | Login/lookup | Natural key |
| `customers` | `idx_customers_tier` | Tier reports | FK requirement |
| `orders` | `idx_orders_customer_date` | **Q1** | `(customer_id, order_date)` |
| `orders` | `idx_orders_customer_status_net` | **Q3** | `(customer_id, status, net_amount)` — covering |
| `order_details` | `uq_order_details_order_product` | Rule O-06, **and** the FK index on `order_id` | `(order_id, product_id)` |
| `order_details` | `idx_order_details_product_qty` | **Q7** | `(product_id, quantity)` — covering |
| `order_details` | `idx_order_details_discount_rule` | **Q6** | FK requirement |
| `inventory_logs` | `idx_inventory_logs_product_time_qty` | **Q4 and Q5** | `(product_id, created_at, quantity_change)` |
| `inventory_logs` | `idx_inventory_logs_order` | Movement → order lineage | FK requirement |

Three of these deserve explanation.

**`uq_order_details_order_product` does double duty.** MySQL requires an index on every foreign
key column and silently creates one if absent. Because this unique constraint leads with
`order_id`, the leftmost-prefix rule means it already satisfies the foreign key's index
requirement — so no separate `idx_order_details_order` is created. Letting MySQL auto-create
one would have produced a redundant index that costs write throughput and returns nothing.

**`idx_orders_customer_status_net` is a covering index.** Q3 filters on `customer_id` and
`status`, then sums `net_amount`. With all three columns in the index, the aggregate is answered
from the index alone without touching a single table row. On 100,000 orders this is the
difference between reading an index range and reading the table. Column order follows the
standard rule: equality predicates first, the aggregated column last.

**`idx_inventory_logs_product_time_qty` deliberately consolidates two indexes into one.** Q4
wants a product's movements in time order — `(product_id, created_at)`. Q5 wants
`SUM(quantity_change)` per product — `(product_id, quantity_change)`. Rather than create two
indexes both leading with `product_id`, appending the third column serves both: Q4 uses the
first two parts for its range and ordering, and Q5 reads all three index-only. One index, two
queries, half the write cost.

### 5.1 The low-stock query needs a column that does not exist

Q2 is *"products where `stock_quantity <= reorder_level`"* — a comparison **between two
columns**. No conventional index can serve it. An index on `stock_quantity` is useless, because
the threshold differs for every row; the optimiser has no choice but a full table scan.

Two solutions exist in MySQL 8:

1. A **functional index** on the expression: `INDEX ((stock_quantity <= reorder_level))`
2. A **generated column** holding the comparison, with an ordinary index on it

This design takes the second, adding to `products`:

```sql
needs_reorder BOOLEAN
  GENERATED ALWAYS AS (stock_quantity <= reorder_level) VIRTUAL
```

Three reasons for preferring it over the functional index:

- **The requirements literally ask for a flag.** Phase 3 says any product below its reorder
  point *"should be flagged"*. A column named `needs_reorder` **is** that flag, readable
  directly in the low-stock view rather than reconstructed by each query.
- **A functional index only helps when the query's expression matches the index's exactly.**
  A column is used by any query that mentions it, which is far less brittle.
- **`VIRTUAL` costs no row storage.** The value is computed on read and materialised only
  inside the index — so we get the index without widening every row.

**Why an index on a boolean is justified here**, when low-cardinality indexes are usually
worthless: an index is valuable when the *value being searched for* is rare, not when the
column has many distinct values. A healthy inventory has few products below reorder level — the
`TRUE` set is a small fraction of the table, which is exactly the case where the optimiser will
choose the index. If the business ever let most of its catalogue run low, this index would stop
being used, and that would be the least of the company's problems.

### 5.2 Deliberately not indexed

Restraint is part of the strategy. Every index slows every write and consumes space, so the
following are left out — recorded so their absence reads as a decision:

| Not indexed | Why |
|---|---|
| `orders.order_date` alone | No requirement asks for cross-customer date-range reporting. A candidate to add when a query needs it — measured, not guessed |
| `orders.status` alone | `CANCELLED` is rare, so an index would be selective — but no required query filters on status alone |
| `customers.last_name` | Q1 displays customer names but joins by `customer_id`. Indexing for a display column serves nothing |
| `discount_rules`, `customer_tiers`, `categories` beyond their keys | 3–20 rows each. A full scan of 4 rows is faster than any index lookup; InnoDB will read the single page either way |
| `inventory_logs.movement_type` | *"All replenishments last month"* is plausible but not required. Deferred |
| `products.is_active` | Two values, and most products are active — the searched-for value is the common one, so an index would be ignored |

The two entries about *rare versus common values* are the same principle applied in opposite
directions: `needs_reorder` gets an index because `TRUE` is rare; `is_active` does not, because
`TRUE` is almost everything.

## 6. Concurrency and locking

Rule I-10 requires that two simultaneous orders cannot both sell the last unit. The server runs
`REPEATABLE-READ`, under which a plain `SELECT` takes no locks — so reading stock, deciding it
is sufficient, and then updating is a race. Two sessions can both read `stock_quantity = 1` and
both proceed.

`sp_place_order` therefore takes explicit row locks:

```sql
SELECT stock_quantity FROM products
 WHERE product_id IN (…)
 ORDER BY product_id
   FOR UPDATE;
```

Two details in that statement matter:

- **`FOR UPDATE`** takes an exclusive lock, so the second session blocks until the first
  commits, then re-reads the true value and fails the check.
- **`ORDER BY product_id`** makes lock acquisition deterministic. Without it, an order for
  products (5, 9) and a simultaneous order for (9, 5) can each hold one lock and wait for the
  other — a deadlock. Locking in a consistent order across all sessions makes that cycle
  impossible. This costs nothing and removes an entire class of intermittent production
  failure.

The `CHECK (stock_quantity >= 0)` constraint remains as a backstop. Locking is the mechanism;
the constraint is the guarantee that holds even if a future code path forgets to lock.

## 7. Why `sql_mode` is load-bearing

Two of the observed `sql_mode` flags are not incidental — the design depends on them.

**`STRICT_TRANS_TABLES` is what makes `UNSIGNED` meaningful.** Without strict mode, writing
`-5` to an `INT UNSIGNED` column does not fail: MySQL clamps it to `0` and emits a warning.
Rule I-01 would then be silently defeated — stock could not go negative, but only because
overselling would round up to zero, corrupting the ledger while reporting success. Under strict
mode the same write raises an error and the transaction rolls back. The rule holds because of
the mode, not merely because of the column type.

**`ONLY_FULL_GROUP_BY` constrains the views.** Every aggregate in `vw_customer_spending` and the
order-summary view must group by all non-aggregated columns. This is a discipline, not an
obstacle — it rejects exactly the ambiguous grouping that produces plausible-looking wrong
numbers.

Because the schema depends on these, `sql/01_schema.sql` asserts the required modes at the top
rather than assuming a future server will match this one.

## 8. Operational notes

**`AUTO_INCREMENT` gaps are expected.** Rule I-12 rolls back rejected orders, and InnoDB does
not reclaim the consumed sequence value. Gaps in `order_id` are normal and not a defect —
worth stating, because they invariably get reported as one.

**Sequence values are not a count.** For the same reason, `MAX(order_id)` is not the number of
orders. Reports use `COUNT(*)`.

**Every script is idempotent.** `sql/01_schema.sql` through `sql/09_reconciliation.sql` can be
re-run from scratch on a clean server to rebuild the entire system, which is how the test
harness works and how a reviewer will verify it.

## 9. Column additions beyond ADR 0001

One further column-level addition, on top of the four recorded in
[§5 of the logical model](04-logical-model.md):

| Addition | Justification |
|---|---|
| `products.needs_reorder` | `VIRTUAL` generated column making the Phase 3 low-stock query indexable, and serving directly as the "flag" the requirement asks for. Costs no row storage |
