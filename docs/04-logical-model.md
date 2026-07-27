# Logical Data Model

The logical model with attributes, keys, and cardinality to the
[conceptual model](03-conceptual-model.md), and resolves every structural question before any
DDL is written. 

 
## The diagram 
 ![Entity relationship diagram — eight entities and the eight relationships between them](img/erd.png)


## Normalisation walkthrough

The model is in **third normal form**.

### First normal form — atomic attributes

- The requirements specify a customer *"name"*. Stored as `first_name` and `last_name` rather
  than one field, so that sorting and reporting by surname is possible without string
  surgery.
- `phone` holds a single number. 
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
  duplicate lines.

### Third normal form — no transitive dependencies

Two transitive dependencies were removed, and each removal is why one of the added tables
exists:

| Transitive dependency, if left in place | Resolution |
|---|---|
| `product_id → category_name` — the category's name depends on the category, not the product. Storing it on `products` means a rename must touch every product row, and misspellings create phantom categories. | `categories` table |
| `customer_id → tier_name, min_spend` — a tier's name and thresholds depend on the tier, not the customer. Storing them on `customers` means changing a threshold requires rewriting customer rows. | `customer_tiers` table |

`customers.tier_id` remains as a foreign key. That is not a transitive dependency.

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
 

## 5. Column additions  

[ADR 0001](adr/0001-scope-spec-plus.md) lists table-level additions. Four column-level
additions were made while resolving this model, each recorded here:

| Addition | Justification |
|---|---|
| `products.sku` | Products need a business-facing identifier; also supplies the natural key that makes the surrogate-key discussion concrete |
| `products.is_active` | Required by `ON DELETE RESTRICT` — without it there is no way to retire a product that has order history |
| `order_details.discount_rule_id` | Answers *which* rule granted a discount, which Phase 3's discount reporting needs; one nullable column |
| `inventory_logs.order_id` + `notes` | Links a stock movement to its cause, making the Phase 2 audit trail answer *why* rather than only *what* |
