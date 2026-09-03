# Fulfillment Performance page
# Co-authored with CoCo
import streamlit as st
import pandas as pd
from lib.filters import apply_filters
from lib.metrics import fulfillment_status_label

st.header("Fulfillment Performance")

df = apply_filters(st.session_state["_raw_df"])

if df.empty:
    st.info("No data matches the current filters.")
    st.stop()

col1, col2 = st.columns(2)

with col1:
    with st.container(border=True):
        st.subheader("Avg Days to Ship by Method")
        by_method = (
            df.groupby("ship_method", as_index=False)
            .agg(avg_days=("days_to_ship", "mean"))
            .sort_values("avg_days", ascending=False)
        )
        st.bar_chart(by_method, x="ship_method", y="avg_days")

with col2:
    with st.container(border=True):
        st.subheader("On-Time % by Region (≤3 days)")
        region_grp = df.groupby("region", as_index=False).apply(
            lambda g: pd.Series({
                "on_time_pct": (g["days_to_ship"] <= 3).sum() / len(g) * 100
            }),
            include_groups=False,
        )
        st.bar_chart(region_grp, x="region", y="on_time_pct")

with st.container(border=True):
    st.subheader("Revenue vs Shipping Cost by Store")
    store_scatter = (
        df.groupby("store_name", as_index=False)
        .agg(revenue=("net_revenue", "sum"), shipping=("shipping_amount", "sum"))
    )
    st.scatter_chart(store_scatter, x="shipping", y="revenue")

with st.container(border=True):
    st.subheader("Top 10 Slowest Stores")
    store_speed = (
        df.groupby("store_name", as_index=False)
        .agg(avg_days=("days_to_ship", "mean"))
        .sort_values("avg_days", ascending=False)
        .head(10)
    )
    store_speed["status"] = store_speed["avg_days"].apply(fulfillment_status_label)
    st.dataframe(
        store_speed.rename(columns={
            "store_name": "Store",
            "avg_days": "Avg Days to Ship",
            "status": "Status",
        }),
        hide_index=True,
        use_container_width=True,
    )
