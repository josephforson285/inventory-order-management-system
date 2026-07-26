# Logical Data Model

The logical model adds attributes, keys, and cardinality to the
[conceptual model](03-conceptual-model.md), and resolves every structural question before any
DDL is written. Types are indicative rather than final; the physical decisions — storage
engine, character set, index layout — belong to
[`05-physical-design.md`](05-physical-design.md).

---

## 1. The central distinction: redundancy versus history

Seven attributes in this model store a value that could, in principle, be calculated from
somewhere else. Treating them as one category would be a mistake. They divide into two kinds,
and confusing them is the most common modelling error in order systems.

### Kind A — Temporal facts. Not redundancy at all.

| Attribute | Could be "derived" from | Why deriving it is wrong |
|---|---|---|
| `order_details.unit_price` | `products.unit_price` | The product's price today is not the price this order was sold at. Joining live means every historical invoice silently re-prices whenever a product's price changes. |
| `order_details.discount_percent_applied` | `discount_rules` | Same failure. Editing a discount band would retroactively alter what past customers were charged. |

These look like violations of normalisation. They are not. Normalisation forbids storing the
**same fact** twice; these store a **different fact** — not *"what does this product cost"*
but *"what was this product sold for on this date"*. The source is a different point in time,
so it is a different value. There is no functional dependency to eliminate.

A useful test: if the value must remain unchanged when the reference data changes, it is a
temporal fact and must be stored.

### Kind B — Caches. Genuine, deliberate denormalisation.

| Attribute | Derivable from | Maintained by | Proven by |
|---|---|---|---|
| `products.stock_quantity` | `SUM(inventory_logs.quantity_change)` | Procedures, logged by trigger | Rule I-08 |
| `inventory_logs.balance_after` | Sum of all prior movements for that product | I-02 trigger | Rule I-08 |
| `orders.gross_amount`, `orders.discount_amount` | `SUM` over `order_details` | O-10 trigger | Rule O-11 |
| `customers.tier_id` | `vw_customer_spending` against `customer_tiers` | T-05 trigger | Rule T-06 |

These *are* denormalisations. Each is stored because recomputing it on every read is the exact
cost [Phase 5](00-requirements.md) asks us to remove. Each therefore carries an obligation:
a named owner that maintains it, and a reconciliation query that proves it has not drifted.
A cache without a proof is just a bug that has not surfaced yet.

### Kind C — Engine-owned. Cannot drift.

All three money columns on `order_details` — `gross_amount`, `discount_amount`, `net_amount` —
are `STORED` generated columns, as is `orders.net_amount`. Note that `orders.gross_amount` and
`orders.discount_amount` are **not**: those aggregate across rows, which no generated column
can express, so they belong to the O-10 trigger and to Kind B above.

A generated column is arithmetic on values within its own row, so MySQL computes it and no
trigger can write it incorrectly. Where a derived value can be pushed down to the engine, it
is — which is precisely why only *aggregates across rows* are left to triggers.

---

## 2. Normalisation walkthrough

The model is in **third normal form**, with the Kind B exceptions above recorded as
deliberate departures.

### First normal form — atomic attributes

- The requirements specify a customer *"name"*. Stored as `first_name` and `last_name` rather
  than one field, so that sorting and reporting by surname is possible without string
  surgery.
- `phone` holds a single number. A customer with two numbers would require a repeating group,
  which 1NF forbids — the correct fix is a `customer_phones` table. Scoped out under
  [ADR 0001](adr/0001-scope-spec-plus.md) as the requirements describe one *"phone number"*.
  Recorded so the limitation is visible rather than accidental.
- No comma-separated lists anywhere. Product-to-category is a foreign key, not a text field.

### Second normal form — no partial key dependencies

`order_details` is the only candidate for trouble, since its natural key is composite
(`order_id`, `product_id`).

- `quantity`, `unit_price`, and `discount_percent_applied` all depend on the **whole** key: the
  price and discount are those of *this product, in this order*, not of the product generally.
- A surrogate primary key `order_detail_id` is used with a `UNIQUE (order_id, product_id)`
  constraint alongside it. The surrogate simplifies foreign keys and application code; the
  unique constraint preserves the business rule (O-06) that a product appears at most once per
  order. Dropping the unique constraint in favour of the surrogate alone would silently permit
  duplicate lines — a common oversight.

### Third normal form — no transitive dependencies

Two transitive dependencies were removed, and each removal is why one of the added tables
exists:

| Transitive dependency, if left in place | Resolution |
|---|---|
| `product_id → category_name` — the category's name depends on the category, not the product. Storing it on `products` means a rename must touch every product row, and misspellings create phantom categories. | `categories` table |
| `customer_id → tier_name, min_spend` — a tier's name and thresholds depend on the tier, not the customer. Storing them on `customers` means changing a threshold requires rewriting customer rows. | `customer_tiers` table |

`customers.tier_id` remains as a foreign key. That is not a transitive dependency — it is a
cached derived value (Kind B), owned by T-05 and proven by T-06.

### Keys: surrogate and natural

Every table uses an auto-incrementing surrogate primary key, with natural keys enforced
separately as unique constraints:

| Table | Surrogate PK | Natural key (`UNIQUE`) |
|---|---|---|
| `categories` | `category_id` | `category_name` |
| `products` | `product_id` | `sku` |
| `customers` | `customer_id` | `email` |
| `customer_tiers` | `tier_id` | `tier_name` |
| `orders` | `order_id` | — (no business identifier) |
| `order_details` | `order_detail_id` | (`order_id`, `product_id`) |
| `inventory_logs` | `log_id` | — (append-only; repeats are legitimate) |
| `discount_rules` | `discount_rule_id` | — (bands enforced by D-02/D-03) |

Surrogates are preferred because natural keys here are all mutable — a customer changes email,
a category is renamed — and a mutable primary key propagates updates through every child row.
Keeping the natural key as a unique constraint retains the data-quality guarantee without
paying that cost.

---

## 3. Attributes

Audit columns `created_at` and `updated_at` are present on every table except
`inventory_logs`, which is append-only and needs only `created_at`. They are omitted from the
tables below for brevity.

### `categories`

| Attribute | Type | Null | Notes |
|---|---|---|---|
| `category_id` | `SMALLINT UNSIGNED` | No | PK, auto-increment |
| `category_name` | `VARCHAR(60)` | No | `UNIQUE` |
| `description` | `VARCHAR(255)` | Yes | |

### `products`

| Attribute | Type | Null | Notes |
|---|---|---|---|
| `product_id` | `INT UNSIGNED` | No | PK |
| `category_id` | `SMALLINT UNSIGNED` | No | FK → `categories`, `ON DELETE RESTRICT` |
| `sku` | `VARCHAR(32)` | No | `UNIQUE` — the business-facing identifier |
| `product_name` | `VARCHAR(120)` | No | |
| `unit_price` | `DECIMAL(12,2)` | No | `CHECK (unit_price > 0)` |
| `stock_quantity` | `INT UNSIGNED` | No | Default 0. Cache — see rule I-08 |
| `reorder_level` | `INT UNSIGNED` | No | Replenish at or below this (I-13) |
| `target_stock_level` | `INT UNSIGNED` | No | `CHECK (target_stock_level > reorder_level)` (I-14) |
| `is_active` | `BOOLEAN` | No | Default true. Soft retirement — see note below |

### `customer_tiers`

| Attribute | Type | Null | Notes |
|---|---|---|---|
| `tier_id` | `TINYINT UNSIGNED` | No | PK |
| `tier_name` | `VARCHAR(20)` | No | `UNIQUE` — Bronze, Silver, Gold |
| `min_spend` | `DECIMAL(12,2)` | No | Lowest band must be 0 (rule T-04) |
| `max_spend` | `DECIMAL(12,2)` | **Yes** | `NULL` means unbounded — the top band |

### `customers`

| Attribute | Type | Null | Notes |
|---|---|---|---|
| `customer_id` | `INT UNSIGNED` | No | PK |
| `first_name` | `VARCHAR(60)` | No | |
| `last_name` | `VARCHAR(60)` | No | |
| `email` | `VARCHAR(160)` | No | `UNIQUE` |
| `phone` | `VARCHAR(20)` | Yes | Stored as text — never numeric; leading zeros matter |
| `tier_id` | `TINYINT UNSIGNED` | No | FK → `customer_tiers`. Cache — see rule T-06 |

### `orders`

| Attribute | Type | Null | Notes |
|---|---|---|---|
| `order_id` | `BIGINT UNSIGNED` | No | PK |
| `customer_id` | `INT UNSIGNED` | No | FK → `customers`, `ON DELETE RESTRICT` (O-01) |
| `order_date` | `DATETIME` | No | Default `CURRENT_TIMESTAMP`; not future-dated (O-13) |
| `status` | `ENUM('PLACED','CANCELLED')` | No | Default `'PLACED'` (O-03) |
| `gross_amount` | `DECIMAL(12,2)` | No | Cache, maintained by O-10 |
| `discount_amount` | `DECIMAL(12,2)` | No | Cache, maintained by O-10 |
| `net_amount` | `DECIMAL(12,2)` | No | `GENERATED … STORED` as `gross_amount - discount_amount` |
| `cancelled_at` | `DATETIME` | Yes | Non-null exactly when status is `CANCELLED` |

### `order_details`

| Attribute | Type | Null | Notes |
|---|---|---|---|
| `order_detail_id` | `BIGINT UNSIGNED` | No | PK |
| `order_id` | `BIGINT UNSIGNED` | No | FK → `orders`, `ON DELETE RESTRICT` |
| `product_id` | `INT UNSIGNED` | No | FK → `products`, `ON DELETE RESTRICT` |
| `quantity` | `INT UNSIGNED` | No | `CHECK (quantity > 0)` (O-07) |
| `unit_price` | `DECIMAL(12,2)` | No | **Temporal fact** — price at time of sale (O-08) |
| `discount_percent_applied` | `DECIMAL(5,2)` | No | Default 0. **Temporal fact** (D-05) |
| `discount_rule_id` | `SMALLINT UNSIGNED` | **Yes** | FK → `discount_rules`. `NULL` = sold at full price |
| `gross_amount` | `DECIMAL(14,2)` | No | `GENERATED` — `quantity * unit_price` |
| `discount_amount` | `DECIMAL(14,2)` | No | `GENERATED` — rounded to 2 dp, see note |
| `net_amount` | `DECIMAL(14,2)` | No | `GENERATED` — `gross_amount - discount_amount` (O-09) |

Constraint: `UNIQUE (order_id, product_id)` (O-06).

### `inventory_logs`

| Attribute | Type | Null | Notes |
|---|---|---|---|
| `log_id` | `BIGINT UNSIGNED` | No | PK |
| `product_id` | `INT UNSIGNED` | No | FK → `products`, `ON DELETE RESTRICT` |
| `movement_type` | `ENUM(…)` | No | Six values (I-04) |
| `quantity_change` | `INT` | No | **Signed** — negative out, positive in. `CHECK (<> 0)` (I-06) |
| `balance_after` | `INT UNSIGNED` | No | Resulting stock level (I-07) |
| `order_id` | `BIGINT UNSIGNED` | **Yes** | FK → `orders`. Null for non-sale movements |
| `notes` | `VARCHAR(255)` | Yes | Free text for `ADJUSTMENT` |
| `created_at` | `DATETIME` | No | Default `CURRENT_TIMESTAMP` |

### `discount_rules`

| Attribute | Type | Null | Notes |
|---|---|---|---|
| `discount_rule_id` | `SMALLINT UNSIGNED` | No | PK |
| `min_quantity` | `INT UNSIGNED` | No | Band floor, inclusive |
| `max_quantity` | `INT UNSIGNED` | **Yes** | `NULL` = unbounded top band |
| `discount_percent` | `DECIMAL(5,2)` | No | `CHECK (BETWEEN 0 AND 100)` (D-01) |
| `is_active` | `BOOLEAN` | No | Default true |

---

## 4. Design notes

**`quantity_change` is signed, so it is the one integer that is not `UNSIGNED`.**
A movement out of stock is negative; a movement in is positive. This is what makes rule I-08
a single `SUM` rather than a conditional aggregation, and it is why I-05 exists to stop the
sign contradicting the reason code.

**`inventory_logs.order_id` is a conditional relationship.**
`SALE` and `CANCELLATION` movements must carry an order; `REPLENISHMENT`, `ADJUSTMENT`, and
`INITIAL_LOAD` must not. This is expressible as a `CHECK`:

```
CHECK (
  (movement_type IN ('SALE','CANCELLATION') AND order_id IS NOT NULL)
  OR
  (movement_type IN ('REPLENISHMENT','ADJUSTMENT','INITIAL_LOAD') AND order_id IS NULL)
)
```

Modelling it this way is what makes the log a full stock history rather than a sales history —
and the constraint stops the two categories being mixed up.

**Products are retired, never deleted.**
Every foreign key into `products` is `ON DELETE RESTRICT`, so a product with order history
cannot be removed without destroying that history. `is_active` marks it unsellable while
leaving the past intact. The same reasoning applies to customers: `ON DELETE RESTRICT` on
`orders.customer_id` means a customer with orders cannot be deleted.

**Rounding is applied per line, not per order.**
`order_details.discount_amount` rounds to two decimal places inside the generated column. Rounding once at
the order level instead would leave `orders.discount_amount` differing from the sum of its
lines by fractions of a pesewa — and rule O-11 would fail. Rounding at the lowest level and
summing upward keeps the totals exactly reconcilable.

**`NULL` as unbounded, in two places.**
`customer_tiers.max_spend` and `discount_rules.max_quantity` are nullable, where `NULL` means
"no upper limit". The alternative — a sentinel such as `999999999` — invites arithmetic
mistakes and eventually gets exceeded. Band-resolution logic therefore reads
`… AND (max_spend IS NULL OR spend < max_spend)`.

**`orders.net_amount` is generated, but `gross_amount` is not.**
`net = gross − discount` is arithmetic within one row, so the engine owns it. Gross and
discount are aggregates over `order_details`, which no generated column can express — hence the
O-10 trigger. This split keeps the trigger as small as possible: it maintains two columns, and
the third follows for free.

## 5. Column additions beyond ADR 0001

[ADR 0001](adr/0001-scope-spec-plus.md) lists table-level additions. Four column-level
additions were made while resolving this model, each recorded here:

| Addition | Justification |
|---|---|
| `products.sku` | Products need a business-facing identifier; also supplies the natural key that makes the surrogate-key discussion concrete |
| `products.is_active` | Required by `ON DELETE RESTRICT` — without it there is no way to retire a product that has order history |
| `order_details.discount_rule_id` | Answers *which* rule granted a discount, which Phase 3's discount reporting needs; one nullable column |
| `inventory_logs.order_id` + `notes` | Links a stock movement to its cause, making the Phase 2 audit trail answer *why* rather than only *what* |
