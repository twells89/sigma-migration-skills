# Retail Fulfillment & Returns Control Tower - main entry point
# Co-authored with CoCo
import os
import streamlit as st
from lib.data import load_orders
from lib.filters import render_sidebar_filters, apply_filters

st.set_page_config(
    page_title="Retail Fulfillment & Returns Control Tower",
    page_icon=":material/local_shipping:",
    layout="wide",
)

conn = st.connection("snowflake", ttl=os.getenv("SNOWFLAKE_CONNECTION_TTL"))

with st.spinner("Loading order data..."):
    raw_df = load_orders(conn)

st.session_state["_raw_df"] = raw_df

render_sidebar_filters(raw_df)

page = st.navigation([
    st.Page("app_pages/executive.py", title="Executive Overview", icon=":material/dashboard:"),
    st.Page("app_pages/fulfillment.py", title="Fulfillment Performance", icon=":material/local_shipping:"),
    st.Page("app_pages/returns.py", title="Returns & Cancellations", icon=":material/assignment_return:"),
    st.Page("app_pages/exceptions.py", title="Exception Explorer", icon=":material/warning:"),
])

page.run()
