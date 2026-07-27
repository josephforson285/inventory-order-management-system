# Future Architecture 

[ADR 0001](adr/0001-scope-spec-plus.md) chose an eight-table model but a still work in progress is a nineteen-table. 
---

## 1. The production model

Nineteen entities across four subject areas. The eight tables that exist today are marked ✅.

| Subject area | Entities |
|---|---|
| **Product & pricing** | `categories` ✅, `products` ✅, `price_history`, `discount_rules` ✅, `customer_tiers` ✅ |
| **Party & sales** | `customers` ✅, `addresses`, `orders` ✅, `order_details` ✅, `returns`, `return_lines` |
| **Inventory** | `warehouses`, `inventory`, `inventory_logs` ✅ |
| **Procurement** | `suppliers`, `supplier_products`, `purchase_orders`, `purchase_order_lines` |

```mermaid
erDiagram
    CATEGORY        ||--o{ PRODUCT              : classifies
    PRODUCT         ||--o{ PRICE_HISTORY        : "priced over time"
    PRODUCT         ||--o{ INVENTORY            : "stocked as"
    WAREHOUSE       ||--o{ INVENTORY            : holds
    INVENTORY       ||--o{ INVENTORY_LOG        : "movements recorded in"

    CUSTOMER_TIER   ||--o{ CUSTOMER             : segments
    CUSTOMER        ||--o{ ADDRESS              : has
    CUSTOMER        ||--o{ ORDER                : places
    ORDER           ||--|{ ORDER_DETAIL         : "consists of"
    PRODUCT         ||--o{ ORDER_DETAIL         : "is sold as"
    DISCOUNT_RULE   ||--o{ ORDER_DETAIL         : "granted discount to"

    ORDER           ||--o{ RETURN               : "may generate"
    RETURN          ||--|{ RETURN_LINE          : contains
    ORDER_DETAIL    ||--o{ RETURN_LINE          : "returned via"

    SUPPLIER        ||--o{ SUPPLIER_PRODUCT     : offers
    PRODUCT         ||--o{ SUPPLIER_PRODUCT     : "sourced via"
    SUPPLIER        ||--o{ PURCHASE_ORDER       : receives
    WAREHOUSE       ||--o{ PURCHASE_ORDER       : "delivered to"
    PURCHASE_ORDER  ||--|{ PURCHASE_ORDER_LINE  : contains
    PRODUCT         ||--o{ PURCHASE_ORDER_LINE  : "replenished by"
```

---

## 2. Expansion one — multi-warehouse inventory
 

## 3. Expansion two — procurement
 
 

## 4. Expansion three — reserved stock and available-to-promise


## 5. Expansion four — returns

 