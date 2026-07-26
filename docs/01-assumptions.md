# Assumptions Register

The [source requirements](00-requirements.md) are written in business prose and leave a number
of questions unanswered. Every such gap is resolved here rather than silently in code.

Two kinds of entry appear below, and the distinction matters:

- **Assumption** — a question the requirements do not answer, resolved by judgement. A real
  business stakeholder could overrule any of these, and the system would need to change.
- **Scope decision** — something deliberately excluded. Not an open question; a choice, with its
  reasoning recorded in [ADR 0001](adr/0001-scope-spec-plus.md).

Each entry names where it is enforced, so an assumption cannot quietly drift away from the code
that implements it.

---

## Order processing

| # | Kind | Assumption | Enforced by |
|---|---|---|---|
| A-01 | Assumption | When any line of an order has insufficient stock, **the entire order is rejected**. No partial fulfilment, no backorder. | Rule I-12, `sp_place_order` |
| A-02 | Assumption | An order has exactly two states: `PLACED` or `CANCELLED`. Nothing is provisional, because stock is deducted at placement. | Rule O-03, `chk_orders_cancelled_at_consistent` |
| A-03 | Assumption | Stock is deducted at the moment of placement, not at shipment. Follows from there being no reservation model. | `sp_place_order` |
| A-04 | Assumption | An order line, once written, is never amended. Corrections are made by cancelling and re-placing. | Rule O-05 |
| A-05 | Assumption | A customer ordering the same product twice in one order is treated as one line with the quantities summed, not two lines. | Rule O-06, `uq_order_details_order_product` |

**On A-01** — the alternative readings were partial fulfilment and backordering. Both were
rejected: partial fills require line-level status and make the order total ambiguous, and
backordering implies a fulfilment concept the requirements never mention. If the business
actually wants partial fills, this is the assumption to revisit first, and it changes
`sp_place_order`, the order total logic, and the inventory log's meaning.

**On A-05** — this is a genuine judgement call. Summing is friendlier (the customer's intent is
obvious) but loses the information that they added the item twice. Since the requirements say
nothing about a cart or a UI, that information has nowhere to be useful.

---

## Inventory and replenishment

| # | Kind | Assumption | Enforced by |
|---|---|---|---|
| A-06 | Assumption | Replenishment triggers when stock is **at or below** `reorder_level` (`<=`), not strictly below. | Rule I-13, `sp_replenish_stock` |
| A-07 | Assumption | Replenishment **tops stock up to `target_stock_level`** rather than adding a fixed quantity. | Rule I-13 |
| A-08 | Assumption | Replenishment is instantaneous — stock appears on the shelf when the procedure runs. There is no supplier, purchase order, or lead time. | Scope, see A-20 |
| A-09 | Assumption | Seed stock enters through the same write path as every other movement, logged as `INITIAL_LOAD`, so the ledger reconciles from the very first row. | Rule I-15 |
| A-10 | Assumption | `ADJUSTMENT` is the only movement type permitted in either direction. All others have a fixed sign. | `chk_inventory_logs_sign_matches_type` |

**On A-06** — the requirements say *"below its reorder point"*, which strictly reads as `<`.
Reaching the reorder level is itself the signal to reorder in standard inventory practice, so
this is a deliberate departure from the wording. Recorded so it is not mistaken for an
off-by-one error.

**On A-07** — a fixed reorder quantity leaves a product that crashed to zero still below its
threshold after replenishment. Top-up is self-correcting. The cost is one extra column
(`target_stock_level`), since the requirements supply a threshold but no destination.

---

## Pricing, discounts, and tiers

| # | Kind | Assumption | Enforced by |
|---|---|---|---|
| A-11 | Assumption | Bulk discount is resolved from **each line's own quantity**, not the order's total quantity. | Rule D-04, `sp_place_order` |
| A-12 | Assumption | Customer tiers are for **reporting only** and never affect price. | Rule D-06 |
| A-13 | Assumption | Tier thresholds are as below. **These figures are invented** — the requirements give only *"e.g. Bronze, Silver, Gold"*. | `customer_tiers` rows |
| A-14 | Assumption | Lifetime spend excludes cancelled orders. | Rule T-03, `vw_customer_spending` |
| A-15 | Assumption | A customer who has never ordered holds the lowest tier, not no tier. | Rule T-04 |
| A-16 | Assumption | All amounts are in a single currency (GHS). No multi-currency, no exchange rates. | Column types |

Provisional tier bands for A-13:

| Tier | `min_spend` | `max_spend` |
|---|---|---|
| Bronze | 0.00 | 2,000.00 |
| Silver | 2,000.00 | 10,000.00 |
| Gold | 10,000.00 | `NULL` (unbounded) |

These are placeholders chosen to produce a sensible spread, not derived from anything. They
remain in [`03_reference_data.sql`](../sql/03_reference_data.sql) because they suit the
small-scale scenarios in `tests/`.

### Status: discharged for the seeded population

This assumption has since been tested against real data, and it was wrong — informatively so.
With 100,000 orders loaded, actual lifetime spend ran from 2,065 to 1,181,678 with a median near
430,000. Against that population a Gold floor of 10,000 filed **99.1% of customers as Gold**:

| | Invented thresholds | Derived from percentiles |
|---|---|---|
| Bronze | 0 | 6,000 |
| Silver | 90 | 2,997 |
| Gold | 9,910 | 1,003 |

[`07_seed.sql`](../sql/07_seed.sql) now re-derives the bands from the data it generated — bottom
60% Bronze, next 30% Silver, top 10% Gold — and refreshes every cached `customers.tier_id`
against them.

Two things worth drawing out of that:

- **This is the argument for business-rules-as-data, demonstrated rather than asserted.**
  Correcting a materially wrong tier scheme was three `UPDATE` statements. Had the thresholds
  been a `CASE` expression inside a view, it would have been a code change and a redeployment.
- **Moving the bands invalidated every cached tier.** The caches had to be recomputed, and had
  that step been forgotten, rule T-06's reconciliation would have caught it rather than the
  error sitting unnoticed in the reports. That is precisely why a cache is paired with a proof.

**On A-11** — the requirements say *"bulk discounts based on quantity ordered"*, which admits
both readings. Per-line was chosen because bulk pricing reflects the packaging and handling
economics of a specific product; the per-order reading rewards large mixed baskets, which is a
basket promotion rather than a bulk discount.

**On A-12** — the requirements use tiers only for categorisation and spending reports. A
tier-based discount was considered and rejected as an invention. This is recorded because it is
the most tempting feature to add later without noticing it was never asked for.

---

## Data and platform

| # | Kind | Assumption | Enforced by |
|---|---|---|---|
| A-17 | Assumption | One phone number per customer. A second number would need a `customer_phones` table to satisfy 1NF. | `customers.phone` |
| A-18 | Assumption | `DATETIME` values are all server-local. The type stores no zone, so this is a convention rather than a guarantee. | Column types |
| A-19 | Assumption | `sql_mode` includes `STRICT_TRANS_TABLES` and `ONLY_FULL_GROUP_BY`. This is a **deployment dependency**, not a preference. | Asserted at the top of `sql/01_schema.sql` |
| A-20 | Assumption | Product prices are amended in place; there is no price-history table. Historical correctness comes from snapshotting the price onto each order line instead. | Rule O-08 |
| A-21 | Assumption | Customers and products are never deleted. Products are retired via `is_active`; customers are retained because they have orders. | `ON DELETE RESTRICT` throughout |
| A-22 | Assumption | Discount bands and tier bands tile their range with no gaps and no overlaps. Not expressible as a constraint, so verified by query. | Rules D-03, T-01 |

**On A-19** — this one has teeth. Without `STRICT_TRANS_TABLES`, writing a negative value to an
`UNSIGNED` column does not fail: MySQL clamps it to `0` and warns. Rule I-01 would then be
defeated silently — overselling would round up to zero and report success while corrupting the
ledger. The rule holds *because of the mode*, which is why the schema sets it explicitly rather
than trusting a future server's defaults.

**On A-20** — worth stating because it looks like an omission. A `price_history` table would let
us answer *"what did this product cost last March?"*. We cannot answer that. What we **can**
always answer is *"what was this customer charged?"*, which is the question the requirements
actually ask, and which the order-line snapshot answers exactly.

---

## Deliberately out of scope

These are not assumptions. They are exclusions, with reasoning in
[ADR 0001](adr/0001-scope-spec-plus.md) and the architecture they were cut from sketched in
[10-future-architecture.md](10-future-architecture.md).

| # | Excluded | Why |
|---|---|---|
| A-23 | Multiple warehouses / stock locations | Single-location inventory. Stock lives on `products`, not on a `product × location` table |
| A-24 | Suppliers and purchase orders | Replenishment is a direct stock top-up, not a procurement process |
| A-25 | Reserved stock / available-to-promise | Follows from A-03: stock is deducted at placement, so nothing is ever merely reserved |
| A-26 | Returns | The `RETURN` movement type is reserved in the enum but never produced. No return tables exist |
| A-27 | Payments and settlement | No stated requirement. An order records what was owed, not what was paid |
| A-28 | Shipments and carrier tracking | No stated requirement |
| A-29 | Tax and jurisdictions | No stated requirement |
| A-30 | Authentication and user accounts | Out of scope for a database exercise |

A-26 deserves a note: `RETURN` is present in the `movement_type` enum and covered by the sign
and order-presence constraints, so the ledger is *ready* for returns without implementing them.
That is intentional — a reserved value costs nothing, and adding it later would require
`ALTER TABLE` on a large table.
