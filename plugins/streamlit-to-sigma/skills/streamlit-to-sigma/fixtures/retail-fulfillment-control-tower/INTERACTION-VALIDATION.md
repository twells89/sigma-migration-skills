# INTERACTION-VALIDATION.md — Manual Test Plan

## Test 1: Deferred Apply Behavior

**Steps:**
1. Open the app. Observe that all KPIs and charts reflect the full dataset.
2. In the sidebar, select a single Region (e.g., "West") in the Region multiselect.
3. **Do NOT click "Apply Filters" yet.**
4. Observe that all KPIs, charts, and tables remain unchanged (still showing full dataset).
5. Click "Apply Filters."
6. Observe that all KPIs, charts, and tables now reflect only the "West" region.

**Expected:**
- Step 4: No change in dashboard content after widget interaction alone.
- Step 6: Dashboard updates only after form submission.

---

## Test 2: Reset Behavior

**Steps:**
1. Apply filters: select Region = "West" and Category = "Electronics", click "Apply Filters."
2. Verify the dashboard shows filtered results (fewer orders, filtered KPIs).
3. Click the "Reset" button below the form.
4. Observe that the dashboard returns to the full unfiltered state.
5. Verify all multiselects show empty defaults (meaning "all").
6. Verify the date range returns to full min/max of the data.

**Expected:**
- Step 4: All KPIs and charts return to original unfiltered values.
- Step 5-6: Filter controls reset to their defaults.

---

## Test 3: Cross-Page Filter Persistence

**Steps:**
1. Navigate to "Executive Overview."
2. Apply filters: Region = "East", click "Apply Filters."
3. Verify the Executive Overview shows East-only data.
4. Navigate to "Fulfillment Performance" using the sidebar nav.
5. Verify that Fulfillment Performance also shows East-only data (same filters applied).
6. Navigate to "Returns & Cancellations."
7. Verify Returns page also reflects East-only data.
8. Navigate to "Exception Explorer."
9. Verify exceptions are filtered to East region only.

**Expected:**
- Filters persist across all four pages without re-applying.
- Session state `filters_applied` is shared globally.

---

## Test 4: Empty State (Exception Explorer)

**Steps:**
1. Navigate to "Exception Explorer."
2. In the Search text input, type a nonsense string like "ZZZZZ_NONEXISTENT".
3. Observe the result.

**Expected:**
- The warning message appears: "No exceptions match the current filters and search criteria."
- No table is displayed.
- No download button is displayed.

**Alternative empty-state test:**
1. Apply very restrictive filters that produce zero rows (e.g., a single-day date range with no orders).
2. Navigate to Exception Explorer.
3. Verify the empty state warning appears.

---

## Test 5: Popover (Exception Explorer)

**Steps:**
1. Navigate to "Exception Explorer."
2. Locate the "Metric Definitions" button/label.
3. Click it.
4. Observe that a popover opens showing definitions for:
   - Days to Ship > 5
   - Is Returned = 1
   - Is Cancelled = 1
5. Click outside the popover or click the button again.
6. Verify the popover closes.

**Expected:**
- Popover displays markdown-formatted definitions.
- Popover does not interfere with other page elements.

---

## Test 6: CSV Download (Exception Explorer)

**Steps:**
1. Navigate to "Exception Explorer."
2. Ensure there are exceptions displayed in the table (use default filters if needed).
3. Note the row count caption (e.g., "1,234 exception rows").
4. Click "Download CSV."
5. Open the downloaded file (`exceptions_export.csv`).
6. Verify:
   - The CSV has column headers matching the displayed table columns.
   - The row count in the CSV matches the caption count.
   - Data values match what is displayed on screen.

**Expected:**
- A valid CSV file downloads immediately.
- File contains all exception rows visible in the current filtered/searched state.
- Filename is `exceptions_export.csv`.

---

## Test 7: Sort Selector (Exception Explorer)

**Steps:**
1. Navigate to "Exception Explorer."
2. Default sort should be "days_to_ship" (descending — largest first).
3. Change the sort selector to "net_revenue."
4. Verify the table re-sorts with highest revenue exceptions first.
5. Change to "store_name."
6. Verify alphabetical ascending order (A→Z).
7. Change to "order_date."
8. Verify chronological ascending order (oldest first).

**Expected:**
- Descending sort: days_to_ship, net_revenue (numeric, largest first)
- Ascending sort: order_date, store_name (chronological / alphabetical)

---

## Test 8: Fulfillment Status Labels

**Steps:**
1. Navigate to "Fulfillment Performance."
2. Locate the "Top 10 Slowest Stores" table.
3. Verify:
   - Stores with Avg Days to Ship ≤ 3.0 show "Healthy"
   - Stores with Avg Days to Ship between 3.01 and 5.0 show "Watch"
   - Stores with Avg Days to Ship > 5.0 show "Critical"
4. Cross-check at least one value manually against the data.

**Expected:**
- Labels are deterministic based on the threshold rules.
- The table is sorted slowest-first (highest avg_days at top).

---

## Test 9: SLA Progress Bar (Executive Overview)

**Steps:**
1. Navigate to "Executive Overview."
2. Locate the "SLA: Shipped Within 3 Days" section.
3. Verify a progress bar is displayed.
4. The text reads "{X.X}% on-time" where X.X is between 0-100.
5. Apply a filter that includes only fast-shipping regions.
6. Verify the SLA percentage increases.

**Expected:**
- Progress bar visually fills proportional to the percentage.
- Value updates when filters change.

---

## Screenshot Checklist

| Screenshot                              | Viewport   | State                         |
|-----------------------------------------|------------|-------------------------------|
| Executive Overview (default)            | 1440×1000  | No filters applied            |
| Fulfillment Performance (default)       | 1440×1000  | No filters applied            |
| Returns & Cancellations (default)       | 1440×1000  | No filters applied            |
| Exception Explorer (default)            | 1440×1000  | No filters applied            |
| Executive Overview (one region)         | 1440×1000  | Region = single value applied |
| Exception Explorer (empty)             | 1440×1000  | Search produces zero results  |
