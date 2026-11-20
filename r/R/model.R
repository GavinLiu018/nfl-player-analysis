# Ranking model: expression validation, metric evaluation, normalization and scoring.
# Mirrors python/nflrank/model.py — keep the two in sync.

ALLOWED_CALLS <- c("+", "-", "*", "/", "(")

default_model_path <- function(root) file.path(root, "config", "model_default.yaml")
models_dir <- function(root) file.path(root, "config", "models")

read_model <- function(path) normalize_model(yaml::read_yaml(path))

normalize_model <- function(m) {
  if (is.null(m$normalization)) m$normalization <- "percentile"
  if (is.null(m$name)) m$name <- "Untitled"
  for (pos in names(m$positions)) {
    p <- m$positions[[pos]]
    p$qualify$min_games <- as.numeric(p$qualify$min_games %||% 0)
    p$qualify$min_volume <- as.numeric(p$qualify$min_volume %||% 0)
    p$qualify$volume <- p$qualify$volume %||% "games"
    p$metrics <- lapply(p$metrics, function(x) {
      x$weight <- as.numeric(x$weight %||% 0)
      x$higher_is_better <- isTRUE(x$higher_is_better %||% TRUE)
      x$include <- !identical(x$include, FALSE)
      x$custom <- isTRUE(x$custom)
      x
    })
    m$positions[[pos]] <- p
  }
  m
}

`%||%` <- function(a, b) if (is.null(a)) b else a

list_saved_models <- function(root) {
  f <- list.files(models_dir(root), pattern = "\\.ya?ml$", full.names = TRUE)
  setNames(f, tools::file_path_sans_ext(basename(f)))
}

safe_model_filename <- function(name) {
  s <- gsub("[^A-Za-z0-9_-]+", "_", trimws(name))
  s <- gsub("^_+|_+$", "", s)
  if (!nzchar(s)) stop("Model name must contain letters or digits")
  s
}

save_model <- function(model, root, name) {
  dir.create(models_dir(root), recursive = TRUE, showWarnings = FALSE)
  model$name <- name
  path <- file.path(models_dir(root), paste0(safe_model_filename(name), ".yaml"))
  yaml::write_yaml(model, path)
  path
}

# Checks that `expr` is arithmetic over known columns. Returns list(ok, error, vars).
validate_expr <- function(expr, allowed_cols) {
  if (!is.character(expr) || length(expr) != 1 || !nzchar(trimws(expr))) {
    return(list(ok = FALSE, error = "Expression is empty", vars = character()))
  }
  parsed <- tryCatch(parse(text = expr, keep.source = FALSE), error = function(e) e)
  if (inherits(parsed, "error")) {
    return(list(ok = FALSE, error = paste("Syntax error:", conditionMessage(parsed)), vars = character()))
  }
  if (length(parsed) != 1) return(list(ok = FALSE, error = "Use a single expression", vars = character()))
  vars <- character()
  walk <- function(x) {
    if (is.numeric(x) && length(x) == 1 && is.finite(x)) return(NULL)
    if (is.name(x)) {
      nm <- as.character(x)
      if (!nm %in% allowed_cols) return(sprintf("Unknown column: %s", nm))
      vars <<- c(vars, nm)
      return(NULL)
    }
    if (is.call(x)) {
      if (!is.name(x[[1]]) || !as.character(x[[1]]) %in% ALLOWED_CALLS) {
        return(sprintf("Not allowed: %s (only + - * / and parentheses)", deparse(x[[1]])[1]))
      }
      for (a in as.list(x)[-1]) {
        err <- walk(a)
        if (!is.null(err)) return(err)
      }
      return(NULL)
    }
    sprintf("Not allowed: %s", deparse(x)[1])
  }
  err <- walk(parsed[[1]])
  if (!is.null(err)) return(list(ok = FALSE, error = err, vars = character()))
  list(ok = TRUE, error = NULL, vars = unique(vars))
}

numeric_columns <- function(df) names(df)[vapply(df, is.numeric, logical(1))]

# Evaluates a validated expression against df; non-finite results become NA.
eval_metric <- function(expr, df) {
  v <- validate_expr(expr, numeric_columns(df))
  if (!v$ok) stop(v$error)
  env <- lapply(df[v$vars], as.numeric)
  out <- eval(parse(text = expr, keep.source = FALSE)[[1]], envir = env, enclos = baseenv())
  out <- rep_len(as.numeric(out), nrow(df))
  out[!is.finite(out)] <- NA_real_
  out
}

# Share of reference values below x, counting ties as half.
percentile_of <- function(x, ref) {
  out <- rep(NA_real_, length(x))
  ref <- sort(ref[!is.na(ref)])
  n <- length(ref)
  ok <- !is.na(x)
  if (!n || !any(ok)) return(out)
  less <- findInterval(x[ok], ref, left.open = TRUE)
  leq <- findInterval(x[ok], ref)
  out[ok] <- (less + 0.5 * (leq - less)) / n
  out
}

zscore_of <- function(x, ref) {
  ref <- ref[!is.na(ref)]
  if (length(ref) < 2) return(rep(NA_real_, length(x)))
  s <- stats::sd(ref)
  if (!is.finite(s) || s == 0) return(rep(NA_real_, length(x)))
  stats::pnorm((x - mean(ref)) / s)
}

active_metrics <- function(pos_spec) {
  Filter(function(m) isTRUE(m$include) && m$weight > 0, pos_spec$metrics)
}

# Scores every player in df. Returns list(scores = <one row per player>, breakdown = <long>).
score_players <- function(df, model) {
  score_rows <- list()
  breakdown_rows <- list()
  for (pos in names(model$positions)) {
    spec <- model$positions[[pos]]
    sub <- df[df$pos_group == pos, , drop = FALSE]
    if (!nrow(sub)) next
    volume <- eval_metric(spec$qualify$volume, sub)
    qualified <- sub$games >= spec$qualify$min_games & !is.na(volume) & volume >= spec$qualify$min_volume
    qualified[is.na(qualified)] <- FALSE

    num <- numeric(nrow(sub))
    den <- numeric(nrow(sub))
    for (m in spec$metrics) {
      value <- eval_metric(m$expr, sub)
      ref <- value[qualified]
      p <- if (identical(model$normalization, "zscore")) zscore_of(value, ref) else percentile_of(value, ref)
      if (!isTRUE(m$higher_is_better)) p <- 1 - p
      used <- isTRUE(m$include) && m$weight > 0
      if (used) {
        has <- !is.na(p)
        num[has] <- num[has] + m$weight * p[has]
        den[has] <- den[has] + m$weight
      }
      breakdown_rows[[length(breakdown_rows) + 1]] <- data.frame(
        player_id = sub$player_id, pos_group = pos, key = m$key, label = m$label,
        value = value, pct = p, weight = if (used) m$weight else 0,
        higher_is_better = isTRUE(m$higher_is_better), stringsAsFactors = FALSE
      )
    }
    score <- ifelse(den > 0, 100 * num / den, NA_real_)
    pos_rank <- rep(NA_integer_, nrow(sub))
    q_idx <- which(qualified & !is.na(score))
    ord <- q_idx[order(-score[q_idx], sub$player_id[q_idx])]
    pos_rank[ord] <- seq_along(ord)
    score_rows[[length(score_rows) + 1]] <- data.frame(
      player_id = sub$player_id, pos_group = pos, score = score, qualified = qualified,
      volume = volume, pos_rank = pos_rank, stringsAsFactors = FALSE
    )
  }
  scores <- if (length(score_rows)) do.call(rbind, score_rows) else
    data.frame(player_id = character(), pos_group = character(), score = numeric(),
               qualified = logical(), volume = numeric(), pos_rank = integer())
  breakdown <- if (length(breakdown_rows)) do.call(rbind, breakdown_rows) else data.frame()
  list(scores = scores, breakdown = breakdown)
}

# Convenience: player frame joined with scores.
ranked_players <- function(df, model) {
  s <- score_players(df, model)
  out <- merge(df, s$scores[, c("player_id", "score", "qualified", "volume", "pos_rank")],
               by = "player_id", all.x = TRUE, sort = FALSE)
  list(players = out, breakdown = s$breakdown)
}
