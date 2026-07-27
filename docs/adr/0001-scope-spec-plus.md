# ADR 0001 — Scope

- **Status:** Accepted
- **Date:** 2026-07-26
- **Decision owner:** Joseph Forson

## Context

The source requirements ([`../00-requirements.md`](../00-requirements.md)) name five entities:
products, customers, orders, order details, and inventory logs. Three scope levels were also
considered before any DDL was written.


## Decision

Eight tables, each is justified against a specific phase
requirement. Depth of engineering is prioritised.

## Rationale

1. **Scope discipline is to show a senior engineer mindset.** Knowing what to do, leave out   and documenting
   why — is very important.

 

## Additions beyond the source requirements

Each is traceable to a phase requirement; nothing is added for its own sake.

| Addition | Kind | Traces to |
|---|---|---|
| `categories` table | New table | Phase 1 — normalises the free-text `category` attribute |
| `customer_tiers` table | New table | Phase 3/4 — tier thresholds held as data, not a hardcoded `CASE` |
| `discount_rules` table | New table | Phase 3 — bulk-discount breakpoints held as data |
| `products.target_stock_level` | Column | Phase 4 — the source document specifies a reorder *threshold* but no replenishment *destination*; top-up replenishment is unimplementable without it |
| `orders.status` | Column | Phase 2 — cancellation must return stock, which requires a lifecycle |
| `orders` gross / discount / net split | Columns | Phase 3 — makes discount given a reportable figure |
| `inventory_logs.movement_type` | Column | Phase 2 — an audit trail without reason codes cannot answer *why* stock moved |
| `created_at` / `updated_at` | Columns | Standard practice; supports Phase 2 auditability |

## Consequences

- **Positive:** every table is fully engineered — constrained, indexed, seeded at realistic
  volume, and covered by tests. Performance work is measured against ~100k orders
  rather than asserted against a handful of rows.
- **Positive:** the schema stays small enough that the traceability matrix
  ([`../07-traceability-matrix.md`](../07-traceability-matrix.md)) covers every rule.
- **Negative:** single-location inventory only. Multi-warehouse stock, supplier-driven
  purchase orders, and available-to-promise reservations are deliberately excluded.
- **Mitigation:** the excluded production architecture is documented with its ERD and
  migration path in [`../10-future-architecture.md`](../10-future-architecture.md), so the
  omission is recorded as a decision rather than an oversight.

## Explicitly out of scope

Payments and settlement, shipments and carrier tracking, tax jurisdictions, user
authentication, multi-currency. None serves a stated phase requirement.
