"""Shared Streamlit state and helpers (mirrors r/R/ui_helpers.R)."""
from __future__ import annotations

import copy
from datetime import datetime, timezone

import pandas as pd
import plotly.graph_objects as go
import streamlit as st

from .data import load_data, player_frame, project_root, refresh_data
from .model import default_model_path, read_model, score_players

# Validated categorical pair (dataviz reference palette, slots 1-2).
CONF_COLORS = {"AFC": "#2a78d6", "NFC": "#eb6834"}
ACCENT = "#2a78d6"
MUTED = "#b4b2a9"
POSITION_ORDER = ["QB", "RB", "WR", "TE", "DL", "LB", "DB", "K", "P"]

GENERIC_STATS = {
    "fantasy_points_ppr": "Fantasy pts (PPR)", "passing_yards": "Pass yds",
    "rushing_yards": "Rush yds", "receiving_yards": "Rec yds",
    "def_tackles_solo": "Tackles", "def_sacks": "Sacks", "def_interceptions": "INTs",
}
TREND_STATS = {
    "fantasy_points_ppr": "Fantasy points (PPR)", "passing_yards": "Passing yards",
    "passing_epa": "Passing EPA", "rushing_yards": "Rushing yards", "carries": "Carries",
    "receiving_yards": "Receiving yards", "targets": "Targets", "receptions": "Receptions",
    "def_tackles_solo": "Solo tackles", "def_sacks": "Sacks", "def_qb_hits": "QB hits",
    "def_pass_defended": "Passes defended", "fg_made": "FG made", "pt_net_yards": "Punt net yards",
}
DEFAULT_TREND = {"QB": "passing_yards", "RB": "rushing_yards", "WR": "receiving_yards",
                 "TE": "receiving_yards", "DL": "def_sacks", "LB": "def_tackles_solo",
                 "DB": "def_tackles_solo", "K": "fg_made", "P": "pt_net_yards"}

ROOT = project_root()


@st.cache_resource(show_spinner="Loading 2026 data…", max_entries=2)
def _load(version: int):
    return load_data(ROOT)


def get_data():
    st.session_state.setdefault("data_version", 0)
    return _load(st.session_state["data_version"])


@st.cache_resource(max_entries=8)
def _frame(version: int, weeks: tuple[int, int]):
    return player_frame(_load(version), weeks)


def get_frame(weeks: tuple[int, int]) -> pd.DataFrame:
    """Player rows for a week range, cached per data version."""
    return _frame(st.session_state.get("data_version", 0), tuple(weeks))


def init_state() -> None:
    if "model" not in st.session_state:
        m = read_model(default_model_path(ROOT))
        st.session_state["model"] = m              # working model, used by both pages
        st.session_state["saved_model"] = copy.deepcopy(m)  # baseline for rank movement
        st.session_state["ui_version"] = 0


def bump_ui() -> None:
    st.session_state["ui_version"] = st.session_state.get("ui_version", 0) + 1


def fmt_fetched(meta: dict) -> str:
    try:
        t = datetime.strptime(meta["fetched_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        return t.astimezone().strftime("%b %d, %Y %H:%M")
    except (KeyError, ValueError, TypeError):
        return "unknown"


def data_status_text(meta: dict) -> str:
    return f"{meta.get('season')} season · through Week {meta.get('latest_week', '?')} · data as of {fmt_fetched(meta)}"


def refresh_button(key: str) -> None:
    if st.button("Refresh data", key=key, type="primary", icon=":material/refresh:", width="stretch"):
        with st.status("Refreshing 2026 data…", expanded=False) as status:
            try:
                refresh_data(ROOT, progress=lambda msg: status.update(label=msg))
                st.session_state["data_version"] = st.session_state.get("data_version", 0) + 1
                st.session_state["refresh_msg"] = ("success", "Data refreshed")
            except Exception as e:  # keep existing cache
                st.session_state["refresh_msg"] = ("error", f"Refresh failed; existing data kept. {e}")
        st.rerun()
    msg = st.session_state.pop("refresh_msg", None)
    if msg:
        (st.success if msg[0] == "success" else st.error)(msg[1])


def is_pct_label(label: str) -> bool:
    return "%" in label


def format_metric(x, label: str) -> str:
    if x is None or pd.isna(x):
        return "—"
    return f"{100 * x:.1f}%" if is_pct_label(label) else f"{x:.2f}"


def style_fig(fig: go.Figure, height: int | None = None) -> go.Figure:
    fig.update_layout(
        paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
        font=dict(family="system-ui, -apple-system, Segoe UI, sans-serif", size=12),
        margin=dict(l=10, r=20, t=10, b=40),
        legend=dict(orientation="h", y=1.02, x=0, yanchor="bottom"),
    )
    fig.update_xaxes(gridcolor="rgba(127,127,127,.2)", zerolinecolor="rgba(127,127,127,.4)")
    fig.update_yaxes(gridcolor="rgba(127,127,127,.2)", zerolinecolor="rgba(127,127,127,.4)")
    if height:
        fig.update_layout(height=height)
    return fig


PLOTLY_CONFIG = {"displaylogo": False, "modeBarButtonsToRemove": ["lasso2d", "select2d"]}


def metric_wide(breakdown: pd.DataFrame, pos: str) -> tuple[pd.DataFrame, dict[str, str]]:
    b = breakdown[breakdown["pos_group"] == pos]
    labels = dict(zip(b["key"], b["label"]))
    wide = b.pivot_table(index="player_id", columns="key", values="value", aggfunc="first", dropna=False)
    return wide.reindex(columns=list(labels)), labels


def preview_scores(players: pd.DataFrame, pos: str, model: dict, saved: dict) -> pd.DataFrame:
    p = players[players["pos_group"] == pos]
    cur, _ = score_players(p, model)
    old, _ = score_players(p, saved)
    cur = cur.merge(old[["player_id", "pos_rank"]].rename(columns={"pos_rank": "saved_rank"}),
                    on="player_id", how="left")
    return cur.merge(p[["player_id", "player_display_name", "team"]], on="player_id", how="left")
