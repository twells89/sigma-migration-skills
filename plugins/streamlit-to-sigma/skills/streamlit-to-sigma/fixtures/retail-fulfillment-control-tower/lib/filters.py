# Sidebar filter logic with deferred apply semantics
# Co-authored with CoCo
import streamlit as st
import pandas as pd


def init_filter_state(df: pd.DataFrame):
    if "filters_applied" not in st.session_state:
        st.session_state["filters_applied"] = {
            "date_range": (df["order_date"].min().date(), df["order_date"].max().date()),
            "regions": [],
            "categories": [],
            "channels": [],
            "statuses": [],
        }


def render_sidebar_filters(df: pd.DataFrame):
    init_filter_state(df)

    all_regions = sorted(df["region"].dropna().unique().tolist())
    all_categories = sorted(df["category"].dropna().unique().tolist())
    all_channels = sorted(df["order_channel"].dropna().unique().tolist())
    all_statuses = sorted(df["order_status"].dropna().unique().tolist())

    min_date = df["order_date"].min().date()
    max_date = df["order_date"].max().date()

    with st.sidebar:
        st.header("Filters")
        with st.form("filter_form"):
            date_range = st.date_input(
                "Date Range",
                value=(min_date, max_date),
                min_value=min_date,
                max_value=max_date,
            )
            regions = st.multiselect("Region", options=all_regions, default=[])
            categories = st.multiselect("Category", options=all_categories, default=[])
            channels = st.multiselect("Order Channel", options=all_channels, default=[])
            statuses = st.multiselect("Order Status", options=all_statuses, default=[])
            submitted = st.form_submit_button("Apply Filters")

        if submitted:
            if len(date_range) == 2:
                st.session_state["filters_applied"] = {
                    "date_range": (date_range[0], date_range[1]),
                    "regions": regions,
                    "categories": categories,
                    "channels": channels,
                    "statuses": statuses,
                }
            else:
                st.session_state["filters_applied"] = {
                    "date_range": (date_range[0], max_date),
                    "regions": regions,
                    "categories": categories,
                    "channels": channels,
                    "statuses": statuses,
                }

        if st.sidebar.button("Reset"):
            st.session_state["filters_applied"] = {
                "date_range": (min_date, max_date),
                "regions": [],
                "categories": [],
                "channels": [],
                "statuses": [],
            }
            st.rerun()


def apply_filters(df: pd.DataFrame) -> pd.DataFrame:
    f = st.session_state.get("filters_applied")
    if f is None:
        return df

    filtered = df.copy()
    start, end = f["date_range"]
    filtered = filtered[
        (filtered["order_date"].dt.date >= start)
        & (filtered["order_date"].dt.date <= end)
    ]
    if f["regions"]:
        filtered = filtered[filtered["region"].isin(f["regions"])]
    if f["categories"]:
        filtered = filtered[filtered["category"].isin(f["categories"])]
    if f["channels"]:
        filtered = filtered[filtered["order_channel"].isin(f["channels"])]
    if f["statuses"]:
        filtered = filtered[filtered["order_status"].isin(f["statuses"])]
    return filtered
