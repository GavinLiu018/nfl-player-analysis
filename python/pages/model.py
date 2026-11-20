"""Model page: per-position metrics, weights, direction, qualification and custom metrics."""
import copy
import re

import numpy as np
import pandas as pd
import streamlit as st

from nflrank.model import (
    default_model_path, eval_metric, list_saved_models, numeric_columns, read_model, save_model,
    validate_expr,
)
from nflrank.ui import (
    POSITION_ORDER, ROOT, bump_ui, get_data, init_state, preview_scores, refresh_button,
)

init_state()
data = get_data()
model = st.session_state["model"]
v = st.session_state["ui_version"]
cols = numeric_columns(data.players)


def apply_model(m: dict, msg: str) -> None:
    st.session_state["model"] = m
    st.session_state["saved_model"] = copy.deepcopy(m)
    st.session_state["flash"] = msg
    bump_ui()
    st.rerun()


# ---- sidebar -----------------------------------------------------------------
with st.sidebar:
    refresh_button("refresh_model")
    pos = st.selectbox("Position", POSITION_ORDER, key="m_pos")
    norm_opts = ["percentile", "zscore"]
    model["normalization"] = st.radio(
        "Normalization", norm_opts, index=norm_opts.index(model.get("normalization", "percentile")),
        format_func={"percentile": "Percentile", "zscore": "Z-score"}.get, horizontal=True, key=f"norm_v{v}")

    st.markdown("**Qualification**")
    q = model["positions"][pos]["qualify"]
    q["min_games"] = float(st.number_input("Minimum games", min_value=0.0, value=float(q["min_games"]),
                                           step=1.0, format="%.0f", key=f"mg_{pos}_v{v}"))
    ve = st.text_input("Volume expression", value=q["volume"], key=f"ve_{pos}_v{v}")
    chk = validate_expr(ve, cols)
    if chk.ok:
        q["volume"] = ve
    else:
        st.error(chk.error)
    q["min_volume"] = float(st.number_input("Minimum volume", min_value=0.0, value=float(q["min_volume"]),
                                            step=0.5, format="%.1f", key=f"mv_{pos}_v{v}"))

    st.divider()
    st.markdown("**Saved models**")
    st.caption(f"Active: **{model.get('name', 'Untitled')}**")
    saved = list_saved_models(ROOT)
    options = ["__default__", *saved]
    choice = st.selectbox("Saved models", options, label_visibility="collapsed",
                          format_func=lambda k: "Default model" if k == "__default__" else k, key="m_load")
    b1, b2 = st.columns(2)
    if b1.button("Load", width="stretch"):
        path = default_model_path(ROOT) if choice == "__default__" else saved[choice]
        try:
            m = read_model(path)
            bad = [f"{x['label']}: {validate_expr(x['expr'], cols).error}"
                   for s in m["positions"].values() for x in s["metrics"] if not validate_expr(x["expr"], cols).ok]
            if bad:
                st.error("Model has invalid metrics: " + "; ".join(bad))
            else:
                apply_model(m, f'Loaded "{m["name"]}"')
        except Exception as e:
            st.error(f"Could not load: {e}")
    if b2.button("Reset", width="stretch", help="Reset to the default model"):
        apply_model(read_model(default_model_path(ROOT)), "Default model restored")
    name = st.text_input("Save as", placeholder="e.g. Efficiency", key="m_save_name")
    if st.button("Save model", type="primary", icon=":material/save:"):
        try:
            path = save_model(model, ROOT, name)
            model["name"] = name.strip()
            st.session_state["saved_model"] = copy.deepcopy(model)
            st.session_state["flash"] = f"Saved to {path}"
            st.rerun()
        except ValueError as e:
            st.error(str(e))
    st.caption("Saved to config/models/. The R app can load the same files.")

flash = st.session_state.pop("flash", None)
if flash:
    st.toast(flash)

st.title("Ranking model")
left, right = st.columns([7, 5], gap="large")

# ---- metric rows ---------------------------------------------------------------
with left:
    st.subheader(f"{pos} metrics and weights")
    st.caption("Each metric is converted to a percentile against qualified players at this position. "
               "The score is the weighted average, 0–100.")
    metrics = model["positions"][pos]["metrics"]
    for i, m in enumerate(metrics):
        c0, c1, c2, c3 = st.columns([0.4, 3, 2.3, 2.8], vertical_alignment="center")
        m["include"] = c0.checkbox("Include", value=m["include"], key=f"inc_{pos}_{i}_v{v}",
                                   label_visibility="collapsed")
        c1.markdown(f"**{m['label']}**{' :blue-badge[custom]' if m.get('custom') else ''}  \n`{m['expr']}`")
        m["weight"] = float(c2.slider("Weight", 0, 10, int(round(m["weight"])), key=f"w_{pos}_{i}_v{v}",
                                      label_visibility="collapsed"))
        m["higher_is_better"] = c3.selectbox(
            "Direction", [True, False], index=0 if m["higher_is_better"] else 1,
            format_func=lambda b: "Higher is better" if b else "Lower is better",
            key=f"dir_{pos}_{i}_v{v}", label_visibility="collapsed")

    with st.expander("Add a custom metric", expanded=False):
        a1, a2 = st.columns([2, 3])
        new_label = a1.text_input("Label", placeholder="Scrimmage yds / g", key=f"new_label_v{v}")
        new_expr = a2.text_input("Expression", placeholder="(rushing_yards + receiving_yards) / games",
                                 key=f"new_expr_v{v}")
        if new_expr.strip():
            echk = validate_expr(new_expr, cols)
            if echk.ok:
                sub = data.players[data.players["pos_group"] == pos]
                vals = eval_metric(new_expr, sub)
                top = sub.assign(_v=vals).dropna(subset=["_v"]).nlargest(3, "_v")["player_display_name"]
                st.success(f"Valid. {int(np.sum(~np.isnan(vals)))} players with a value; highest: {', '.join(top)}")
            else:
                st.error(echk.error)
        else:
            echk = None
            st.caption("Use + - * / and parentheses with any stats column name, e.g. passing_tds, targets, games.")
        if st.button("Add metric"):
            if echk is None or not echk.ok:
                st.warning("Enter a valid expression first")
            elif not new_label.strip():
                st.warning("Enter a label for the metric")
            else:
                keys = {x["key"] for x in metrics}
                key = "custom_" + re.sub(r"[^a-z0-9]+", "_", new_label.strip().lower())
                while key in keys:
                    key += "_2"
                metrics.append({"key": key, "label": new_label.strip(), "expr": new_expr.strip(),
                                "higher_is_better": True, "weight": 5.0, "include": True, "custom": True})
                bump_ui()
                st.rerun()

    customs = {x["key"]: x["label"] for x in metrics if x.get("custom")}
    if customs:
        r1, r2 = st.columns([3, 1], vertical_alignment="bottom")
        rm = r1.selectbox("Remove a custom metric", list(customs), format_func=customs.get, key=f"rm_{pos}_v{v}")
        if r2.button("Remove"):
            model["positions"][pos]["metrics"] = [x for x in metrics if x["key"] != rm]
            bump_ui()
            st.rerun()

# ---- preview ---------------------------------------------------------------------
with right:
    st.subheader("Preview: top 20 (full season)")
    pv = preview_scores(data.players, pos, model, st.session_state["saved_model"])
    q_only = pv[pv["pos_rank"].notna()].sort_values("pos_rank")
    st.caption(f"{len(q_only)} of {len(pv)} {pos} players qualify. Movement is compared with the last "
               f"saved/loaded model ({st.session_state['saved_model'].get('name')}).")

    def move_txt(cur, old):
        if pd.isna(old):
            return "new"
        d = int(old) - int(cur)
        return f"▲{d}" if d > 0 else (f"▼{-d}" if d < 0 else "–")

    top = q_only.head(20)
    st.dataframe(
        pd.DataFrame({
            "rank": top["pos_rank"].astype(int), "player": top["player_display_name"], "team": top["team"],
            "score": top["score"], "move": [move_txt(c, o) for c, o in zip(top["pos_rank"], top["saved_rank"])],
        }),
        hide_index=True, width="stretch", height=740,
        column_config={
            "rank": st.column_config.NumberColumn("#", width=40),
            "player": st.column_config.TextColumn("Player", width=150),
            "team": st.column_config.TextColumn("Team", width=55),
            "score": st.column_config.ProgressColumn("Score", min_value=0, max_value=100, format="%.1f", width=130),
            "move": st.column_config.TextColumn("Δ", width=55),
        },
    )
