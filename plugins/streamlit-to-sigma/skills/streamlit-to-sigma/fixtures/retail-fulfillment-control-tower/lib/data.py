# Cached data loader for the retail fulfillment control tower
# Co-authored with CoCo
import streamlit as st
import pandas as pd
import os


@st.cache_data(ttl="10m")
def load_orders(_conn) -> pd.DataFrame:
    sql_path = os.path.join(os.path.dirname(__file__), "..", "sql", "orders.sql")
    with open(sql_path, "r") as f:
        sql = f.read()
    df = _conn.query(sql)
    df.columns = [c.lower() for c in df.columns]
    df["order_date"] = pd.to_datetime(df["order_date"])
    return df
