"""Ranking model: expression validation, metric evaluation, normalization and scoring.

Mirrors r/R/model.R; keep the two in sync.
"""
from __future__ import annotations

import ast
import copy
import math
import re
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd
import yaml

_BINOPS = {ast.Add: np.add, ast.Sub: np.subtract, ast.Mult: np.multiply, ast.Div: np.divide}


def default_model_path(root: Path) -> Path:
    return root / "config" / "model_default.yaml"


def models_dir(root: Path) -> Path:
    return root / "config" / "models"


def normalize_model(m: dict) -> dict:
    m = copy.deepcopy(m)
    m.setdefault("normalization", "percentile")
    m.setdefault("name", "Untitled")
    for spec in m["positions"].values():
        q = spec.setdefault("qualify", {})
        q["min_games"] = float(q.get("min_games") or 0)
        q["min_volume"] = float(q.get("min_volume") or 0)
        q["volume"] = q.get("volume") or "games"
        for x in spec["metrics"]:
            x["weight"] = float(x.get("weight") or 0)
            x["higher_is_better"] = bool(x.get("higher_is_better", True))
            x["include"] = x.get("include") is not False
            x["custom"] = bool(x.get("custom", False))
    return m


def read_model(path: Path) -> dict:
    return normalize_model(yaml.safe_load(Path(path).read_text(encoding="utf-8")))


def list_saved_models(root: Path) -> dict[str, Path]:
    d = models_dir(root)
    if not d.exists():
        return {}
    return {p.stem: p for p in sorted(d.glob("*.y*ml"))}


def safe_model_filename(name: str) -> str:
    s = re.sub(r"[^A-Za-z0-9_-]+", "_", name.strip()).strip("_")
    if not s:
        raise ValueError("Model name must contain letters or digits")
    return s


def save_model(model: dict, root: Path, name: str) -> Path:
    d = models_dir(root)
    d.mkdir(parents=True, exist_ok=True)
    m = copy.deepcopy(model)
    m["name"] = name
    path = d / f"{safe_model_filename(name)}.yaml"
    path.write_text(yaml.safe_dump(m, sort_keys=False, allow_unicode=True), encoding="utf-8")
    return path


@dataclass
class ExprCheck:
    ok: bool
    error: str | None
    vars: list[str]


def validate_expr(expr: str, allowed_cols) -> ExprCheck:
    """Checks that expr is arithmetic (+ - * / and parentheses) over known columns."""
    if not isinstance(expr, str) or not expr.strip():
        return ExprCheck(False, "Expression is empty", [])
    try:
        tree = ast.parse(expr.strip(), mode="eval")
    except SyntaxError as e:
        return ExprCheck(False, f"Syntax error: {e.msg}", [])
    allowed = set(allowed_cols)
    found: list[str] = []

    def walk(node) -> str | None:
        if isinstance(node, ast.Constant):
            v = node.value
            if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
                return f"Not allowed: {v!r}"
            return None
        if isinstance(node, ast.Name):
            if node.id not in allowed:
                return f"Unknown column: {node.id}"
            found.append(node.id)
            return None
        if isinstance(node, ast.BinOp):
            if type(node.op) not in _BINOPS:
                return f"Not allowed: {type(node.op).__name__} (only + - * / and parentheses)"
            return walk(node.left) or walk(node.right)
        if isinstance(node, ast.UnaryOp):
            if not isinstance(node.op, (ast.UAdd, ast.USub)):
                return f"Not allowed: {type(node.op).__name__}"
            return walk(node.operand)
        return f"Not allowed: {type(node).__name__} (only + - * / and parentheses)"

    err = walk(tree.body)
    if err:
        return ExprCheck(False, err, [])
    return ExprCheck(True, None, list(dict.fromkeys(found)))


def numeric_columns(df: pd.DataFrame) -> list[str]:
    return [c for c in df.columns if pd.api.types.is_numeric_dtype(df[c]) and not pd.api.types.is_bool_dtype(df[c])]


def eval_metric(expr: str, df: pd.DataFrame) -> np.ndarray:
    """Evaluates a validated expression against df; non-finite results become NaN."""
    chk = validate_expr(expr, numeric_columns(df))
    if not chk.ok:
        raise ValueError(chk.error)
    cols = {c: df[c].to_numpy(dtype="float64") for c in chk.vars}

    def ev(node):
        if isinstance(node, ast.Constant):
            return float(node.value)
        if isinstance(node, ast.Name):
            return cols[node.id]
        if isinstance(node, ast.BinOp):
            return _BINOPS[type(node.op)](ev(node.left), ev(node.right))
        if isinstance(node, ast.UnaryOp):
            v = ev(node.operand)
            return -v if isinstance(node.op, ast.USub) else v
        raise ValueError("unreachable")

    with np.errstate(divide="ignore", invalid="ignore"):
        out = np.broadcast_to(np.asarray(ev(ast.parse(expr.strip(), mode="eval").body), dtype="float64"),
                              (len(df),)).copy()
    out[~np.isfinite(out)] = np.nan
    return out


def percentile_of(x: np.ndarray, ref: np.ndarray) -> np.ndarray:
    """Share of reference values below x, counting ties as half."""
    x = np.asarray(x, dtype="float64")
    out = np.full(len(x), np.nan)
    ref = np.sort(ref[~np.isnan(ref)])
    n = len(ref)
    ok = ~np.isnan(x)
    if n == 0 or not ok.any():
        return out
    less = np.searchsorted(ref, x[ok], side="left")
    leq = np.searchsorted(ref, x[ok], side="right")
    out[ok] = (less + 0.5 * (leq - less)) / n
    return out


_erfc = np.vectorize(math.erfc, otypes=[float])


def zscore_of(x: np.ndarray, ref: np.ndarray) -> np.ndarray:
    ref = ref[~np.isnan(ref)]
    if len(ref) < 2:
        return np.full(len(x), np.nan)
    s = ref.std(ddof=1)
    if not np.isfinite(s) or s == 0:
        return np.full(len(x), np.nan)
    z = (np.asarray(x, dtype="float64") - ref.mean()) / s
    out = np.full(len(z), np.nan)
    ok = ~np.isnan(z)
    out[ok] = 0.5 * _erfc(-z[ok] / math.sqrt(2))
    return out


def active_metrics(spec: dict) -> list[dict]:
    return [m for m in spec["metrics"] if m["include"] and m["weight"] > 0]


def score_players(df: pd.DataFrame, model: dict) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Scores every player. Returns (scores: one row per player, breakdown: long)."""
    score_parts, bd_parts = [], []
    for pos, spec in model["positions"].items():
        sub = df[df["pos_group"] == pos]
        if sub.empty:
            continue
        q = spec["qualify"]
        volume = eval_metric(q["volume"], sub)
        games = sub["games"].to_numpy(dtype="float64")
        with np.errstate(invalid="ignore"):
            qualified = (games >= q["min_games"]) & ~np.isnan(volume) & (volume >= q["min_volume"])
        num = np.zeros(len(sub))
        den = np.zeros(len(sub))
        for m in spec["metrics"]:
            value = eval_metric(m["expr"], sub)
            ref = value[qualified]
            p = zscore_of(value, ref) if model.get("normalization") == "zscore" else percentile_of(value, ref)
            if not m["higher_is_better"]:
                p = 1 - p
            used = m["include"] and m["weight"] > 0
            if used:
                has = ~np.isnan(p)
                num[has] += m["weight"] * p[has]
                den[has] += m["weight"]
            bd_parts.append(pd.DataFrame({
                "player_id": sub["player_id"].to_numpy(), "pos_group": pos, "key": m["key"],
                "label": m["label"], "value": value, "pct": p,
                "weight": m["weight"] if used else 0.0, "higher_is_better": m["higher_is_better"],
            }))
        with np.errstate(divide="ignore", invalid="ignore"):
            score = np.where(den > 0, 100 * num / den, np.nan)
        pos_rank = np.full(len(sub), np.nan)
        ids = sub["player_id"].to_numpy()
        q_idx = np.flatnonzero(qualified & ~np.isnan(score))
        order = (pd.DataFrame({"i": q_idx, "s": -score[q_idx], "id": ids[q_idx].astype(str)})
                 .sort_values(["s", "id"], kind="stable")["i"].to_numpy())
        pos_rank[order] = np.arange(1, len(order) + 1)
        score_parts.append(pd.DataFrame({
            "player_id": ids, "pos_group": pos, "score": score, "qualified": qualified,
            "volume": volume, "pos_rank": pd.array(pos_rank, dtype="Int64"),
        }))
    scores = pd.concat(score_parts, ignore_index=True) if score_parts else pd.DataFrame(
        columns=["player_id", "pos_group", "score", "qualified", "volume", "pos_rank"])
    breakdown = pd.concat(bd_parts, ignore_index=True) if bd_parts else pd.DataFrame()
    return scores, breakdown


def ranked_players(df: pd.DataFrame, model: dict) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Player frame joined with scores."""
    scores, breakdown = score_players(df, model)
    out = df.merge(scores[["player_id", "score", "qualified", "volume", "pos_rank"]],
                   on="player_id", how="left")
    return out, breakdown
