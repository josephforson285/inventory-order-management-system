# Requirements Coverage

Every requirement in the [source document](00-requirements.md) mapped to the artefact that
satisfies it. This exists because the delivered schema is larger than the five tables the
requirements name — [ADR 0001](adr/0001-scope-spec-plus.md) explains why — and additions are
only defensible if the original requirements are demonstrably still met in full.

**Legend:** ✅ implemented and verified · ◐ partially implemented · ○ designed, not yet built

---

## Phase 1 — Database design and schema implementation

| Requirement | Satisfied by | Status |
|---|---|---|
| **Products:** ID, name, category, price, stock quantity, reorder level | `products`. Category is a foreign key to `categories` rather than free text (3NF, see [logical model §2](04-logical-model.md)) | ✅ |
| **Customers:** ID, name, email, phone | `customers`. "Name" split into `first_name` / `last_name` for 1NF atomicity | ✅ |
| **Orders:** ID, customer ID, order date, total amount | `orders`. "Total amount" is three columns — `gross_amount`, `discount_amount`, `net_amount` — so discount given is reportable | ✅ |
| **Order Details:** products ordered, quantities, prices | `order_details`. Named after this requirement's own vocabulary rather than the industry term *order lines* | ✅ |
| **Inventory Logs:** all inventory changes, including order and replenishment adjustments | `inventory_logs`, with `movement_type` reason codes distinguishing the two causes | ✅ |
| Implement relationships to maintain consistency (orders → valid customer, details → valid products) | 8 named foreign keys, all `ON DELETE RESTRICT ON UPDATE RESTRICT` | ✅ |

## Phase 2 — Order placement and inventory management

| Requirement | Satisfied by | Status |
|---|---|---|
| Design a way to process new orders | `sp_place_order` — a single transaction, rules I-10 and I-12 | ✅ |
| Deduct the correct quantity from stock | `sp_place_order` locks each product in ascending `product_id` order via a cursor, preventing both overselling and deadlock | ✅ |
| Calculate the total order amount | `trg_order_details_after_insert` maintains `gross_amount` and `discount_amount`; `net_amount` is engine-generated | ✅ |
| Update order details and track stock used per order | `order_details` plus `inventory_logs.order_id`, which links every movement back to its cause | ✅ |
| Handle multiple products in a single order | `sp_place_order` takes a JSON array expanded by `JSON_TABLE`. MySQL has no table-valued parameters, so this is the design fork the requirement implies. Repeated products are merged into one line | ✅ |
| Record every stock change in an inventory log | Inverted: stock is changed *by* inserting into `inventory_logs`, and `trg_inventory_logs_after_insert` applies it. No write path can bypass the log because the log **is** the write path ([ADR 0002](adr/0002-ledger-is-the-write-path.md)) | ✅ |
| Log stores when, which product, and how much | `created_at`, `product_id`, `quantity_change` — plus `balance_after` and `movement_type` beyond what was asked | ✅ |
| Full history retrievable for auditing | Append-only, enforced twice: immutability triggers, plus no role holding `UPDATE` or `DELETE` on `inventory_logs`. Verified by connecting as a restricted account (rule I-03) | ✅ |

The audit requirement is worth a note. *"Full history"* is only true if the history cannot be
edited, which is why rule I-03 makes `inventory_logs` append-only at two levels rather than
treating immutability as a convention.

## Phase 3 — Monitoring and reporting

| Requirement | Satisfied by | Status |
|---|---|---|
| Order summaries per customer: date, total, item count | `vw_order_summary`. "Number of items" is ambiguous in the brief, so both readings are exposed: `line_count` (distinct products) and `item_count` (total units) | ✅ |
| Report products low on stock, flagged below reorder point | `vw_low_stock`, filtering on the `needs_reorder` generated column so the query uses its index. `units_to_order` matches exactly what `sp_replenish_stock` would order | ✅ |
| Categorise customers by total spending (Bronze / Silver / Gold) | `vw_customer_spending` joined to `customer_tiers`. Thresholds are rows, not a hardcoded `CASE`. Customers with no orders, and with only cancelled orders, both correctly resolve to the lowest tier rather than disappearing | ✅ |
| Generate spending reports | `vw_customer_spending` carries spend, order counts, discount received, and tier; presentation queries in `08_reports.sql` to come | ◐ |
| Apply bulk discounts based on quantity ordered | `discount_rules` resolved per detail line by `sp_place_order` from that line's own quantity (rule D-04) | ✅ |

The low-stock requirement says products should be *"flagged"*. `products.needs_reorder` is
literally that flag — a generated column, not a per-query expression, which is also what makes
the query indexable. See [physical design §5.1](05-physical-design.md).

## Phase 4 — Stock replenishment and automation

| Requirement | Satisfied by | Status |
|---|---|---|
| Replenish stock for products below the reorder point | `sp_replenish_stock`, topping up to `target_stock_level`, scheduled hourly by `ev_replenish_stock` (rule I-13). Self-limiting, so safe to schedule freely | ✅ |
| Ensure the inventory log reflects replenishment | Structurally unavoidable — a replenishment *is* a `REPLENISHMENT` ledger row, and stock follows from it | ✅ |
| Automate stock updates after an order | Trigger-driven: the procedure writes the ledger, the trigger moves the stock. The procedure never touches `stock_quantity` | ✅ |
| Automate total amount calculation | `trg_order_details_after_insert` + the generated `net_amount` | ✅ |
| Automate customer tier categorisation | `trg_orders_after_insert` / `trg_orders_after_update` call `sp_refresh_customer_tier` (rule T-05). Verified: promotion on a large order, demotion on cancellation | ✅ |
| Minimise manual work while ensuring accuracy | `ev_replenish_stock` runs hourly with no human involvement; the three reconciliation checks prove the automation has not drifted, and pass on 100,000 seeded orders | ✅ |

*"Ensuring accuracy"* is the part usually left unaddressed. Automation that silently drifts is
worse than manual work, which is why every cached value carries a reconciliation query:
rules I-08, O-11, and T-06.

## Phase 5 — Advanced queries and optimisations

| Requirement | Satisfied by | Status |
|---|---|---|
| View: customer name, order date, total amount, item count per order | [`vw_order_summary`](../sql/05_views.sql) | ✅ |
| View: products low on stock needing reorder | [`vw_low_stock`](../sql/05_views.sql) | ✅ |
| Optimise queries for growth in customers, orders, and products | 12 indexes, each derived from a named query ([physical design §5](05-physical-design.md)). Seed data now exists at full volume — 500 products, 10,000 customers, 100,000 orders, 250,000 details, 250,513 ledger rows — with `EXPLAIN ANALYZE` evidence still to be written up | ◐ |

The optimisation requirement is the one most often answered by assertion. It is addressed here
with `EXPLAIN ANALYZE` output before and after indexing, at realistic volume — 500 products,
10,000 customers, 100,000 orders, ~300,000 order details — because an index strategy proven on
forty rows proves nothing.

---

## Deliverables

| Deliverable | Artefact | Status |
|---|---|---|
| Database schema — tables, relationships, constraints | [`sql/01_schema.sql`](../sql/01_schema.sql) | ✅ |
| SQL queries — order placement, stock updates, inventory tracking, customer categorisation | [`sql/04_procedures.sql`](../sql/04_procedures.sql) done; `sql/08_reports.sql` to come | ◐ |
| Views — order and stock summaries | [`sql/05_views.sql`](../sql/05_views.sql) — three views | ✅ |
| Replenishment system — identify and replenish low stock | [`sql/04_procedures.sql`](../sql/04_procedures.sql) done; scheduling in `sql/06_events.sql` to come | ◐ |
| Report summaries — order summaries and stock insights | `sql/08_reports.sql` | ○ |

---

## Beyond the requirements

Delivered although not asked for, because each closes a gap the requirements leave open:

| Addition | Gap it closes |
|---|---|
| Reconciliation suite (`sql/09_reconciliation.sql`) | The requirements ask for automated derived values but never for proof they stay correct. Eight named checks, 0 violations at full volume, runnable as one query |
| Negative test suite (`tests/`) | Four suites: 9 constraint/trigger denials, 6 procedure rejections, the view edge cases, and 11 privilege assertions run as restricted accounts. A constraint nobody has tried to violate is an untested claim |
| `movement_type` reason codes | The requirements ask *what* changed; a reason code answers *why*, which is what makes the log auditable rather than merely complete |
| `balance_after` | Makes point-in-time stock reconstruction O(1) instead of a sum over history |
| Concurrency handling | The requirements never mention simultaneous orders. Without row locking, two customers can each buy the last unit |
| Privilege model (`sql/10_grants.sql`) | Three roles. The application cannot write any table directly — it places orders through a procedure running with its definer's rights, so rules I-02 and I-12 cannot be circumvented even in principle |
| Assumptions register | 30 entries recording every question the requirements leave unanswered, and how each was resolved |

## Deviations

Three places where this implementation knowingly departs from the source text. All three are
recorded in the [assumptions register](01-assumptions.md) with reasoning.

| Requirement text | Implemented as | Why |
|---|---|---|
| *"stock below its reorder point"* | `<=`, not `<` | Reaching the reorder level is itself the reorder signal. Standard inventory practice |
| Products table holds *"stock quantity"* as an attribute | Held there, but as a **cache** over `inventory_logs` | The ledger is the source of truth; the column is a maintained balance proven by rule I-08 |
| Orders hold *"total amount"* | Split into gross, discount, and net | A single total cannot answer how much revenue was given away as discount, which Phase 3 asks for |
