# NFL Player Rankings (2026 season)

A local tool for ranking NFL players with a model you configure per position. It comes in two
versions that share data, config and saved models, and produce identical scores:

- **R version:** a Shiny app
- **Python version:** a Streamlit app

Both run on **Windows and macOS** (and Linux). Each one runs only on your own computer
(bound to localhost) and opens in your web browser.

## Quick start

| | Windows | macOS |
|---|---|---|
| **R** version | double-click `r\run.bat` | double-click `r/run.command` |
| **Python** version | double-click `python\run.bat` | double-click `python/run.command` |

The first launch installs what the app needs (R packages, or a Python virtual environment), and
the first run downloads the 2026 data. Both take a minute or two. Later launches start in seconds.

To stop an app, close its console window (Windows) or press **Ctrl+C** in its Terminal window (macOS).

## Requirements

| | Windows | macOS |
|---|---|---|
| **R** 4.1 or later (tested on 4.5) | [CRAN installer](https://cran.r-project.org/bin/windows/base/) | [CRAN installer](https://cran.r-project.org/bin/macosx/) (pick Apple silicon or Intel), or `brew install --cask r` |
| **Python** 3.10 or later (tested on 3.13) | [python.org installer](https://www.python.org/downloads/) | [python.org installer](https://www.python.org/downloads/) or `brew install python` |
| Browser | any modern browser | any modern browser |

You only need the language of the version you want to run.

- **macOS Python:** the `python3` that ships with macOS is often 3.9, which is too old. The
  launcher skips it automatically and uses a newer Python if one is installed.
- **R packages:** these install into your user library (`r/install.R`). On Windows they come from
  Posit Package Manager, because CRAN only builds Windows binaries for the newest R release.
  On macOS they come from CRAN.

### macOS: first launch

macOS may not let you double-click a downloaded script the first time.

- **"cannot be opened because it is from an unidentified developer"**: right-click the
  `.command` file, choose **Open**, then confirm **Open**. You only have to do this once.
- **"permission denied"**, or the file opens in a text editor: the executable flag was lost when
  the folder was copied, for example from a zip or a sync service. In Terminal, from the project
  folder, run:
  ```bash
  chmod +x r/run.command python/run.command
  ```
- You can also skip double-clicking and always launch from Terminal:
  ```bash
  bash r/run.command        # R version
  bash python/run.command   # Python version
  ```

### Sharing the folder between a Mac and a PC

The project can live in a synced folder (OneDrive, Dropbox, iCloud) and be used from both OSes:

- Data (`data/cache/`) and saved models (`config/models/`) are shared, so a model saved on one machine
  loads on the other.
- Each OS gets its own Python environment: `.venv` on Windows, `.venv-darwin` on macOS.
  Neither overwrites the other.
- R packages are installed per machine, outside the project folder.

You may want to exclude the `.venv*` folders from syncing. They are large and rebuild automatically.

## Data

Stats come from the free, nightly-updated [nflverse](https://github.com/nflverse/nflverse-data/releases) releases:

- `stats_player_reg_2026.csv`: regular-season totals per player (about 150 stat columns: passing, rushing, receiving, EPA, target share, defense, kicking, punting, fantasy points)
- `stats_player_week_2026.csv`: one row per player per week
- `roster_2026.csv`: current team and status

**Refresh data** (on either page) downloads all three files to temporary files and checks that
**every row is from the 2026 season** and the expected columns exist. Only then does it replace
`data/cache/`. If a check fails, the old data is kept and the app shows the error. The header shows
"2026 season · through Week N · data as of …". The season and URLs are set in `config/settings.yaml`.

## Pages

**Rankings**
- Filters: position, conference, division, team, name search, week range, minimum games, qualified only.
- Sortable table with a score bar and position rank. With one position selected, the columns
  become that position's model metrics.
- Charts: top-N bar chart and a scatter of any two metrics, colored by conference.
- Player detail: per-metric percentile breakdown and a weekly trend line.

**Model**
- For each position: include or exclude each metric, set its weight (0–10) and direction
  (higher or lower is better).
- Qualification rules, and percentile or z-score normalization.
- **Custom metrics** from expressions such as `(rushing_yards + receiving_yards) / games`.
- Live top-20 preview with rank movement compared with the last saved model.
- Save, load and reset. Models are YAML files in `config/models/`, and either app can load them.

## How scores work

1. A player **qualifies** at their position if `games >= min_games` and the position's volume
   expression (for example `attempts / games` for QBs) is at least `min_volume`.
2. Each metric becomes a **percentile against qualified players at that position**, with ties
   counted as half. Lower-is-better metrics are flipped. Z-score mode uses the normal CDF of the
   z-score instead.
3. **Score** = weighted average of the metric percentiles × 100. Players who don't qualify still get
   a score against the same pool but are marked "NQ" and have no position rank.
4. Scores are league-wide per position, so filtering by team or conference never changes a score.

Expressions may only use `+ - * / ( )`, numbers and stats column names. Both apps reject anything
else, such as function calls or attribute access. Division by zero gives a missing value, and a
missing metric is left out of that player's weighted average.

**Week ranges:** for a partial range, season rows are rebuilt from the weekly file. Counting stats
are summed. Rates are recomputed: PACR, RACR, FG%, PAT%, and target share and air-yards share
against team totals for the range. CPOE is averaged, weighted by attempts. For some traded players,
target share can differ slightly from nflverse's own numbers.

## Running from a terminal

Run these from the project folder. The launchers do the same thing.

**R** (both OSes; on Windows use the full path, e.g. `"C:\Program Files\R\R-4.5.1\bin\Rscript.exe"`, if `Rscript` isn't on your PATH):
```bash
Rscript r/install.R
Rscript -e "shiny::runApp('r', launch.browser = TRUE)"
```

**Python**, macOS:
```bash
python3 -m venv .venv-darwin
.venv-darwin/bin/pip install -r python/requirements.txt
.venv-darwin/bin/streamlit run python/app.py --server.address localhost
```

**Python**, Windows (PowerShell or cmd):
```bat
py -m venv .venv
.venv\Scripts\pip install -r python\requirements.txt
.venv\Scripts\streamlit run python\app.py --server.address localhost
```

## Tests

Unit tests, plus an R/Python parity check: both versions score the same model, then every player
is compared. To check a specific model and week range, pass them to both scoring commands,
e.g. `config/models/My_model.yaml 3 8`.

**macOS**
```bash
Rscript -e "testthat::test_dir('r/tests/testthat')"
.venv-darwin/bin/python -m pytest python/tests

Rscript r/cli_scores.R
(cd python && ../.venv-darwin/bin/python -m nflrank.cli)
.venv-darwin/bin/python tools/compare_scores.py      # prints PARITY OK
```

**Windows**
```bat
Rscript -e "testthat::test_dir('r/tests/testthat')"
.venv\Scripts\python -m pytest python\tests

Rscript r\cli_scores.R
cd python && ..\.venv\Scripts\python -m nflrank.cli && cd ..
.venv\Scripts\python tools\compare_scores.py
```

## Project layout

```
config/            settings.yaml (season, URLs, positions), model_default.yaml, teams.csv, models/
data/cache/        downloaded CSVs + meta.json (shared by both apps)
r/                 app.R, R/ (data.R, model.R, UI modules), tests/, cli_scores.R, install.R,
                   run.bat (Windows), run.command (macOS/Linux)
python/            app.py, pages/, nflrank/ (data.py, model.py, ui.py, cli.py), tests/, requirements.txt,
                   run.bat (Windows), run.command (macOS/Linux)
tools/             compare_scores.py (R vs Python parity check)
.streamlit/        Streamlit config (localhost only, theme)
```

## Troubleshooting

- **A port is already in use:** another copy is probably still running. Close its window, or press
  Ctrl+C in it. Streamlit uses port 8501 and Shiny picks a random port.
- **R package install fails on Windows with SSL or connection errors:** usually a temporary network
  problem. Run the launcher again; packages that are already installed are skipped.
- **The Python environment is broken** after a Python upgrade: delete `.venv` (Windows) or
  `.venv-darwin` (macOS) and launch again to rebuild it.
- **Refresh failed:** the existing data is kept. Check your internet connection. Outside the season,
  nflverse may not have published a 2026 file yet.
