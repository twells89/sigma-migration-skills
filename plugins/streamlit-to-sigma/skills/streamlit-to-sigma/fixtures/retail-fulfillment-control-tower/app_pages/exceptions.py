# Exception Explorer page
# Co-authored with CoCo
import streamlit as st
import pandas as pd
from lib.filters import apply_filters

st.header("Exception Explorer")

df = apply_filters(st.session_state["_raw_df"])

exceptions = df[
    (df["days_to_ship"] > 5) | (df["is_returned"] == 1) | (df["is_cancelled"] == 1)
].copy()

with st.popover("Metric Definitions"):
    st.markdown("""
**Days to Ship > 5** — Orders that took more than 5 days from order date to ship date.

**Is Returned = 1** — Orders where the customer returned the product.

**Is Cancelled = 1** — Orders that were cancelled before fulfillment.
    """)

col1, col2 = st.columns([2, 1])
with col1:
    search_text = st.text_input("Search by Order ID or Store Name", value="")
with col2:
    sort_col = st.selectbox(
        "Sort by",
        options=["days_to_ship", "net_revenue", "order_date", "store_name"],
        index=0,
    )

if search_text:
    mask = (
        exceptions["order_id"].str.contains(search_text, case=False, na=False)
        | exceptions["store_name"].str.contains(search_text, case=False, na=False)
    )
    exceptions = exceptions[mask]

ascending = sort_col in ("order_date", "store_name")
exceptions = exceptions.sort_values(sort_col, ascending=ascending)

if exceptions.empty:
    st.warning("No exceptions match the current filters and search criteria.")
else:
    st.caption(f"{len(exceptions):,} exception rows")
    display_cols = [
        "order_id", "order_date", "region", "store_name", "category",
        "order_channel", "ship_method", "days_to_ship", "is_returned",
        "is_cancelled", "net_revenue",
    ]
    st.dataframe(
        exceptions[display_cols].rename(columns={
            "order_id": "Order ID",
            "order_date": "Order Date",
            "region": "Region",
            "store_name": "Store Name",
            "category": "Category",
            "order_channel": "Channel",
            "ship_method": "Ship Method",
            "days_to_ship": "Days to Ship",
            "is_returned": "Returned",
            "is_cancelled": "Cancelled",
            "net_revenue": "Net Revenue",
        }),
        hide_index=True,
        use_container_width=True,
    )

    csv = exceptions[display_cols].to_csv(index=False)
    st.download_button(
        label="Download CSV",
        data=csv,
        file_name="exceptions_export.csv",
        mime="text/csv",
    )
