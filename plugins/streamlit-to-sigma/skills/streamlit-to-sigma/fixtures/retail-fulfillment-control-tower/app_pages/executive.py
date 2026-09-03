# Executive Overview page
# Co-authored with CoCo
import streamlit as st
import pandas as pd
from lib.filters import apply_filters
from lib.metrics import compute_kpis, sla_on_time_pct

st.header("Executive Overview")

df = apply_filters(st.session_state["_raw_df"])

kpis = compute_kpis(df)

with st.container(horizontal=True):
    st.metric("Net Revenue", f"${kpis['net_revenue']:,.0f}", border=True)
    st.metric("Net Profit", f"${kpis['net_profit']:,.0f}", border=True)
    st.metric("Orders", f"{kpis['total_orders']:,}", border=True)

with st.container(horizontal=True):
    st.metric("Return Rate", f"{kpis['return_rate']:.1f}%", border=True)
    st.metric("Cancellation Rate", f"{kpis['cancel_rate']:.1f}%", border=True)
    st.metric("Avg Days to Ship", f"{kpis['avg_days_to_ship']:.1f}", border=True)

sla_pct = sla_on_time_pct(df, threshold=3)
st.subheader("SLA: Shipped Within 3 Days")
st.progress(min(sla_pct / 100, 1.0), text=f"{sla_pct:.1f}% on-time")

col1, col2 = st.columns(2)

with col1:
    with st.container(border=True):
        st.subheader("Monthly Revenue")
        monthly = (
            df.assign(month=df["order_date"].dt.to_period("M").dt.to_timestamp())
            .groupby("month", as_index=False)
            .agg(revenue=("net_revenue", "sum"))
        )
        st.line_chart(monthly, x="month", y="revenue")

with col2:
    with st.container(border=True):
        st.subheader("Revenue by Region")
        by_region = df.groupby("region", as_index=False).agg(revenue=("net_revenue", "sum"))
        st.bar_chart(by_region, x="region", y="revenue")

with st.container(border=True):
    st.subheader("Order Channel Mix")
    channel_mix = df.groupby("order_channel", as_index=False).agg(orders=("order_id", "nunique"))
    st.bar_chart(channel_mix, x="order_channel", y="orders")
