# Data layer: download, validate, cache and prepare nflverse 2026 player stats.
# Mirrors python/nflrank/data.py — keep the two in sync.

ID_COLUMNS <- c(
  "player_id", "player_name", "player_display_name", "position", "position_group",
  "headshot_url", "season", "week", "season_type", "game_id", "team", "recent_team",
  "opponent_team", "games"
)
# Rate columns that cannot be summed across weeks.
WEIGHTED_BY_ATTEMPTS <- c("passing_cpoe")
MAX_COLUMNS <- c("fg_long", "pt_long")
# Recomputed from sums. target_share / air_yards_share use the team's total over the
# week range for every team the player appeared for (this is how nflverse defines them).
RECOMPUTED <- c("pacr", "racr", "fg_pct", "pat_pct", "target_share", "air_yards_share", "wopr")

project_root <- function(start = getwd()) {
  env <- Sys.getenv("NFLRANK_ROOT")
  if (nzchar(env)) return(normalizePath(env, winslash = "/"))
  d <- normalizePath(start, winslash = "/")
  repeat {
    if (file.exists(file.path(d, "config", "settings.yaml"))) return(d)
    parent <- dirname(d)
    if (parent == d) stop("Could not find config/settings.yaml above ", start)
    d <- parent
  }
}

read_settings <- function(root) {
  s <- yaml::read_yaml(file.path(root, "config", "settings.yaml"))
  s$season <- as.integer(s$season)
  s$sources <- lapply(s$sources, function(u) gsub("{season}", s$season, u, fixed = TRUE))
  s
}

read_teams <- function(root) {
  utils::read.csv(file.path(root, "config", "teams.csv"), stringsAsFactors = FALSE)
}

cache_paths <- function(root, season) {
  dir <- file.path(root, "data", "cache")
  list(
    dir = dir,
    reg = file.path(dir, sprintf("stats_reg_%d.csv", season)),
    week = file.path(dir, sprintf("stats_week_%d.csv", season)),
    roster = file.path(dir, sprintf("roster_%d.csv", season)),
    meta = file.path(dir, "meta.json")
  )
}

read_nflverse_csv <- function(path) {
  header <- names(utils::read.csv(path, nrows = 1, check.names = FALSE))
  ids <- intersect(c("player_id", "gsis_id", "jersey_number"), header)
  utils::read.csv(path, check.names = FALSE, stringsAsFactors = FALSE,
                  na.strings = c("", "NA"), colClasses = setNames(rep("character", length(ids)), ids))
}

# Stops with a readable message if a downloaded file is not what we expect.
validate_download <- function(df, kind, settings) {
  need <- unlist(settings$required_columns[[kind]])
  missing <- setdiff(need, names(df))
  if (length(missing)) {
    stop(sprintf("%s file is missing columns: %s", kind, paste(missing, collapse = ", ")))
  }
  if (!nrow(df)) stop(sprintf("%s file has no rows", kind))
  seasons <- unique(df$season)
  if (length(seasons) != 1 || is.na(seasons) || seasons != settings$season) {
    stop(sprintf("%s file contains season(s) %s, expected only %d",
                 kind, paste(seasons, collapse = ", "), settings$season))
  }
  invisible(TRUE)
}

download_with_retry <- function(url, dest, tries = 3) {
  last <- NULL
  for (i in seq_len(tries)) {
    ok <- tryCatch({
      utils::download.file(url, dest, mode = "wb", quiet = TRUE)
      TRUE
    }, error = function(e) { last <<- conditionMessage(e); FALSE },
       warning = function(w) { last <<- conditionMessage(w); FALSE })
    if (ok && file.exists(dest) && file.size(dest) > 0) return(invisible(TRUE))
    Sys.sleep(i)
  }
  stop(sprintf("Download failed for %s: %s", url, last))
}

last_modified <- function(url) {
  h <- tryCatch(curlGetHeaders(url), error = function(e) character())
  lm <- grep("^last-modified:", h, ignore.case = TRUE, value = TRUE)
  if (!length(lm)) return(NA_character_)
  trimws(sub("^last-modified:", "", lm[length(lm)], ignore.case = TRUE))
}

# Downloads all sources to temp files, validates them, and only then replaces the cache.
refresh_data <- function(root, progress = function(msg) NULL) {
  settings <- read_settings(root)
  paths <- cache_paths(root, settings$season)
  dir.create(paths$dir, recursive = TRUE, showWarnings = FALSE)
  kinds <- c("reg", "week", "roster")
  tmp <- setNames(paste0(unlist(paths[kinds]), ".part"), kinds)
  on.exit(unlink(tmp[file.exists(tmp)]), add = TRUE)

  files <- list()
  latest_week <- NA_integer_
  for (k in kinds) {
    url <- settings$sources[[k]]
    progress(sprintf("Downloading %s", basename(url)))
    download_with_retry(url, tmp[[k]])
    df <- read_nflverse_csv(tmp[[k]])
    validate_download(df, k, settings)
    if (k == "week") latest_week <- as.integer(max(df$week, na.rm = TRUE))
    files[[k]] <- list(url = url, last_modified = last_modified(url), rows = nrow(df))
  }
  for (k in kinds) {
    if (!file.copy(tmp[[k]], paths[[k]], overwrite = TRUE)) stop("Could not write ", paths[[k]])
  }
  meta <- list(
    season = settings$season,
    fetched_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    latest_week = latest_week,
    source = "nflverse-data GitHub releases",
    files = files
  )
  jsonlite::write_json(meta, paths$meta, auto_unbox = TRUE, pretty = TRUE)
  progress("Done")
  meta
}

# Assigns the ranking group (QB, RB, ..., DB) from the nflverse `position` column.
assign_pos_group <- function(position, settings) {
  map <- unlist(lapply(names(settings$position_groups), function(g) {
    setNames(rep(g, length(settings$position_groups[[g]])), unlist(settings$position_groups[[g]]))
  }))
  unname(map[position])
}

stat_columns <- function(df) {
  cols <- setdiff(names(df), ID_COLUMNS)
  cols[!grepl("_list$", cols) & cols != "gwfg_distance"]
}

coerce_stats <- function(df) {
  for (c in stat_columns(df)) df[[c]] <- suppressWarnings(as.numeric(df[[c]]))
  df
}

# Adds pos_group, current team (roster, falling back to the stats team), conference, division.
decorate <- function(df, roster, teams, settings) {
  df <- df[!is.na(df$player_id) & nzchar(df$player_id), , drop = FALSE]
  df$pos_group <- assign_pos_group(df$position, settings)
  df <- df[!is.na(df$pos_group), , drop = FALSE]
  df$games <- as.numeric(df$games)
  r <- roster[match(df$player_id, roster$gsis_id), , drop = FALSE]
  df$status <- r$status
  df$jersey_number <- r$jersey_number
  df$team <- ifelse(is.na(r$team), df$recent_team, r$team)
  t <- teams[match(df$team, teams$abbr), , drop = FALSE]
  df$team_name <- t$name
  df$conference <- t$conference
  df$division <- t$division
  df$team_color <- t$color
  rownames(df) <- NULL
  df
}

load_data <- function(root, auto_refresh = TRUE) {
  settings <- read_settings(root)
  paths <- cache_paths(root, settings$season)
  if (!all(file.exists(unlist(paths[c("reg", "week", "roster", "meta")])))) {
    if (!auto_refresh) stop("No cached data. Run refresh_data() first.")
    refresh_data(root)
  }
  reg <- read_nflverse_csv(paths$reg)
  week <- read_nflverse_csv(paths$week)
  roster <- read_nflverse_csv(paths$roster)
  roster <- roster[!is.na(roster$gsis_id) & !duplicated(roster$gsis_id), , drop = FALSE]
  teams <- read_teams(root)
  meta <- jsonlite::read_json(paths$meta)

  reg <- coerce_stats(reg[reg$season == settings$season & reg$season_type == "REG", , drop = FALSE])
  # Rows without a player_id are kept here: they still count toward team totals.
  week <- coerce_stats(week[week$season == settings$season & week$season_type == "REG", , drop = FALSE])

  list(
    settings = settings,
    meta = meta,
    teams = teams,
    roster = roster,
    week = week,
    players = decorate(reg, roster, teams, settings),
    weeks_available = sort(unique(week$week))
  )
}

weighted_mean_by <- function(x, w, g) {
  ok <- !is.na(x) & !is.na(w)
  num <- tapply(ifelse(ok, x * w, 0), g, sum)
  den <- tapply(ifelse(ok, w, 0), g, sum)
  out <- num / den
  out[!is.finite(out)] <- NA_real_
  out
}

# Rebuilds season-style rows from weekly rows for weeks [from, to].
aggregate_weeks <- function(data, from, to) {
  all_rows <- data$week[data$week$week >= from & data$week$week <= to, , drop = FALSE]
  team_tgt <- tapply(all_rows$targets, all_rows$team, sum, na.rm = TRUE)
  team_ay <- tapply(all_rows$receiving_air_yards, all_rows$team, sum, na.rm = TRUE)
  w <- all_rows[!is.na(all_rows$player_id) & nzchar(all_rows$player_id), , drop = FALSE]
  w <- w[order(w$player_id, w$week), , drop = FALSE]
  if (!nrow(w)) return(data$players[0, , drop = FALSE])
  ids <- sort(unique(w$player_id))
  g <- factor(w$player_id, levels = ids)
  last <- w[!duplicated(w$player_id, fromLast = TRUE), , drop = FALSE]
  last <- last[match(ids, last$player_id), , drop = FALSE]

  out <- data.frame(
    player_id = ids,
    player_name = last$player_name,
    player_display_name = last$player_display_name,
    position = last$position,
    position_group = last$position_group,
    headshot_url = last$headshot_url,
    season = data$settings$season,
    season_type = "REG",
    recent_team = last$team,
    games = as.numeric(tabulate(g, nbins = length(ids))),
    stringsAsFactors = FALSE
  )
  cols <- stat_columns(w)
  sum_cols <- setdiff(cols, c(WEIGHTED_BY_ATTEMPTS, MAX_COLUMNS, RECOMPUTED))
  sums <- rowsum(as.matrix(w[sum_cols]), g, na.rm = TRUE, reorder = TRUE)
  out <- cbind(out, as.data.frame(sums[ids, , drop = FALSE], row.names = NULL))
  for (c in intersect(WEIGHTED_BY_ATTEMPTS, cols)) out[[c]] <- as.numeric(weighted_mean_by(w[[c]], w$attempts, g)[ids])
  # Team denominators: sum over each distinct team the player appeared for.
  pt <- unique(w[, c("player_id", "team")])
  den_tgt <- tapply(unname(team_tgt[pt$team]), factor(pt$player_id, levels = ids), sum)
  den_ay <- tapply(unname(team_ay[pt$team]), factor(pt$player_id, levels = ids), sum)
  for (c in intersect(MAX_COLUMNS, cols)) {
    m <- suppressWarnings(tapply(w[[c]], g, max, na.rm = TRUE))
    m[!is.finite(m)] <- NA_real_
    out[[c]] <- as.numeric(m[ids])
  }
  safe_div <- function(a, b) { r <- a / b; r[!is.finite(r)] <- NA_real_; r }
  out$pacr <- safe_div(out$passing_yards, out$passing_air_yards)
  out$racr <- safe_div(out$receiving_yards, out$receiving_air_yards)
  out$fg_pct <- safe_div(out$fg_made, out$fg_att)
  out$pat_pct <- safe_div(out$pat_made, out$pat_att)
  out$target_share <- safe_div(out$targets, as.numeric(den_tgt[ids]))
  out$air_yards_share <- safe_div(out$receiving_air_yards, as.numeric(den_ay[ids]))
  out$wopr <- 1.5 * out$target_share + 0.7 * out$air_yards_share
  decorate(out, data$roster, data$teams, data$settings)
}

# Returns the player frame for a week range (full season uses the official season file).
player_frame <- function(data, weeks = NULL) {
  wk <- data$weeks_available
  if (is.null(weeks) || !length(wk) || (weeks[1] <= min(wk) && weeks[2] >= max(wk))) {
    return(data$players)
  }
  aggregate_weeks(data, weeks[1], weeks[2])
}
