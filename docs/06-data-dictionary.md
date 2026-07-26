# Data Dictionary

Every column in the schema, with its type, nullability, and — where it is not obvious — why it
exists at all. A reader wanting one column should not have to read
[`sql/01_schema.sql`](../sql/01_schema.sql) to find it.

Generated from `information_schema` against the built database, so this describes what is
actually deployed rather than what was intended.

**Conventions used below**

| Marker | Meaning |
|---|---|
| **PK** | Primary key |
| **UQ** | Unique constraint |
| **FK** | Foreign key |
| **GEN** | Generated column — computed by the engine, never written directly |
| **CACHE** | Denormalised copy of a value derived elsewhere. Maintained by a trigger, and paired with a reconciliation query that proves it has not drifted |
| **SNAPSHOT** | A historical fact recorded at the time of an event. Deliberately *not* joined live — see [logical model §1](04-logical-model.md) |

`created_at` and `updated_at` appear on every table except `inventory_logs`, which is append-only
and therefore has only `created_at`. Both are `DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP`;
`updated_at` additionally carries `ON UPDATE CURRENT_TIMESTAMP`. They are omitted from the tables
below to keep the columns that matter visible.

---

## `categories`

Product groupings. Exists so `category` is a foreign key rather than free text, removing the
transitive dependency `product_id → category_name`.

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `category_id` | `SMALLINT UNSIGNED` | No | PK | Auto-increment |
| `category_name` | `VARCHAR(60)` | No | UQ | Case-insensitive collation, so `Electronics` and `electronics` cannot both exist |
| `description` | `VARCHAR(255)` | Yes | | |

---

## `customer_tiers`

Spending bands, held as data rather than a hardcoded `CASE` so a threshold can be changed with an
`UPDATE`. Bands are **half-open**: `[min_spend, max_spend)`.

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `tier_id` | `TINYINT UNSIGNED` | No | PK | Three tiers; 255 is already generous |
| `tier_name` | `VARCHAR(20)` | No | UQ | Bronze, Silver, Gold |
| `min_spend` | `DECIMAL(12,2)` | No | UQ | Inclusive floor. The lowest band **must** be 0, or a customer who has never ordered matches no band (rule T-04). Unique because two bands sharing a floor necessarily overlap |
| `max_spend` | `DECIMAL(12,2)` | **Yes** | | Exclusive ceiling. `NULL` means unbounded — the top band. A sentinel such as `999999999` would eventually be exceeded |
| `is_active` | — | | | *(not present; tiers are not retired)* |

Constraints: `chk_customer_tiers_band` (`max_spend IS NULL OR min_spend < max_spend`),
`chk_customer_tiers_min_non_negative`.

---

## `discount_rules`

Bulk-discount breakpoints, also held as data. Bands are half-open on quantity, and resolved
**per order detail row** from that row's own quantity (rule D-04).

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `discount_rule_id` | `SMALLINT UNSIGNED` | No | PK | |
| `min_quantity` | `INT UNSIGNED` | No | UQ | Inclusive floor. Lowest band starts at 10 — quantities below that match no rule and are sold at full price |
| `max_quantity` | `INT UNSIGNED` | **Yes** | | Exclusive ceiling. `NULL` = unbounded |
| `discount_percent` | `DECIMAL(5,2)` | No | | 0–100 |
| `is_active` | `BOOLEAN` | No | | Default true. A band can be withdrawn without deleting it, which would break the `order_details` rows that reference it |

Constraints: `chk_discount_rules_percent` (0–100), `chk_discount_rules_band`,
`chk_discount_rules_min_positive`.

---

## `products`

Sellable products. `stock_quantity` is a cache; `inventory_logs` is the ledger of record.

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `product_id` | `INT UNSIGNED` | No | PK | `INT` not `BIGINT`: InnoDB stores the PK in every secondary index entry, so key width multiplies across all of them |
| `category_id` | `SMALLINT UNSIGNED` | No | FK | → `categories`, `RESTRICT` |
| `sku` | `VARCHAR(32)` | No | UQ | Natural key. Surrogate PK used because SKUs are mutable and a mutable PK propagates updates through every child row |
| `product_name` | `VARCHAR(120)` | No | | |
| `unit_price` | `DECIMAL(12,2)` | No | | `DECIMAL`, never `FLOAT` — binary approximation would break rule O-11's exact reconciliation |
| `stock_quantity` | `INT UNSIGNED` | No | **CACHE** | Of `SUM(inventory_logs.quantity_change)`. Not directly writable: the ledger is the only write path ([ADR 0002](adr/0002-ledger-is-the-write-path.md)). Proven by `rec_stock_ledger` |
| `reorder_level` | `INT UNSIGNED` | No | | Replenishment triggers at or **below** this (`<=`, not `<` — a deliberate departure from the brief's wording) |
| `target_stock_level` | `INT UNSIGNED` | No | | Where replenishment tops up to. The brief gives a threshold but no destination, so this column was added |
| `is_active` | `BOOLEAN` | No | | Soft retirement. Products are never deleted, because every FK into them is `RESTRICT` and deleting one would destroy order history |
| `needs_reorder` | `BOOLEAN` | No | **GEN** (virtual) | `stock_quantity <= reorder_level`. Exists because a comparison *between two columns* cannot be indexed — so the comparison becomes a column, and the column is indexed. `VIRTUAL`, so it costs no row storage |

Constraints: `chk_products_price_positive`, `chk_products_stock_non_negative` (rule I-01 — note
this is unreachable while the column is `UNSIGNED`; the real enforcement is the type plus
`STRICT_TRANS_TABLES`), `chk_products_target_above_reorder`.

---

## `customers`

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `customer_id` | `INT UNSIGNED` | No | PK | |
| `first_name` | `VARCHAR(60)` | No | | Split from the brief's single *"name"* for 1NF atomicity, so sorting by surname does not need string surgery |
| `last_name` | `VARCHAR(60)` | No | | |
| `email` | `VARCHAR(160)` | No | UQ | Natural key. The case-insensitive collation is deliberate: `Joseph@x.com` and `joseph@x.com` are the same mailbox and must collide |
| `phone` | `VARCHAR(20)` | Yes | | Text, never numeric — leading zeros are significant. One number per customer; a second would need a `customer_phones` table (assumption A-17) |
| `tier_id` | `TINYINT UNSIGNED` | No | FK, **CACHE** | → `customer_tiers`. Cached from `vw_customer_spending`, maintained by trigger T-05, proven by `rec_customer_tiers`. No application role holds `UPDATE` on this column |

---

## `orders`

Order headers. Totals are caches of `order_details`; `net_amount` is engine-generated.

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `order_id` | `INT UNSIGNED` | No | PK | Gaps are expected — a rejected order consumes a sequence value that InnoDB does not reclaim. `MAX(order_id)` is not a count |
| `customer_id` | `INT UNSIGNED` | No | FK | → `customers`, `RESTRICT` |
| `order_date` | `DATETIME` | No | | Default now. Not future-dated — enforced by trigger, because MySQL forbids `NOW()` inside a `CHECK` |
| `status` | `ENUM('PLACED','CANCELLED')` | No | | Two states only. Stock deducts at placement and there is no reservation model, so nothing is ever provisional. `CANCELLED` exists solely because cancellation returns stock |
| `gross_amount` | `DECIMAL(12,2)` | No | **CACHE** | Of `SUM(order_details.gross_amount)`. Maintained incrementally by trigger O-10 — safe because detail rows are immutable |
| `discount_amount` | `DECIMAL(12,2)` | No | **CACHE** | Same |
| `net_amount` | `DECIMAL(12,2)` | No | **GEN** (stored) | `gross_amount - discount_amount`. Arithmetic within one row, so the engine owns it and no trigger can get it wrong |
| `cancelled_at` | `DATETIME` | Yes | | Populated exactly when status is `CANCELLED`, enforced by constraint |

Constraints: `chk_orders_amounts_non_negative`, `chk_orders_discount_within_gross`,
`chk_orders_cancelled_at_consistent`.

**Why gross and discount are triggers but net is generated:** net is arithmetic on the same row,
which a generated column can express. Gross and discount are aggregates *across rows*, which no
generated column can. The split keeps the trigger as small as possible — it maintains two
columns and the third follows for free.

---

## `order_details`

Line items. Named after the brief's own vocabulary rather than the industry term *order lines*,
so every term in the requirements maps to a schema object without translation.

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `order_detail_id` | `INT UNSIGNED` | No | PK | |
| `order_id` | `INT UNSIGNED` | No | FK | → `orders`, `RESTRICT` |
| `product_id` | `INT UNSIGNED` | No | FK | → `products`, `RESTRICT` |
| `quantity` | `INT UNSIGNED` | No | | Must be positive. Repeated products in one order are merged into a single row with quantities summed |
| `unit_price` | `DECIMAL(12,2)` | No | **SNAPSHOT** | The price charged **on this date**. Never joined live from `products` — doing so would silently re-price every historical order whenever a price changed |
| `discount_percent_applied` | `DECIMAL(5,2)` | No | **SNAPSHOT** | The rate actually granted. Same reasoning: editing a discount band must not retroactively alter what past customers paid |
| `discount_rule_id` | `SMALLINT UNSIGNED` | **Yes** | FK | Which band fired. `NULL` = sold at full price. Modelling this as optional avoids inventing a fictional 0% band |
| `gross_amount` | `DECIMAL(14,2)` | No | **GEN** | `quantity × unit_price` |
| `discount_amount` | `DECIMAL(14,2)` | No | **GEN** | Rounded to 2 dp **per row**, not per order, so the order total is exactly the sum of its lines |
| `net_amount` | `DECIMAL(14,2)` | No | **GEN** | `gross_amount - discount_amount` |

Unique: `uq_order_details_order_product (order_id, product_id)` — enforces one row per product per
order, *and* satisfies the foreign key's index requirement on `order_id` by leftmost prefix, so no
separate index is created.

Constraints: `chk_order_details_quantity_positive`, `chk_order_details_price_positive`,
`chk_order_details_discount_percent`.

Widened to `DECIMAL(14,2)` where `orders` uses `(12,2)`, because `quantity × unit_price` can
exceed a single order-level amount.

---

## `inventory_logs`

The ledger of record for stock. Append-only. `products.stock_quantity` is merely a cached balance
over this table.

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `log_id` | `INT UNSIGNED` | No | PK | Auto-increment order is chronological order, which `rec_balance_chain` relies on |
| `product_id` | `INT UNSIGNED` | No | FK | → `products`, `RESTRICT` |
| `movement_type` | `ENUM(6)` | No | | `SALE`, `RETURN`, `REPLENISHMENT`, `ADJUSTMENT`, `CANCELLATION`, `INITIAL_LOAD`. Answers *why* stock moved, not merely that it did. `RETURN` is reserved and never produced in this scope |
| `quantity_change` | `INT` | No | | **The only signed integer in the schema.** Negative = out, positive = in — which is what lets rule I-08 be a single `SUM` rather than a conditional aggregation |
| `balance_after` | `INT UNSIGNED` | No | | Resulting stock level. Makes point-in-time audit O(1) instead of summing all prior history, and is what `products.stock_quantity` is copied from — so the cache agrees with the ledger by construction |
| `order_id` | `INT UNSIGNED` | **Yes** | FK | The cause. **Conditional**: mandatory for `SALE`/`CANCELLATION`/`RETURN`, forbidden for `REPLENISHMENT`/`ADJUSTMENT`/`INITIAL_LOAD`. That constraint is what makes this a complete stock history rather than a sales history |
| `notes` | `VARCHAR(255)` | Yes | | Free text, for `ADJUSTMENT` |

Constraints: `chk_inventory_logs_change_non_zero`, `chk_inventory_logs_sign_matches_type` (a
`SALE` cannot add stock; `ADJUSTMENT` is the only type permitted in either direction, which is
what makes it an adjustment), `chk_inventory_logs_order_presence`.

---

## Foreign keys

Every one is `ON DELETE RESTRICT ON UPDATE RESTRICT`. Surrogate keys are immutable, so nothing
should cascade — and it is also a hard requirement, since MySQL forbids a column carrying a
`CASCADE` referential action from appearing in a `CHECK` constraint (error 3823), which
`chk_inventory_logs_order_presence` depends on.

| Constraint | From | To |
|---|---|---|
| `fk_products_categories` | `products.category_id` | `categories.category_id` |
| `fk_customers_customer_tiers` | `customers.tier_id` | `customer_tiers.tier_id` |
| `fk_orders_customers` | `orders.customer_id` | `customers.customer_id` |
| `fk_order_details_orders` | `order_details.order_id` | `orders.order_id` |
| `fk_order_details_products` | `order_details.product_id` | `products.product_id` |
| `fk_order_details_discount_rules` | `order_details.discount_rule_id` | `discount_rules.discount_rule_id` |
| `fk_inventory_logs_products` | `inventory_logs.product_id` | `products.product_id` |
| `fk_inventory_logs_orders` | `inventory_logs.order_id` | `orders.order_id` |

## Views

| View | Purpose |
|---|---|
| `vw_order_summary` | Order summaries per customer. Exposes both `line_count` (distinct products) and `item_count` (total units), because the brief's *"number of items"* admits both readings |
| `vw_low_stock` | Products at or below reorder level, with `units_to_order` matching exactly what `sp_replenish_stock` would order |
| `vw_customer_spending` | **The definition** of lifetime spend that rules T-02/T-03 refer to, and the truth `customers.tier_id` is cached from. Exposes stored and computed tier side by side |
| `rec_*` (8 views) | Reconciliation checks. Each returns violations only, so an empty result is a pass. `rec_summary` runs the whole suite as one query |

## Routines

| Routine | Purpose |
|---|---|
| `sp_place_order(customer_id, lines JSON, OUT order_id)` | Places a multi-product order. Locks products in ascending `product_id` order, validates every line before writing anything, resolves discounts per line, snapshots prices |
| `sp_cancel_order(order_id)` | Returns stock as `CANCELLATION` movements and marks the order cancelled |
| `sp_replenish_stock(OUT count)` | Tops every low product up to target. Self-limiting |
| `sp_refresh_customer_tier(customer_id)` | Trigger infrastructure, not business API. Recalculates one customer's cached tier |
| `ev_replenish_stock` | Hourly event calling `sp_replenish_stock` |

## A note on the generated columns

All five generated columns are declared `NOT NULL`. That is not the default — MySQL will happily
create a nullable generated column — and it was corrected while compiling this dictionary. Their
inputs are all `NOT NULL`, so the expressions can never yield `NULL`; declaring it makes the
schema state that rather than leaving a reader to work it out.
