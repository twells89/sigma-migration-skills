# Metric computation helpers
# Co-authored with CoCo
import pandas as pd


def compute_kpis(df: pd.DataFrame) -> dict:
    total_orders = df["order_id"].nunique()
    net_revenue = df["net_revenue"].sum()
    net_profit = df["net_profit"].sum()
    total_returned = df["is_returned"].sum()
    total_cancelled = df["is_cancelled"].sum()
    total_rows = len(df)
    return_rate = (total_returned / total_rows * 100) if total_rows > 0 else 0.0
    cancel_rate = (total_cancelled / total_rows * 100) if total_rows > 0 else 0.0
    avg_days_to_ship = df["days_to_ship"].mean() if total_rows > 0 else 0.0
    return {
        "net_revenue": net_revenue,
        "net_profit": net_profit,
        "total_orders": total_orders,
        "return_rate": return_rate,
        "cancel_rate": cancel_rate,
        "avg_days_to_ship": avg_days_to_ship,
    }


def sla_on_time_pct(df: pd.DataFrame, threshold: int = 3) -> float:
    if len(df) == 0:
        return 0.0
    on_time = (df["days_to_ship"] <= threshold).sum()
    return on_time / len(df) * 100


def fulfillment_status_label(avg_days: float) -> str:
    if avg_days <= 3:
        return "Healthy"
    elif avg_days <= 5:
        return "Watch"
    else:
        return "Critical"
