# EXPECTED.md — Retail Fulfillment & Returns Control Tower

## Project Structure

```
retail-fulfillment-control-tower/
├── .streamlit/config.toml
├── snowflake.yml
├── pyproject.toml
├── streamlit_app.py              (entry point, navigation, data load, filters)
├── app_pages/
│   ├── executive.py              (Executive Overview)
│   ├── fulfillment.py            (Fulfillment Performance)
│   ├── returns.py                (Returns & Cancellations)
│   └── exceptions.py             (Exception Explorer)
├── lib/
│   ├── data.py                   (cached SQL loader)
│   ├── filters.py                (sidebar form + deferred apply logic)
│   └── metrics.py                (KPI + status label helpers)
├── sql/
│   └── orders.sql                (static joined query)
├── source-validation.sql
├── EXPECTED.md                   (this file)
└── INTERACTION-VALIDATION.md
```

---

## Navigation

| # | Page Title               | Icon                        | File                        |
|---|--------------------------|-----------------------------|-----------------------------|
| 1 | Executive Overview       | :material/dashboard:        | app_pages/executive.py      |
| 2 | Fulfillment Performance  | :material/local_shipping:   | app_pages/fulfillment.py    |
| 3 | Returns & Cancellations  | :material/assignment_return:| app_pages/returns.py        |
| 4 | Exception Explorer       | :material/warning:          | app_pages/exceptions.py     |

Navigation is rendered via `st.navigation` (sidebar position, default).

---

## Global Sidebar Filters (all pages)

Inside `st.form("filter_form")`:

| Control         | Widget Type       | Default             |
|-----------------|-------------------|---------------------|
| Date Range      | st.date_input     | Full data range     |
| Region          | st.multiselect    | [] (all)            |
| Category        | st.multiselect    | [] (all)            |
| Order Channel   | st.multiselect    | [] (all)            |
| Order Status    | st.multiselect    | [] (all)            |
| Apply Filters   | form_submit_button| —                   |

Below the form:
| Control | Widget Type | Behavior                   |
|---------|-------------|----------------------------|
| Reset   | st.button   | Clears all filters, reruns |

**Deferred semantics:** Filter widgets do NOT affect dashboard results until "Apply Filters" is clicked. Reset restores unfiltered default state and triggers `st.rerun()`.

---

## Page 1: Executive Overview

### KPIs (row 1)

| KPI          | Formula                                          | Format       |
|--------------|--------------------------------------------------|--------------|
| Net Revenue  | SUM(net_revenue) of filtered rows                | $X,XXX       |
| Net Profit   | SUM(net_profit) of filtered rows                 | $X,XXX       |
| Orders       | COUNT DISTINCT(order_id) of filtered rows        | X,XXX        |

### KPIs (row 2)

| KPI              | Formula                                      | Format   |
|------------------|----------------------------------------------|----------|
| Return Rate      | SUM(is_returned) / COUNT(*) * 100            | X.X%     |
| Cancellation Rate| SUM(is_cancelled) / COUNT(*) * 100           | X.X%     |
| Avg Days to Ship | MEAN(days_to_ship)                           | X.X      |

### SLA Progress Indicator

- Label: "SLA: Shipped Within 3 Days"
- Widget: `st.progress`
- Value: COUNT(days_to_ship <= 3) / COUNT(*) * 100, capped at 100%
- Display: "{pct:.1f}% on-time"

### Charts

| Chart               | Type          | X-axis        | Y-axis   | Grouping          |
|---------------------|---------------|---------------|----------|-------------------|
| Monthly Revenue     | st.line_chart | month (period)| revenue  | —                 |
| Revenue by Region   | st.bar_chart  | region        | revenue  | —                 |
| Order Channel Mix   | st.bar_chart  | order_channel | orders   | NUNIQUE(order_id) |

---

## Page 2: Fulfillment Performance

### Charts

| Chart                         | Type             | X-axis       | Y-axis      |
|-------------------------------|------------------|--------------|-------------|
| Avg Days to Ship by Method    | st.bar_chart     | ship_method  | avg_days    |
| On-Time % by Region (≤3 days)| st.bar_chart     | region       | on_time_pct |
| Revenue vs Shipping by Store  | st.scatter_chart | shipping     | revenue     |

### Top 10 Slowest Stores Table

| Column         | Source                                    |
|----------------|-------------------------------------------|
| Store          | store_name                                |
| Avg Days to Ship| MEAN(days_to_ship) per store             |
| Status         | Conditional label from avg_days           |

**Conditional Status Rules:**
- avg_days ≤ 3 → **Healthy**
- 3 < avg_days ≤ 5 → **Watch**
- avg_days > 5 → **Critical**

Sorting: descending by avg_days (slowest first). Top 10 only.

---

## Page 3: Returns & Cancellations

### KPI

| KPI              | Formula                                                | Format  |
|------------------|--------------------------------------------------------|---------|
| Revenue at Risk  | SUM(net_revenue) WHERE is_returned = 1                 | $X,XXX  |

### Charts

| Chart                   | Type          | X-axis        | Y-axis       |
|-------------------------|---------------|---------------|--------------|
| Return Rate by Category | st.bar_chart  | category      | return_rate  |
| Cancellation by Channel | st.bar_chart  | order_channel | cancel_rate  |
| Returned Units Trend    | st.line_chart | month         | returned_units|

### Category Detail Table

| Column       | Formula                                          |
|--------------|--------------------------------------------------|
| Category     | groupby key                                      |
| Orders       | NUNIQUE(order_id)                                |
| Returns      | SUM(is_returned)                                 |
| Cancellations| SUM(is_cancelled)                                |
| Revenue      | SUM(net_revenue)                                 |
| Return Rate %| returns / orders * 100, rounded 1 decimal        |
| Cancel Rate %| cancellations / orders * 100, rounded 1 decimal  |

Sorting: descending by Return Rate %.

---

## Page 4: Exception Explorer

### Exception Criteria

A row is an exception if ANY of:
- `days_to_ship > 5`
- `is_returned = 1`
- `is_cancelled = 1`

### Controls

| Control              | Widget           | Behavior                         |
|----------------------|------------------|----------------------------------|
| Metric Definitions   | st.popover       | Shows text definitions           |
| Search               | st.text_input    | Filters by order_id or store_name (case-insensitive contains) |
| Sort by              | st.selectbox     | Options: days_to_ship, net_revenue, order_date, store_name    |
| Download CSV         | st.download_button| Exports visible exceptions       |

### Sort Direction

| Column       | Direction  |
|--------------|------------|
| days_to_ship | descending |
| net_revenue  | descending |
| order_date   | ascending  |
| store_name   | ascending  |

### Empty State

When no exceptions match: `st.warning("No exceptions match the current filters and search criteria.")`

### Table Columns Displayed

Order ID, Order Date, Region, Store Name, Category, Channel, Ship Method, Days to Ship, Returned, Cancelled, Net Revenue

---

## Data Layer

### SQL (sql/orders.sql)

- Static query, no parameters
- Joins ORDER_FACT → STORE_DIM (ORDER_STORE_KEY = STORE_KEY)
- Joins ORDER_FACT → PRODUCT_DIM (PRODUCT_KEY = PRODUCT_KEY)
- Joins ORDER_FACT → DATE_DIM (ORDER_DATE_KEY = DATE_KEY)
- 17 explicit output columns, all aliased lowercase

### Cached Loader (lib/data.py)

- `@st.cache_data(ttl="10m")`
- Reads sql/orders.sql from disk
- Lowercases all column names
- Converts order_date to datetime

---

## Session State Keys

| Key              | Purpose                                    |
|------------------|--------------------------------------------|
| `_raw_df`        | Raw unfiltered DataFrame from loader       |
| `filters_applied`| Dict of currently applied filter values    |

No business records stored beyond the cached loader reference.
