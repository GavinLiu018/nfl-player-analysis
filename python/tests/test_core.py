import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nflrank.data import NflData, aggregate_weeks, assign_pos_group, validate_download  # noqa: E402
from nflrank.model import (  # noqa: E402
    eval_metric, normalize_model, percentile_of, read_model, safe_model_filename,
    save_model, score_players, validate_expr, zscore_of,
)

SETTINGS = {
    "season": 2026,
    "required_columns": {"reg": ["player_id", "season"]},
    "position_groups": {"QB": ["QB"], "DB": ["CB", "SAF"]},
}


def test_percentile_ties_half_and_nan():
    ref = np.array([1, 2, 2, 3, np.nan])
    got = percentile_of(np.array([0, 1, 2, 3, 4, np.nan]), ref)
    np.testing.assert_allclose(got, [0, 0.125, 0.5, 0.875, 1, np.nan])
    assert np.isnan(percentile_of(np.array([1.0]), np.array([]))).all()


def test_zscore():
    assert zscore_of(np.array([2.0]), np.array([1.0, 2.0, 3.0]))[0] == pytest.approx(0.5)
    assert np.isnan(zscore_of(np.array([2.0]), np.array([2.0, 2.0, 2.0]))[0])


@pytest.mark.parametrize("expr,ok", [
    ("(a + b) / 2 - -a * 3", True),
    ("__import__('os')", False),
    ("system('x')", False),
    ("a ** 2", False),
    ("c + 1", False),
    ("a.b", False),
    ("a[0]", False),
    ("True + a", False),
    ("", False),
])
def test_validate_expr(expr, ok):
    assert validate_expr(expr, ["a", "b"]).ok is ok


def test_validate_expr_message():
    assert validate_expr("zzz / a", ["a"]).error == "Unknown column: zzz"


def test_eval_metric_div_zero():
    df = pd.DataFrame({"a": [1.0, 0, 4], "b": [2.0, 0, 0]})
    np.testing.assert_allclose(eval_metric("a / b", df), [0.5, np.nan, np.nan])


def test_score_players():
    df = pd.DataFrame({
        "player_id": ["p1", "p2", "p3", "p4"], "pos_group": "QB",
        "games": [10.0, 10, 10, 1], "yds": [300.0, 200, 100, 999], "ints": [1.0, 5, 9, 0],
    })
    model = normalize_model({"positions": {"QB": {
        "qualify": {"min_games": 4, "volume": "games", "min_volume": 0},
        "metrics": [
            {"key": "y", "label": "Y", "expr": "yds", "higher_is_better": True, "weight": 1},
            {"key": "i", "label": "I", "expr": "ints", "higher_is_better": False, "weight": 1},
        ],
    }}})
    s, _ = score_players(df, model)
    assert s["pos_rank"].tolist()[:3] == [1, 2, 3] and pd.isna(s["pos_rank"].iloc[3])
    assert s["qualified"].tolist() == [True, True, True, False]
    assert s["score"].iloc[0] == pytest.approx(100 * 5 / 6)
    assert s["score"].iloc[3] == pytest.approx(100)


def test_save_model_roundtrip(tmp_path):
    m = normalize_model({"positions": {"K": {
        "qualify": {"min_games": 1, "volume": "games", "min_volume": 0},
        "metrics": [{"key": "x", "label": "X", "expr": "fg_made", "weight": 3}],
    }}})
    p = save_model(m, tmp_path, "My model / v2")
    assert p.name == "My_model_v2.yaml"
    assert read_model(p)["positions"]["K"]["metrics"][0]["weight"] == 3
    with pytest.raises(ValueError):
        safe_model_filename("../..")


def test_validate_download():
    validate_download(pd.DataFrame({"player_id": ["a"], "season": [2026]}), "reg", SETTINGS)
    with pytest.raises(ValueError, match="expected only 2026"):
        validate_download(pd.DataFrame({"player_id": ["a"], "season": [2025]}), "reg", SETTINGS)
    with pytest.raises(ValueError, match="missing columns: player_id"):
        validate_download(pd.DataFrame({"season": [2026]}), "reg", SETTINGS)


def test_assign_pos_group():
    got = assign_pos_group(pd.Series(["QB", "SAF", "OT"]), SETTINGS).tolist()
    assert got[:2] == ["QB", "DB"] and pd.isna(got[2])


def test_aggregate_weeks():
    week = pd.DataFrame({
        "player_id": ["p1", "p1", "p2", "p2", None], "player_name": "x",
        "player_display_name": ["A", "A", "B", "B", None], "position": "QB", "position_group": "QB",
        "headshot_url": None, "season": 2026, "season_type": "REG", "week": [1, 2, 1, 2, 2], "team": "KC",
        "attempts": [10.0, 30, 0, 0, 0], "passing_cpoe": [1.0, 5, np.nan, np.nan, np.nan],
        "targets": [2.0, 2, 6, 6, 4], "receiving_air_yards": [10.0, 10, 30, 30, 20],
        "passing_yards": [100.0, 200, 0, 0, 0], "passing_air_yards": [50.0, 100, 0, 0, 0],
        "receiving_yards": [0.0, 0, 50, 70, 0], "fg_made": 0.0, "fg_att": 0.0, "pat_made": 0.0, "pat_att": 0.0,
    })
    data = NflData(
        settings=SETTINGS, meta={}, week=week, players=pd.DataFrame(),
        roster=pd.DataFrame(columns=["gsis_id", "status", "jersey_number", "team"]),
        teams=pd.DataFrame({"abbr": ["KC"], "name": ["Chiefs"], "conference": ["AFC"],
                            "division": ["AFC West"], "color": ["#E31837"]}),
    )
    a = aggregate_weeks(data, 1, 2)
    p1 = a[a["player_id"] == "p1"].iloc[0]
    assert p1["games"] == 2 and p1["passing_yards"] == 300
    assert p1["passing_cpoe"] == pytest.approx((1 * 10 + 5 * 30) / 40)
    assert p1["pacr"] == pytest.approx(2)
    assert p1["target_share"] == pytest.approx(4 / 20)
    assert p1["conference"] == "AFC"
    assert len(aggregate_weeks(data, 2, 2)) == 2
