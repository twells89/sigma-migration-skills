import streamlit as st

conn = st.connection("snowflake")


@st.cache_data
def load_sales():
    return conn.query(
        """
        SELECT
          ORDER_DATE AS "Order Date",
          REGION AS "Region",
          CATEGORY AS "Category",
          ORDER_ID AS "Order Id",
          REVENUE AS "Revenue",
          PROFIT AS "Profit"
        FROM EXAMPLE_DB.ANALYTICS.RETAIL_SALES
        """
    )


df = load_sales()
regions = sorted(df["Region"].dropna().unique().tolist())
selected_regions = st.sidebar.multiselect(
    "Region", regions, default=regions
)
filtered = df[df["Region"].isin(selected_regions)].copy()

st.title("Retail Sales Dashboard")
total_revenue = filtered["Revenue"].sum()
total_profit = filtered["Profit"].sum()
order_count = filtered["Order Id"].nunique()

col1, col2, col3 = st.columns(3)
col1.metric("Revenue", f"${total_revenue:,.0f}")
col2.metric("Profit", f"${total_profit:,.0f}")
col3.metric("Orders", f"{order_count:,}")

tab_overview, tab_detail = st.tabs(["Overview", "Detail"])
with tab_overview:
    st.bar_chart(filtered, x="Category", y="Revenue")
with tab_detail:
    st.dataframe(filtered)
