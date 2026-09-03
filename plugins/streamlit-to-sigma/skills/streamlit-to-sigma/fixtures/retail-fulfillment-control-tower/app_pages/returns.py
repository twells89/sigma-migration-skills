# Returns & Cancellations page
# Co-authored with CoCo
import streamlit as st
import pandas as pd
from lib.filters import apply_filters

st.header("Returns & Cancellations")

df = apply_filters(st.session_state["_raw_df"])

if df.empty:
    st.info("No data matches the current filters.")
    st.stop()

revenue_at_risk = df.loc[df["is_returned"] == 1, "net_revenue"].sum()
st.metric("Revenue at Risk (Returned Orders)", f"${revenue_at_risk:,.0f}", border=True)

col1, col2 = st.columns(2)

with col1:
    with st.container(border=True):
        st.subheader("Return Rate by Category")
        cat_return = (
            df.groupby("category", as_index=False)
            .agg(return_rate=("is_returned", "mean"))
            .assign(return_rate=lambda x: x["return_rate"] * 100)
            .sort_values("return_rate", ascending=False)
        )
        st.bar_chart(cat_return, x="category", y="return_rate")

with col2:
    with st.container(border=True):
        st.subheader("Cancellation Rate by Channel")
        chan_cancel = (
            df.groupby("order_channel", as_index=False)
            .agg(cancel_rate=("is_cancelled", "mean"))
            .assign(cancel_rate=lambda x: x["cancel_rate"] * 100)
            .sort_values("cancel_rate", ascending=False)
        )
        st.bar_chart(chan_cancel, x="order_channel", y="cancel_rate")

with st.container(border=True):
    st.subheader("Returned Units Trend")
    returns_trend = (
        df[df["is_returned"] == 1]
        .assign(month=df.loc[df["is_returned"] == 1, "order_date"].dt.to_period("M").dt.to_timestamp())
        .groupby("month", as_index=False)
        .agg(returned_units=("quantity_returned", "sum"))
    )
    if not returns_trend.empty:
        st.line_chart(returns_trend, x="month", y="returned_units")
    else:
        st.info("No returns in selected period.")

with st.container(border=True):
    st.subheader("Category Detail (Ranked by Return Rate)")
    detail = (
        df.groupby("category", as_index=False)
        .agg(
            total_orders=("order_id", "nunique"),
            returns=("is_returned", "sum"),
            cancellations=("is_cancelled", "sum"),
            revenue=("net_revenue", "sum"),
        )
        .assign(
            return_rate=lambda x: (x["returns"] / x["total_orders"] * 100).round(1),
            cancel_rate=lambda x: (x["cancellations"] / x["total_orders"] * 100).round(1),
        )
        .sort_values("return_rate", ascending=False)
    )
    st.dataframe(
        detail.rename(columns={
            "category": "Category",
            "total_orders": "Orders",
            "returns": "Returns",
            "cancellations": "Cancellations",
            "revenue": "Revenue",
            "return_rate": "Return Rate %",
            "cancel_rate": "Cancel Rate %",
        }),
        hide_index=True,
        use_container_width=True,
    )
