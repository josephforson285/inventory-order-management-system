# ADR 0002 — Stock is written to the ledger, not to the product

- **Status:** Accepted
- **Date:** 2026-07-26
- **Supersedes:** the original direction of rules I-02, I-07, and I-15
- **Decision owner:** Joseph Forson

## Context

Rule I-02 originally read: *every change to `products.stock_quantity` writes exactly one
`inventory_logs` row*, owned by an `AFTER UPDATE` trigger on `products`. The application would
update stock; the trigger would record it.

Implementing it exposed a problem the rule could not solve. A trigger sees only the row before
and the row after. Given:

| What happened | `OLD.stock_quantity` | `NEW.stock_quantity` |
|---|---|---|
| A customer bought 12 units | 100 | 88 |
| 12 units were written off as damaged | 100 | 88 |

the two are indistinguishable. Yet the trigger must supply a `movement_type`, and the existing
constraints make a wrong guess fatal rather than merely inaccurate: `chk_inventory_logs_order_presence`
requires `SALE` to carry an `order_id` and forbids `ADJUSTMENT` from carrying one. A trigger that
guesses wrong fails the customer's order.

The intent must therefore be communicated from whoever performed the update.

## Options considered

**1. Session variable.** The procedure sets `@movement_type` before the `UPDATE`; the trigger
reads it. No schema change, and common in practice. Rejected: the variable is invisible at the
schema level, and it survives the statement that set it. A stale value from an earlier operation
silently mislabels the next movement — wrong data that looks right, which is the worst failure
mode available to an audit system.

**2. Context columns on `products`.** Add `last_movement_type` and `last_movement_order_id`, set
within the same `UPDATE` so they cannot go stale. Rejected: it places columns describing a
*transaction* onto the *product* table, and an `UPDATE` that omits them silently inherits the
previous movement's values.

**3. Invert the write direction.** Accepted.

## Decision

**Stock is changed by inserting into `inventory_logs`. A trigger then applies the movement to
`products.stock_quantity`.** The application never writes stock directly.

```
INSERT INTO inventory_logs (product_id, movement_type, quantity_change, order_id)
      |
      +-- trg_inventory_logs_before_insert   locks the product, computes balance_after
      +-- trg_inventory_logs_after_insert    copies balance_after into products
```

## Rationale

**The intent becomes part of the write.** `movement_type` and `order_id` are columns of the row
being inserted. There is nothing to infer, no hidden session state, and no extra columns.

**The rule gets stronger, not merely satisfied.** *"Every stock change is logged"* depends on
every code path remembering to behave. *"Stock cannot change except by writing to the ledger"* is
structural — there is no other mechanism. Three guards close the loop:

| Guard | Prevents |
|---|---|
| `trg_products_before_insert` | A product created with opening stock that no ledger row accounts for |
| `trg_products_before_update` | Any direct write to `stock_quantity` |
| `10_grants.sql` | The same, for users privileged enough to ignore a trigger |

**It resolves a contradiction rather than adding a feature.** The logical model, the README, and
the schema comments all state that `inventory_logs` is the source of truth and `stock_quantity`
is a cache over it. Rule I-02 as originally written had the application write to the *cache* and
the truth follow behind. The missing `movement_type` was a symptom of that inversion.

**The cache now agrees with the ledger by construction.** `balance_after` is computed once in the
`BEFORE INSERT` trigger and then *copied* into `products` — not recomputed. Rule I-08's
reconciliation query consequently verifies a property that is structurally true, rather than
hoping two independent calculations agree.

**Locking improves as a side effect.** The `BEFORE INSERT` trigger takes `SELECT … FOR UPDATE` on
the product row, so rule I-10's protection against overselling now holds for *any* ledger write,
not only for writes made through `sp_place_order`. The procedure retains responsibility for
acquiring locks in `product_id` order, which is what prevents deadlock between concurrent
multi-product orders.

## The latch, and why it is not option 1 in disguise

`trg_inventory_logs_after_insert` sets `@allow_stock_write = 1` so that
`trg_products_before_update` will permit its single write.

This is a user variable, which is what option 1 was rejected for. The distinction is real:
the latch carries **no business meaning** and never crosses a statement boundary. It is raised
and consumed within one trigger cascade, whereas `@movement_type` would have had to carry
semantic content from the application into the trigger.

It is also **single-use**: `trg_products_before_update` clears the latch at the moment it honours
it, rather than the caller clearing it afterwards. User variables are not transactional, so had
the latch been cleared after the write, a failed `UPDATE` would have left it raised and
authorised a later manual write. Spending the token on use closes that window. This behaviour is
asserted by the final case in `tests/02_triggers_test.sql`.

## Consequences

**Positive**

- `movement_type` and `order_id` are always correct, because the writer states them
- Stock cannot move without an audit row, enforced structurally at three points
- `sp_place_order` becomes simpler: it inserts details and ledger rows, and stock follows
- Verified end to end — `stock_quantity − SUM(quantity_change) = 0` across a mixed sequence of
  `INITIAL_LOAD`, `SALE`, and `REPLENISHMENT` movements

**Negative**

- Three rules changed direction (I-02, I-07, I-15) after having been agreed
- Writing stock is no longer obvious to a newcomer: `UPDATE products SET stock_quantity` fails
  with an error rather than working. Mitigated by the error message naming the rule and the
  required alternative
- One user variable exists in the design, requiring the justification above

**Neutral**

- The trigger count rises from an intended one on `products` to two on `inventory_logs` plus two
  guards on `products`

## Rules affected

| Rule | Before | After |
|---|---|---|
| I-02 | `AFTER UPDATE` trigger on `products` logs the change | `trg_inventory_logs_after_insert` applies the ledger row to stock; two `products` guards make it the only path |
| I-07 | `balance_after` written by the `products` trigger | Computed by `trg_inventory_logs_before_insert` before the row is stored |
| I-15 | Seed writes stock through the same `UPDATE` path | Opening stock is an `INITIAL_LOAD` ledger insert; non-zero opening stock is rejected outright |
