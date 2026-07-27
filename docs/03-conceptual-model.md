# Conceptual Data Model
**What things exist in this business, and how do
they relate?** Here's also the [logical model](04-logical-model.md).  
## Entities

Eight entities, grouped by the business function they serve.

| Entity | What it represents |
|---|---|
| `CATEGORY` | A grouping of products for merchandising and reporting |
| `PRODUCT` | Something the company sells and holds stock of |
| `CUSTOMER` | A person who places orders |
| `CUSTOMER_TIER` | A spending band used to segment customers for reporting |
| `ORDER` | A single purchase event by one customer |
| `ORDER_DETAIL` | One product, at one quantity, within an order |
| `INVENTORY_LOG` | A single recorded movement of stock, in or out |
| `DISCOUNT_RULE` | A quantity threshold that earns a discount percentage |

## Diagram

![Entity relationship diagram — eight entities and the eight relationships between them](img/erd.png)

Generated from the live schema. The relationships are the subject here; the column names and
types shown belong to the [physical design](05-physical-design.md).

One relationship the diagram cannot express: an order must have **at least one** line. A
foreign key stops a line pointing at a missing order, but nothing at the schema level stops an
order having no lines — that is rule O-02, proven by `rec_orphan_orders` instead. It is stated
in the table below.

## Relationships in business language

Each relationship stated as a sentence the business would recognise, in both directions.
Being aware of it is also a  cheapest way to catch a modelling error.

| Relationship | Reading |  
|---|---|
| `CATEGORY` → `PRODUCT` | A category classifies zero or more products. A product belongs to exactly one category. | 
| `CUSTOMER_TIER` → `CUSTOMER` | A tier segments zero or more customers. Every customer holds exactly one tier — including a customer who has never ordered, who holds the lowest tier. | 
| `CUSTOMER` → `ORDER` | A customer places zero or more orders. Every order belongs to exactly one customer. | 
| `ORDER` → `ORDER_DETAIL` | An order consists of **at least one** line. Every line belongs to exactly one order. | 
| `PRODUCT` → `ORDER_DETAIL` | A product appears on zero or more order lines, but **at most once within any single order**. | 
| `PRODUCT` → `INVENTORY_LOG` | A product has zero or more recorded stock movements. Every movement concerns exactly one product. | 
| `DISCOUNT_RULE` → `ORDER_DETAIL` | A discount rule may have been granted to zero or more lines. A line was granted at most one rule — lines at full price reference none. |  
| `ORDER` → `INVENTORY_LOG` | An order causes zero or more stock movements. A movement may or may not arise from an order — replenishments and corrections do not. 

 



## Questions this model can answer
Every question below traces to a phase in [the requirements](00-requirements.md):

- What did each customer order, when, and for how much? *(Phase 3 — order summaries)*
- Which products have fallen to or below their reorder level? *(Phase 3 — low stock)*
- What is each customer's lifetime spend, and which tier does that place them in? *(Phase 3 — customer insights)*
- For any product, what is the complete history of stock movements, and why did each occur? *(Phase 2 — audit)*
- How much revenue was given away as bulk discount, and under which rule? *(Phase 3 — discounts)*
- Which products sell fastest relative to the stock held? *(Phase 3 — monitoring)*

