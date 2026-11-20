"""Data layer: download, validate, cache and prepare nflverse 2026 player stats.

Mirrors r/R/data.R; keep the two in sync.
"""
from __future__ import annotations

import json
import os
import shutil
import time
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

import numpy as np
import pandas as pd
import yaml

ID_COLUMNS = {
    "player_id", "player_name", "player_display_name", "position", "position_group",
    "headshot_url", "season", "week", "season_type", "game_id", "team", "recent_team",
    "opponent_team", "games",
}
WEIGHTED_BY_ATTEMPTS = ["passing_cpoe"]
MAX_COLUMNS = ["fg_long", "pt_long"]
# Recomputed from sums. target_share / air_yards_share use the team's total over the
# week range for every team the player appeared for (this is how nflverse defines them).
RECOMPUTED = ["pacr", "racr", "fg_pct", "pat_pct", "target_share", "air_yards_share", "wopr"]
KINDS = ("reg", "week", "roster")
USER_AGENT = "nfl-player-analysis/1.0"


def project_root(start: str | Path | None = None) -> Path:
    env = os.environ.get("NFLRANK_ROOT")
    if env:
        return Path(env).resolve()
    d = Path(start or Path(__file__).parent).resolve()
    for p in [d, *d.parents]:
        if (p / "config" / "settings.yaml").exists():
            return p
    raise FileNotFoundError(f"Could not find config/settings.yaml above {d}")


def read_settings(root: Path) -> dict:
    s = yaml.safe_load((root / "config" / "settings.yaml").read_text(encoding="utf-8"))
    s["season"] = int(s["season"])
    s["sources"] = {k: v.replace("{season}", str(s["season"])) for k, v in s["sources"].items()}
    return s


def read_teams(root: Path) -> pd.DataFrame:
    return pd.read_csv(root / "config" / "teams.csv", keep_default_na=False)


def cache_paths(root: Path, season: int) -> dict[str, Path]:
    d = root / "data" / "cache"
    return {
        "dir": d,
        "reg": d / f"stats_reg_{season}.csv",
        "week": d / f"stats_week_{season}.csv",
        "roster": d / f"roster_{season}.csv",
        "meta": d / "meta.json",
    }


def read_nflverse_csv(path: Path) -> pd.DataFrame:
    return pd.read_csv(
        path, low_memory=False,
        dtype={"player_id": str, "gsis_id": str, "jersey_number": str},
    )


def validate_download(df: pd.DataFrame, kind: str, settings: dict) -> None:
    """Raises ValueError if a downloaded file is not what we expect."""
    missing = [c for c in settings["required_columns"][kind] if c not in df.columns]
    if missing:
        raise ValueError(f"{kind} file is missing columns: {', '.join(missing)}")
    if df.empty:
        raise ValueError(f"{kind} file has no rows")
    seasons = df["season"].unique()
    if len(seasons) != 1 or pd.isna(seasons[0]) or int(seasons[0]) != settings["season"]:
        raise ValueError(
            f"{kind} file contains season(s) {', '.join(map(str, seasons))}, "
            f"expected only {settings['season']}"
        )


def _download(url: str, dest: Path, tries: int = 3) -> str | None:
    """Downloads url to dest; returns the Last-Modified header."""
    last_err: Exception | None = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as fh:
                shutil.copyfileobj(resp, fh)
                lm = resp.headers.get("Last-Modified")
            if dest.stat().st_size > 0:
                return lm
        except Exception as e:  # network errors are retried
            last_err = e
        time.sleep(i + 1)
    raise RuntimeError(f"Download failed for {url}: {last_err}")


def refresh_data(root: Path, progress: Callable[[str], None] = lambda msg: None) -> dict:
    """Downloads all sources to temp files, validates them, and only then replaces the cache."""
    settings = read_settings(root)
    paths = cache_paths(root, settings["season"])
    paths["dir"].mkdir(parents=True, exist_ok=True)
    tmp = {k: paths[k].with_name(paths[k].name + ".part") for k in KINDS}
    files: dict[str, dict] = {}
    latest_week = None
    try:
        for k in KINDS:
            url = settings["sources"][k]
            progress(f"Downloading {url.rsplit('/', 1)[-1]}")
            lm = _download(url, tmp[k])
            df = read_nflverse_csv(tmp[k])
            validate_download(df, k, settings)
            if k == "week":
                latest_week = int(df["week"].max())
            files[k] = {"url": url, "last_modified": lm, "rows": int(len(df))}
        for k in KINDS:
            shutil.copyfile(tmp[k], paths[k])
    finally:
        for p in tmp.values():
            p.unlink(missing_ok=True)
    meta = {
        "season": settings["season"],
        "fetched_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "latest_week": latest_week,
        "source": "nflverse-data GitHub releases",
        "files": files,
    }
    paths["meta"].write_text(json.dumps(meta, indent=2), encoding="utf-8")
    progress("Done")
    return meta


def assign_pos_group(position: pd.Series, settings: dict) -> pd.Series:
    mapping = {p: g for g, ps in settings["position_groups"].items() for p in ps}
    return position.map(mapping)


def stat_columns(df: pd.DataFrame) -> list[str]:
    return [c for c in df.columns
            if c not in ID_COLUMNS and not c.endswith("_list") and c != "gwfg_distance"]


def coerce_stats(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    for c in stat_columns(df):
        df[c] = pd.to_numeric(df[c], errors="coerce").astype("float64")
    return df


def decorate(df: pd.DataFrame, roster: pd.DataFrame, teams: pd.DataFrame, settings: dict) -> pd.DataFrame:
    """Adds pos_group, current team (roster, falling back to the stats team), conference, division."""
    df = df[df["player_id"].notna() & (df["player_id"] != "")].copy()
    df["pos_group"] = assign_pos_group(df["position"], settings)
    df = df[df["pos_group"].notna()].copy()
    df["games"] = df["games"].astype("float64")
    r = roster.set_index("gsis_id").reindex(df["player_id"])
    df["status"] = r["status"].to_numpy()
    df["jersey_number"] = r["jersey_number"].to_numpy()
    df["team"] = np.where(r["team"].isna().to_numpy(), df["recent_team"].to_numpy(), r["team"].to_numpy())
    t = teams.set_index("abbr").reindex(df["team"])
    df["team_name"] = t["name"].to_numpy()
    df["conference"] = t["conference"].to_numpy()
    df["division"] = t["division"].to_numpy()
    df["team_color"] = t["color"].to_numpy()
    return df.reset_index(drop=True)


@dataclass
class NflData:
    settings: dict
    meta: dict
    teams: pd.DataFrame
    roster: pd.DataFrame
    week: pd.DataFrame
    players: pd.DataFrame
    weeks_available: list[int] = field(default_factory=list)


def load_data(root: Path, auto_refresh: bool = True) -> NflData:
    settings = read_settings(root)
    paths = cache_paths(root, settings["season"])
    if not all(paths[k].exists() for k in (*KINDS, "meta")):
        if not auto_refresh:
            raise FileNotFoundError("No cached data. Run refresh_data() first.")
        refresh_data(root)
    season = settings["season"]
    reg = read_nflverse_csv(paths["reg"])
    week = read_nflverse_csv(paths["week"])
    roster = read_nflverse_csv(paths["roster"])
    roster = roster[roster["gsis_id"].notna()].drop_duplicates("gsis_id")
    teams = read_teams(root)
    meta = json.loads(paths["meta"].read_text(encoding="utf-8"))

    reg = coerce_stats(reg[(reg["season"] == season) & (reg["season_type"] == "REG")])
    # Rows without a player_id are kept here: they still count toward team totals.
    week = coerce_stats(week[(week["season"] == season) & (week["season_type"] == "REG")])
    return NflData(
        settings=settings, meta=meta, teams=teams, roster=roster, week=week,
        players=decorate(reg, roster, teams, settings),
        weeks_available=sorted(int(w) for w in week["week"].dropna().unique()),
    )


def _safe_div(a, b) -> np.ndarray:
    with np.errstate(divide="ignore", invalid="ignore"):
        r = np.asarray(a, dtype="float64") / np.asarray(b, dtype="float64")
    r[~np.isfinite(r)] = np.nan
    return r


def aggregate_weeks(data: NflData, start: int, end: int) -> pd.DataFrame:
    """Rebuilds season-style rows from weekly rows for weeks [start, end]."""
    all_rows = data.week[(data.week["week"] >= start) & (data.week["week"] <= end)]
    team_tgt = all_rows.groupby("team")["targets"].sum()
    team_ay = all_rows.groupby("team")["receiving_air_yards"].sum()
    w = all_rows[all_rows["player_id"].notna() & (all_rows["player_id"] != "")]
    w = w.sort_values(["player_id", "week"], kind="stable")
    if w.empty:
        return data.players.iloc[0:0].copy()
    g = w.groupby("player_id", sort=True)
    last = g.tail(1).set_index("player_id").sort_index()
    ids = last.index
    out = pd.DataFrame({
        "player_id": ids,
        "player_name": last["player_name"].to_numpy(),
        "player_display_name": last["player_display_name"].to_numpy(),
        "position": last["position"].to_numpy(),
        "position_group": last["position_group"].to_numpy(),
        "headshot_url": last["headshot_url"].to_numpy(),
        "season": data.settings["season"],
        "season_type": "REG",
        "recent_team": last["team"].to_numpy(),
        "games": g.size().reindex(ids).astype("float64").to_numpy(),
    })
    cols = stat_columns(w)
    sum_cols = [c for c in cols if c not in (*WEIGHTED_BY_ATTEMPTS, *MAX_COLUMNS, *RECOMPUTED)]
    sums = g[sum_cols].sum(min_count=0).reindex(ids)
    extra: dict[str, np.ndarray] = {c: sums[c].to_numpy() for c in sum_cols}
    for c in [c for c in WEIGHTED_BY_ATTEMPTS if c in cols]:
        ok = w[c].notna() & w["attempts"].notna()
        num = (w[c].where(ok, 0) * w["attempts"].where(ok, 0)).groupby(w["player_id"]).sum()
        den = w["attempts"].where(ok, 0).groupby(w["player_id"]).sum()
        extra[c] = _safe_div(num.reindex(ids), den.reindex(ids))
    for c in [c for c in MAX_COLUMNS if c in cols]:
        extra[c] = g[c].max().reindex(ids).to_numpy(dtype="float64")
    pt = w[["player_id", "team"]].drop_duplicates()
    den_tgt = pt["team"].map(team_tgt).groupby(pt["player_id"]).sum().reindex(ids)
    den_ay = pt["team"].map(team_ay).groupby(pt["player_id"]).sum().reindex(ids)
    e = extra
    e["pacr"] = _safe_div(e["passing_yards"], e["passing_air_yards"])
    e["racr"] = _safe_div(e["receiving_yards"], e["receiving_air_yards"])
    e["fg_pct"] = _safe_div(e["fg_made"], e["fg_att"])
    e["pat_pct"] = _safe_div(e["pat_made"], e["pat_att"])
    e["target_share"] = _safe_div(e["targets"], den_tgt)
    e["air_yards_share"] = _safe_div(e["receiving_air_yards"], den_ay)
    e["wopr"] = 1.5 * e["target_share"] + 0.7 * e["air_yards_share"]
    out = pd.concat([out, pd.DataFrame(extra)], axis=1)
    return decorate(out, data.roster, data.teams, data.settings)


def player_frame(data: NflData, weeks: tuple[int, int] | None = None) -> pd.DataFrame:
    """Player rows for a week range; the full season uses the official season file."""
    wk = data.weeks_available
    if weeks is None or not wk or (weeks[0] <= min(wk) and weeks[1] >= max(wk)):
        return data.players
    return aggregate_weeks(data, weeks[0], weeks[1])
