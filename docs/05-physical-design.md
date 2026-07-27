# Physical Design

The [logical model](04-logical-model.md) decided *what* is stored, this document decides
*how* — engine, character set, exact types, and the index strategy. Every index here is
justified by a query the [requirements](00-requirements.md) actually asked.

The [entity relationship diagram](03-conceptual-model.md#diagram) shows the eight tables, their
columns, and the eight foreign keys between them.

---

## 1. Development environment

Captured from the development server :

| Setting | Value | Consequence for this design |
|---|---|---|
| Version | `8.4.10` (Ubuntu 26.04) | `CHECK` constraints, functional indexes, and window functions are all available |
| `sql_mode` | `ONLY_FULL_GROUP_BY, STRICT_TRANS_TABLES, NO_ZERO_IN_DATE, NO_ZERO_DATE, ERROR_FOR_DIVISION_BY_ZERO, NO_ENGINE_SUBSTITUTION` | **Load-bearing — see §7** |
| Default engine | `InnoDB` | No override needed |
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

Database: **`inventory_order_management_sys`**.

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

Every constraint is **explicitly named**.


## 3. Data type decisions

### Money — `DECIMAL`, never floating point

All monetary columns are `DECIMAL(12,2)`; the derived per-row amounts on `order_details` widen
to `DECIMAL(14,2)` to accommodate `quantity × unit_price` without overflow.

 

### Integers and key width
 
 
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



### Dates — `DATETIME`

`DATETIME` throughout, with `DEFAULT CURRENT_TIMESTAMP` where appropriate.

 

## 4. Index strategy

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

  

## 5. Concurrency and locking

Rule I-10 requires that two simultaneous orders cannot both sell the last unit. 

 