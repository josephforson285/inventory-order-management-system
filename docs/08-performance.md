# Performance

This doc. makes a walkthrough on the performance when it was tested with generated data.

Everything below was run against the seeded dataset: **500 products, 10,000 customers, 100,000
orders, 250,000 order details, 250,513 ledger rows.**

---

 

## 1. Read performance

Each query is one of the   named in [§5 of the physical design](05-physical-design.md), which
is where the indexes were derived from in the first place.

 

| Query | With index | Without | Ratio | What the index does |
|---|---|---|---|---|
| **Q3** lifetime spend, one customer | **0.023 ms** | 16.1 ms | **≈700×** | Covering — never reads a table row |
| **Q7** units sold, one product | **0.093 ms** | 32.5 ms | **≈350×** | Covering |
| **Q1** order history, one customer | **0.074 ms** | 18.1 ms | **≈244×** | Filters *and* supplies the sort order |
| **Q4** ledger history, one product | **0.469 ms** | 40.3 ms | **≈86×** | Filters *and* supplies the sort order |
| **Q5** reconciliation, all products | **32.3 ms** | 59.7 ms | **≈1.9×** | Avoids a temporary table |
| **Q2** low stock | **0.059 ms** | 0.292 ms | **≈4.9×** | Barely matters yet — see §4 |

 

## 2. What the indexes cost

Every index above is paid for twice: on every write, and in storage. Both are measurable, and
neither is small.

### Write cost

Measured in isolation, in a scratch schema with no triggers, so the figure is the index cost and
not the cost of the automation layer. Two identical copies of `orders`, one with both secondary
indexes and one with neither, each loaded with the same 100,000 rows:

| | Insert time |
|---|---|
| With `idx_orders_customer_date` + `idx_orders_customer_status_net` | **0.71 s** |
| With neither | **0.43 s** |


### Storage cost

After `ANALYZE TABLE`, in the real schema:

| Table | Rows | Data | Indexes | Indexes as % of data |
|---|---|---|---|---|
| `order_details` | 248,917 | 18.5 MB | 21.5 MB | **116%** |
| `inventory_logs` | 250,083 | 12.5 MB | 18.1 MB | **145%** |
| `orders` | 99,876 | 6.5 MB | 15.7 MB | **242%** |
| `customers` | 9,867 | 1.5 MB | 0.6 MB | 40% |



## 3. End-to-end timings

| Operation | Time |
|---|---|
| Full seed — 100k orders, every trigger enabled | 91 s |
| Reconciliation suite — 8 checks (`SELECT * FROM rec_summary`) | 6.3 s |
| Report suite — 9 reports (`08_reports.sql`) | 10.2 s |
| Schema build from empty (`01`–`06`) | < 1 s |

 