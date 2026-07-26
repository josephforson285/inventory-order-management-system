# Performance

Phase 5 asks that queries stay efficient *"as the number of customers, orders, and products
grows"*. That is the requirement most easily answered by assertion — add indexes, declare
victory. This document measures instead.

Everything below was run against the seeded dataset: **500 products, 10,000 customers, 100,000
orders, 250,000 order details, 250,513 ledger rows.**

---

## 1. Method, and its limits

- MySQL 8.4.10, single machine, InnoDB.
- `EXPLAIN ANALYZE`, which **executes** the query and reports actual times rather than estimates.
- The buffer pool was warmed with a full scan of each large table before measuring. These are
  therefore **warm-cache** figures: they compare *query plans*, not disk behaviour. Cold-cache
  differences would be larger, not smaller.
- The "without index" case uses **`IGNORE INDEX`**, not `DROP INDEX`. Two reasons: it makes no
  schema change, and several of these indexes lead with a foreign key column, which MySQL will
  not let you drop at all. Dropping was not an option for half the measurements.
- **Single runs.** Times vary by roughly ±20% between runs, so the *ratios* below are meaningful
  and the third decimal place is not. Nothing here is averaged over repeated trials, which is a
  real limitation of this write-up.

## 2. Read performance

Each query is one of the seven named in [§5 of the physical design](05-physical-design.md), which
is where the indexes were derived from in the first place.

For precision about what is being measured: the schema carries **16 secondary indexes**. Twelve
are the query-driven ones catalogued in §5, and the remaining four exist for data quality rather
than speed — `uq_categories_name`, `uq_customer_tiers_name`, `uq_customer_tiers_min_spend`, and
`uq_discount_rules_min_quantity`. The last two enforce part of rules T-01 and D-03 by making it
impossible for two bands to share a floor. Only the twelve are candidates for the measurements
below.

| Query | With index | Without | Ratio | What the index does |
|---|---|---|---|---|
| **Q3** lifetime spend, one customer | **0.023 ms** | 16.1 ms | **≈700×** | Covering — never reads a table row |
| **Q7** units sold, one product | **0.093 ms** | 32.5 ms | **≈350×** | Covering |
| **Q1** order history, one customer | **0.074 ms** | 18.1 ms | **≈244×** | Filters *and* supplies the sort order |
| **Q4** ledger history, one product | **0.469 ms** | 40.3 ms | **≈86×** | Filters *and* supplies the sort order |
| **Q5** reconciliation, all products | **32.3 ms** | 59.7 ms | **≈1.9×** | Avoids a temporary table |
| **Q2** low stock | **0.059 ms** | 0.292 ms | **≈4.9×** | Barely matters yet — see §4 |

## 3. Three findings that matter more than the ratios

### Covering indexes remove table access altogether

Q3's plan reads, in full:

```
-> Aggregate: sum(orders.net_amount)  (actual time=0.023..0.023 rows=1 loops=1)
    -> Filter: (orders.status <> 'CANCELLED')  (actual time=0.0151..0.0196 rows=10)
        -> Covering index lookup on orders using idx_orders_customer_status_net (customer_id=42)
```

**`Covering index lookup`** is the important phrase. `idx_orders_customer_status_net` holds
`customer_id`, `status`, and `net_amount` — every column the query mentions — so the row data is
never touched. Without it the plan is `Table scan on orders … rows=100000`: a hundred thousand
rows read to return one number.

That is why the gap is 700× rather than the 20–50× a merely-selective index would give. The
column order matters here too — equality predicates first, the aggregated column last — which is
what makes the whole query answerable from the index.

### An index can eliminate a sort, which is a separate benefit from filtering

Compare Q1 with and without:

```
WITH:     -> Index lookup on orders using idx_orders_customer_date (customer_id=42) (reverse)
WITHOUT:  -> Sort: orders.order_date DESC
              -> Filter: (orders.customer_id = 42)
                  -> Table scan on orders  (rows=99876)
```

The `Sort:` node disappears entirely. Because `idx_orders_customer_date` is
`(customer_id, order_date)`, rows come out of the index already in date order — MySQL reads it
backwards (`reverse`) and is done. Q4 shows the same pattern on `inventory_logs`.

This is worth separating out because it is easy to think of an index as purely a filtering
device. Half the benefit in these two queries is that `ORDER BY` becomes free.

### Q5's gain is real but different in kind — and much smaller

Reconciliation sums every movement grouped by product, so it reads all 250,513 rows either way.
There is no filter to accelerate. The improvement comes from somewhere else:

```
WITH:     -> Group aggregate: sum(quantity_change)
              -> Covering index scan using idx_inventory_logs_product_time_qty
WITHOUT:  -> Table scan on <temporary>
              -> Aggregate using temporary table
                  -> Table scan on inventory_logs
```

Because the index is already ordered by `product_id`, MySQL streams a **group aggregate** — one
group at a time, constant memory. Without it, it must materialise a **temporary table** of 500
groups and then scan that.

1.9× rather than 700×. Reporting it as a win of the same kind as Q3 would be misleading: this
index does not make the reconciliation cheap, it makes it cheaper. The suite still takes about
six seconds end to end.

## 4. The index that has not earned its keep yet

[§5.1 of the physical design](05-physical-design.md) argued at some length for
`idx_products_needs_reorder`: a column-to-column comparison cannot be indexed, so the comparison
became a generated column and the column got an index, justified on the grounds that `TRUE` is a
rare value.

The measurement is **0.059 ms against 0.292 ms**. A quarter of a millisecond.

The reasoning was sound and the outcome is nearly irrelevant, for a reason the argument never
addressed: there are only **500 products**. That is two or three InnoDB pages. A full scan of
three pages is not slow, and no index can improve on it much.

Two things keep the index defensible, and it is worth being clear that neither is "it made the
query fast":

1. **It scales with the catalogue, not the order volume.** At 500,000 products the scan grows a
   thousandfold and the index lookup does not. The index is provision for a dimension this
   dataset does not exercise.
2. **It gives the optimiser accurate statistics.** Without it, MySQL estimates `rows=250` for a
   query that returns 13 — it cannot know the selectivity of a comparison between two columns, so
   it guesses 50%. With the index it estimates 13, exactly. That matters little for a standalone
   query and a great deal when the same predicate sits inside a join, where a 20× row
   misestimate is how you get the wrong join order.

Had the catalogue been the large table and orders the small one, this would have been the
headline result. As it stands it is a correct decision with a currently negligible payoff, and
saying so is more useful than quoting the 4.9× without the context.

## 5. What the indexes cost

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

**+65%** for two indexes on one table. This is the trade the read results are buying, and it is
why [§5.2 of the physical design](05-physical-design.md) lists what was deliberately *not*
indexed. Six candidate indexes were declined; had they all been added, write throughput would be
materially worse for queries no requirement asks for.

### Storage cost

After `ANALYZE TABLE`, in the real schema:

| Table | Rows | Data | Indexes | Indexes as % of data |
|---|---|---|---|---|
| `order_details` | 248,917 | 18.5 MB | 21.5 MB | **116%** |
| `inventory_logs` | 250,083 | 12.5 MB | 18.1 MB | **145%** |
| `orders` | 99,876 | 6.5 MB | 15.7 MB | **242%** |
| `customers` | 9,867 | 1.5 MB | 0.6 MB | 40% |

**The indexes on all three large tables occupy more space than the data they index.** `orders` is
the extreme case at 242%, because it is a narrow table carrying two composite indexes plus the
clustered primary key.

This is the concrete form of the argument in
[§4 of the physical design](05-physical-design.md) for keeping primary keys narrow. In InnoDB the
primary key is stored in **every** secondary index entry, so an oversized key inflates all of
them. Had `order_id`, `order_detail_id`, and `log_id` been left as `BIGINT` rather than revised to
`INT UNSIGNED`, four extra bytes per row would have been multiplied across every index on the
three biggest tables. Against 15.7 MB of index on `orders` alone, that decision is visible in the
numbers rather than merely arguable.

## 6. End-to-end timings

| Operation | Time |
|---|---|
| Full seed — 100k orders, every trigger enabled | 91 s |
| Reconciliation suite — 8 checks (`SELECT * FROM rec_summary`) | 6.3 s |
| Report suite — 9 reports (`08_reports.sql`) | 10.2 s |
| Schema build from empty (`01`–`06`) | < 1 s |

The 91-second seed deserves a note. Bulk-inserting stock directly would have been several times
faster, but it would have bypassed the ledger, the immutability rules, and the tier automation —
so the loaded data would prove nothing about the system. The 91 seconds buys three
reconciliations reporting zero at full volume, which is the only reason the dataset is worth
having.

## 7. Conclusions

**What the measurements support.** The covering indexes are the strongest result by a wide
margin — 350× and 700× — and they are strong precisely because the queries were written down
first and the indexes derived from them, so every column the query needs is in the index. The
sort-elimination benefit on Q1 and Q4 was not part of the original justification and turns out to
be roughly half the gain in both.

**What they do not support.** `idx_products_needs_reorder` is currently worth a quarter of a
millisecond, against a fairly involved argument for its existence. It is retained on the grounds
of catalogue growth and optimiser statistics, not on the strength of that number.

**What would be measured next**, given more time:

- Repeated trials with a cold buffer pool, since these figures compare plans rather than I/O.
- The two indexes on `orders` that both lead with `customer_id` are partially redundant.
  `idx_orders_customer_date` alone would serve Q3, though only as a non-covering index — so the
  open question is whether Q3's 700× is worth the second index's share of that 242% storage
  overhead and its half of the +65% write cost. Both numbers are now known; the trade-off between
  them has not been measured, and it is a measurement rather than an opinion.

## 8. A prediction the measurement refuted

`orders.order_date` was left unindexed by choice ([§5.2](05-physical-design.md)), on the grounds
that no requirement asked for cross-customer date reporting. Report R6 — the monthly sales trend —
then arrived and did exactly that, so the obvious conclusion was that R6 was the query §5.2 said
to wait for, and the index should now be added.

That was wrong, and testing it took two minutes:

| | Time | Plan |
|---|---|---|
| R6 as it stands | 64.1 ms | `Table scan on orders` → temporary table → sort |
| R6 with `INDEX (order_date)` added | 54.3 ms | `Table scan on orders` → temporary table → sort |

The plans are **identical**. The optimiser did not use the new index at all, and the difference is
within run-to-run noise. The index was created, measured, and dropped again.

The reason is visible once looked for. R6 groups by `DATE_FORMAT(order_date, '%Y-%m')` — the
column is wrapped in a function, so an index on the bare column cannot supply the grouping order,
and there is no range predicate on `order_date` to narrow the scan. The query reads every row
whatever indexes exist. An index helps a `GROUP BY` only when it can deliver rows already in group
order, and `DATE_FORMAT(col)` is not `col`.

So §5.2's decision is not merely still open — it is now **confirmed by measurement**. What would
actually help, if 64 ms ever became a problem, is a different thing entirely: a functional index
on the expression, or a stored `order_month` generated column with an index on it — the same
technique already used for `needs_reorder`, applied to a date.

This is the second time in this document that measuring contradicted reasoning: the low-stock
index turned out to be worth a quarter of a millisecond, and this index turned out to be worth
nothing at all. Both were argued for plausibly beforehand. That is the case for measuring.
