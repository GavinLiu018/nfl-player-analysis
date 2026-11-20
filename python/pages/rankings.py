"""Rankings page: filters, sortable table, charts and player detail."""
import numpy as np
import pandas as pd
import plotly.graph_objects as go
import streamlit as st

from nflrank.model import ranked_players
from nflrank.ui import (
    ACCENT, CONF_COLORS, DEFAULT_TREND, GENERIC_STATS, MUTED, PLOTLY_CONFIG, POSITION_ORDER,
    TREND_STATS, data_status_text, format_metric, get_data, get_frame, init_state, is_pct_label,
    metric_wide, refresh_button, style_fig,
)

init_state()
data = get_data()
model = st.session_state["model"]
teams = data.teams


def prune(key: str, valid) -> None:
    """Drop selections that are no longer valid options (e.g. after changing conference)."""
    if key in st.session_state:
        st.session_state[key] = [v for v in st.session_state[key] if v in set(valid)]


# ---- sidebar filters ---------------------------------------------------------
with st.sidebar:
    refresh_button("refresh_rankings")
    st.caption(data_status_text(data.meta))
    pos = st.multiselect("Position", POSITION_ORDER, placeholder="All positions", key="f_pos")
    conf = st.pills("Conference", ["AFC", "NFC"], selection_mode="multi", key="f_conf") or []
    t = teams[teams["conference"].isin(conf)] if conf else teams
    divs = sorted(t["division"].unique())
    prune("f_div", divs)
    div = st.multiselect("Division", divs, placeholder="All divisions", key="f_div")
    t = t[t["division"].isin(div)] if div else t
    t = t.sort_values("name")
    names = dict(zip(t["abbr"], t["name"]))
    prune("f_team", names)
    team = st.multiselect("Team", list(names), format_func=lambda a: f"{names[a]} ({a})",
                          placeholder="All teams", key="f_team")
    search = st.text_input("Player search", placeholder="Name contains…", key="f_search")
    wk = data.weeks_available or [1]
    weeks = (st.slider("Weeks", min(wk), max(wk), (min(wk), max(wk)))
             if len(wk) > 1 else (wk[0], wk[0]))
    min_games = st.number_input("Minimum games", min_value=0, max_value=20, value=0, step=1, key="f_min_games")
    qual_only = st.toggle("Qualified players only", value=True, key="f_qual")

# ---- scoring and filtering -----------------------------------------------------
players, breakdown = ranked_players(get_frame(weeks), model)
p = players
if pos:
    p = p[p["pos_group"].isin(pos)]
if conf:
    p = p[p["conference"].isin(conf)]
if div:
    p = p[p["division"].isin(div)]
if team:
    p = p[p["team"].isin(team)]
if search.strip():
    p = p[p["player_display_name"].str.lower().str.contains(search.strip().lower(), regex=False, na=False)]
p = p[p["games"].fillna(0) >= min_games]
if qual_only:
    p = p[p["qualified"].fillna(False).astype(bool)]
p = p.assign(_s=p["score"].fillna(-np.inf)).sort_values(["_s", "player_display_name"], ascending=[False, True])
p = p.drop(columns="_s").reset_index(drop=True)
p["rank"] = np.arange(1, len(p) + 1)
single_pos = pos[0] if len(pos) == 1 else None

st.title("NFL Player Rankings")
st.caption(f"{len(p)} players · {data_status_text(data.meta)}"
           + ("" if weeks == (min(wk), max(wk)) else f" · weeks {weeks[0]}–{weeks[1]} only"))

# ---- table ---------------------------------------------------------------------
table = pd.DataFrame({
    "rank": p["rank"], "headshot": p["headshot_url"], "player": p["player_display_name"],
    "team": p["team"], "pos": p["position"], "games": p["games"], "score": p["score"],
    "pos_rank": [f"{g}{int(r)}" if pd.notna(r) else "—" for g, r in zip(p["pos_group"], p["pos_rank"])],
    "nq": np.where(p["qualified"].fillna(False).astype(bool), "", "NQ"),
})
col_cfg = {
    "rank": st.column_config.NumberColumn("#", width="small"),
    "headshot": st.column_config.ImageColumn("", width="small"),
    "player": st.column_config.TextColumn("Player", width="medium"),
    "team": st.column_config.TextColumn("Team", width="small"),
    "pos": st.column_config.TextColumn("Pos", width="small"),
    "games": st.column_config.NumberColumn("G", format="%d", width="small"),
    "score": st.column_config.ProgressColumn("Score", min_value=0, max_value=100, format="%.1f"),
    "pos_rank": st.column_config.TextColumn("Pos rank", width="small"),
    "nq": st.column_config.TextColumn("", width="small"),
}
if single_pos:
    wide, labels = metric_wide(breakdown, single_pos)
    vals = wide.reindex(p["player_id"]).reset_index(drop=True)
    for k, lab in labels.items():
        table[k] = vals[k].to_numpy()
        col_cfg[k] = st.column_config.NumberColumn(lab, format="percent" if is_pct_label(lab) else "%.2f")
else:
    for k, lab in GENERIC_STATS.items():
        table[k] = p[k].to_numpy()
        col_cfg[k] = st.column_config.NumberColumn(lab, format="localized")

tab_table, tab_bar, tab_scatter = st.tabs(["Table", "Top players", "Scatter"])
with tab_table:
    if table.empty:
        st.info("No players match these filters.")
        event = None
    else:
        event = st.dataframe(table, column_config=col_cfg, hide_index=True, width="stretch",
                             height=600, on_select="rerun", selection_mode="single-row", key="rank_table")

with tab_bar:
    top_n = st.number_input("Show top", min_value=5, max_value=100, value=25, step=5, key="top_n")
    d = p[p["score"].notna()].head(int(top_n))
    if d.empty:
        st.info("No players match these filters.")
    else:
        labels = [f"{r}. {n} ({ps}, {tm})" for r, n, ps, tm in
                  zip(d["rank"], d["player_display_name"], d["position"], d["team"])]
        d = d.assign(label=labels)
        fig = go.Figure()
        for cf, color in CONF_COLORS.items():
            s = d[d["conference"] == cf]
            if len(s):
                fig.add_bar(x=s["score"], y=s["label"], orientation="h", name=cf, marker_color=color,
                            customdata=np.stack([s["player_display_name"], s["team_name"].fillna(""),
                                                 s["division"].fillna("")], axis=1),
                            hovertemplate="%{customdata[0]}<br>%{customdata[1]} · %{customdata[2]}"
                                          "<br>Score %{x:.1f}<extra></extra>")
        fig.update_layout(barmode="overlay", bargap=0.25)
        fig.update_xaxes(title="Score", range=[0, 100])
        fig.update_yaxes(title="", categoryorder="array", categoryarray=labels[::-1])
        st.plotly_chart(style_fig(fig, max(320, 22 * len(d) + 80)), width="stretch", config=PLOTLY_CONFIG)

with tab_scatter:
    if single_pos:
        choices = {"score": "Score", **{m["key"]: m["label"] for m in model["positions"][single_pos]["metrics"]}}
    else:
        choices = {"score": "Score", **GENERIC_STATS, "games": "Games"}
    keys = list(choices)
    c1, c2 = st.columns(2)
    xk = c1.selectbox("X axis", keys, index=min(1, len(keys) - 1), format_func=choices.get,
                      key=f"sx_{single_pos}")
    yk = c2.selectbox("Y axis", keys, index=0, format_func=choices.get, key=f"sy_{single_pos}")

    def getv(key):
        if key in p.columns:
            return p[key].to_numpy(dtype="float64")
        b = breakdown[(breakdown["key"] == key) & (breakdown["pos_group"] == single_pos)]
        return b.set_index("player_id")["value"].reindex(p["player_id"]).to_numpy(dtype="float64")

    sd = p.assign(xv=getv(xk), yv=getv(yk)).dropna(subset=["xv", "yv"])
    if sd.empty:
        st.info("No players with both values.")
    else:
        fig = go.Figure()
        for cf, color in CONF_COLORS.items():
            s = sd[sd["conference"] == cf]
            if len(s):
                fig.add_scatter(
                    x=s["xv"], y=s["yv"], mode="markers", name=cf,
                    marker=dict(color=color, size=9, opacity=0.85, line=dict(color="#fcfcfb", width=1)),
                    customdata=np.stack([s["player_display_name"], s["position"], s["team"],
                                         s["score"].round(1).astype(str)], axis=1),
                    hovertemplate="%{customdata[0]} (%{customdata[1]}, %{customdata[2]})"
                                  "<br>x: %{x:.4g}<br>y: %{y:.4g}<br>Score %{customdata[3]}<extra></extra>")
        fig.update_xaxes(title=choices[xk])
        fig.update_yaxes(title=choices[yk])
        st.plotly_chart(style_fig(fig, 600), width="stretch", config=PLOTLY_CONFIG)

# ---- player detail ---------------------------------------------------------------
st.divider()
if p.empty:
    st.stop()
rows = event.selection.rows if event is not None else []
sp = p.iloc[rows[0]] if rows and rows[0] < len(p) else p.iloc[0]
score_txt = "—" if pd.isna(sp["score"]) else f"{sp['score']:.1f}"
rank_txt = " (not qualified)" if pd.isna(sp["pos_rank"]) else f" · #{int(sp['pos_rank'])} {sp['pos_group']}"
st.subheader(f"{sp['player_display_name']} · {sp['position']} · {sp['team_name'] or sp['team']}")
st.caption(f"Score {score_txt}{rank_txt}" + ("" if rows else " · select a row in the table to change player"))

c1, c2 = st.columns(2)
with c1:
    st.markdown("**Score breakdown** (percentile vs qualified players at the position)")
    b = breakdown[(breakdown["player_id"] == sp["player_id"]) & (breakdown["pos_group"] == sp["pos_group"])]
    if b.empty:
        st.info("No metrics.")
    else:
        hover = [f"{lab}<br>Value: {format_metric(v, lab)}<br>Percentile: "
                 f"{'—' if pd.isna(pc) else round(100 * pc, 1)}<br>Weight: {w:g}"
                 + ("" if hib else "<br>(lower is better)")
                 for lab, v, pc, w, hib in zip(b["label"], b["value"], b["pct"], b["weight"], b["higher_is_better"])]
        fig = go.Figure(go.Bar(x=(100 * b["pct"]).round(1), y=b["label"], orientation="h",
                               marker_color=[ACCENT if w > 0 else MUTED for w in b["weight"]],
                               hovertext=hover, hoverinfo="text"))
        fig.update_xaxes(title="Percentile", range=[0, 100])
        fig.update_yaxes(title="", autorange="reversed")
        st.plotly_chart(style_fig(fig, 320), width="stretch", config=PLOTLY_CONFIG)
with c2:
    stat_keys = list(TREND_STATS)
    stat = st.selectbox("Weekly trend", stat_keys, format_func=TREND_STATS.get,
                        index=stat_keys.index(DEFAULT_TREND.get(sp["pos_group"], "fantasy_points_ppr")),
                        key=f"trend_{sp['player_id']}")
    w = data.week[data.week["player_id"] == sp["player_id"]].sort_values("week")
    if w.empty or stat not in w.columns:
        st.info("No weekly data.")
    else:
        fig = go.Figure(go.Scatter(
            x=w["week"], y=w[stat], mode="lines+markers", line=dict(color=ACCENT, width=2),
            marker=dict(color=ACCENT, size=8), customdata=w["opponent_team"],
            hovertemplate="Week %{x} vs %{customdata}<br>" + TREND_STATS[stat] + ": %{y:.2f}<extra></extra>"))
        fig.update_xaxes(title="Week", dtick=1)
        fig.update_yaxes(title=TREND_STATS[stat])
        st.plotly_chart(style_fig(fig, 300), width="stretch", config=PLOTLY_CONFIG)
