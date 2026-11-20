"""Checks that the R and Python apps produce the same rankings.

Run both CLIs first:
    Rscript r/cli_scores.R [model.yaml] [from to]
    python -m nflrank.cli [model.yaml] [from to]     (from the python/ folder)
then:  python tools/compare_scores.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

TOL = 1e-9
OUT = Path(__file__).resolve().parents[1] / "data" / "out"


def load(name: str) -> pd.DataFrame:
    return pd.read_csv(OUT / name, dtype={"player_id": str})


def compare(kind: str, keys: list[str], numeric: list[str], exact: list[str]) -> int:
    r, p = load(f"{kind}_r.csv"), load(f"{kind}_py.csv")
    m = r.merge(p, on=keys, how="outer", suffixes=("_r", "_py"), indicator=True)
    problems = 0
    only = m[m["_merge"] != "both"]
    if len(only):
        print(f"[{kind}] {len(only)} rows present in only one output")
        problems += len(only)
    both = m[m["_merge"] == "both"]
    for c in numeric:
        a, b = both[f"{c}_r"].to_numpy(float), both[f"{c}_py"].to_numpy(float)
        bad = ~((np.isnan(a) & np.isnan(b)) | (np.abs(a - b) <= TOL))
        if bad.any():
            print(f"[{kind}] {c}: {bad.sum()} mismatches, max diff {np.nanmax(np.abs(a - b)):.3g}")
            print(both.loc[bad, keys + [f"{c}_r", f"{c}_py"]].head())
            problems += int(bad.sum())
    for c in exact:
        a = both[f"{c}_r"].astype(str).str.upper()
        b = both[f"{c}_py"].astype(str).str.upper()
        bad = a != b
        if bad.any():
            print(f"[{kind}] {c}: {bad.sum()} mismatches")
            problems += int(bad.sum())
    print(f"[{kind}] {len(both)} rows compared, {problems} problems")
    return problems


if __name__ == "__main__":
    n = compare("scores", ["player_id", "pos_group"], ["score", "volume", "pos_rank"], ["qualified"])
    n += compare("breakdown", ["player_id", "pos_group", "key"], ["value", "pct", "weight"], [])
    print("PARITY OK" if n == 0 else f"PARITY FAILED ({n} problems)")
    sys.exit(1 if n else 0)
