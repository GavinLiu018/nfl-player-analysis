"""Usage: python -m nflrank.cli [model.yaml] [from_week to_week]

Writes data/out/scores_py.csv and data/out/breakdown_py.csv for the R/Python parity check.
"""
from __future__ import annotations

import sys
from pathlib import Path

from .data import load_data, player_frame, project_root
from .model import default_model_path, read_model, score_players


def main(argv: list[str]) -> None:
    root = project_root()
    data = load_data(root)
    model = read_model(Path(argv[0]) if argv and argv[0] else default_model_path(root))
    weeks = (int(argv[1]), int(argv[2])) if len(argv) >= 3 else None
    scores, breakdown = score_players(player_frame(data, weeks), model)
    out = root / "data" / "out"
    out.mkdir(parents=True, exist_ok=True)
    scores = scores.sort_values(["pos_group", "player_id"])
    breakdown = breakdown.sort_values(["pos_group", "player_id", "key"])
    scores.to_csv(out / "scores_py.csv", index=False, float_format="%.15g")
    breakdown.to_csv(out / "breakdown_py.csv", index=False, float_format="%.15g")
    m = data.meta
    print(f"Season {m['season']} through week {m['latest_week']} (fetched {m['fetched_at']}): "
          f"scored {len(scores)} players, {int(scores['qualified'].sum())} qualified -> {out / 'scores_py.csv'}")


if __name__ == "__main__":
    main(sys.argv[1:])
