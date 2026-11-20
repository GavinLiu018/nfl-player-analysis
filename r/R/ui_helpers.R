# Shared UI helpers for the Shiny app.

# Validated categorical pair (dataviz reference palette, slots 1-2).
CONF_COLORS <- c(AFC = "#2a78d6", NFC = "#eb6834")
ACCENT <- "#2a78d6"
MUTED <- "#b4b2a9"

POSITION_ORDER <- c("QB", "RB", "WR", "TE", "DL", "LB", "DB", "K", "P")

# Columns shown when several positions are mixed in the table.
GENERIC_STATS <- c(
  "Fantasy pts (PPR)" = "fantasy_points_ppr", "Pass yds" = "passing_yards",
  "Rush yds" = "rushing_yards", "Rec yds" = "receiving_yards",
  "Tackles" = "def_tackles_solo", "Sacks" = "def_sacks", "INTs" = "def_interceptions"
)

TREND_STATS <- c(
  "Fantasy points (PPR)" = "fantasy_points_ppr", "Passing yards" = "passing_yards",
  "Passing EPA" = "passing_epa", "Rushing yards" = "rushing_yards", "Carries" = "carries",
  "Receiving yards" = "receiving_yards", "Targets" = "targets", "Receptions" = "receptions",
  "Solo tackles" = "def_tackles_solo", "Sacks" = "def_sacks", "QB hits" = "def_qb_hits",
  "Passes defended" = "def_pass_defended", "FG made" = "fg_made", "Punt net yards" = "pt_net_yards"
)

default_trend_stat <- function(pos) {
  switch(pos %||% "",
    QB = "passing_yards", RB = "rushing_yards", WR = , TE = "receiving_yards",
    DL = "def_sacks", LB = , DB = "def_tackles_solo", K = "fg_made", P = "pt_net_yards",
    "fantasy_points_ppr")
}

is_pct_label <- function(label) grepl("%", label, fixed = TRUE)

format_metric <- function(x, label) {
  label <- rep_len(as.character(label), length(x))
  ifelse(is.na(x), "—",
         ifelse(is_pct_label(label), sprintf("%.1f%%", 100 * x), formatC(x, format = "f", digits = 2)))
}

fmt_fetched <- function(meta) {
  t <- as.POSIXct(meta$fetched_at %||% NA, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  if (is.na(t)) return("unknown")
  format(t, "%b %d, %Y %H:%M", tz = "")
}

data_status_text <- function(meta) {
  sprintf("%s season · through Week %s · data as of %s",
          meta$season, meta$latest_week %||% "?", fmt_fetched(meta))
}

score_bar_cell <- function(value, bar_px = 90) {
  if (is.na(value)) return("—")
  htmltools::div(
    style = "display:flex;align-items:center;gap:8px;",
    htmltools::div(
      style = sprintf("flex:0 0 %dpx;height:10px;background:rgba(127,127,127,.15);border-radius:4px;", bar_px),
      htmltools::div(style = sprintf(
        "width:%.1f%%;height:100%%;background:%s;border-radius:0 4px 4px 0;", value, ACCENT))
    ),
    htmltools::span(style = "font-variant-numeric:tabular-nums;", sprintf("%.1f", value))
  )
}

plotly_defaults <- function(p) {
  p |>
    plotly::config(displaylogo = FALSE, modeBarButtonsToRemove = c("lasso2d", "select2d")) |>
    plotly::layout(
      paper_bgcolor = "rgba(0,0,0,0)", plot_bgcolor = "rgba(0,0,0,0)",
      font = list(family = "system-ui, -apple-system, Segoe UI, sans-serif", size = 12),
      hoverlabel = list(font = list(size = 12)),
      margin = list(l = 10, r = 20, t = 10, b = 40)
    )
}

empty_plot <- function(msg) {
  plotly::plot_ly(type = "scatter", mode = "markers") |>
    plotly::layout(
      xaxis = list(visible = FALSE), yaxis = list(visible = FALSE),
      annotations = list(list(text = msg, showarrow = FALSE, font = list(size = 14)))
    ) |>
    plotly_defaults()
}

# Wide table of metric values (one column per metric label) for one position.
metric_wide <- function(breakdown, pos) {
  b <- breakdown[breakdown$pos_group == pos, c("player_id", "key", "label", "value"), drop = FALSE]
  if (!nrow(b)) return(NULL)
  keys <- unique(b$key)
  out <- data.frame(player_id = unique(b$player_id), stringsAsFactors = FALSE)
  labels <- character()
  for (k in keys) {
    bk <- b[b$key == k, ]
    out[[k]] <- bk$value[match(out$player_id, bk$player_id)]
    labels[k] <- bk$label[1]
  }
  attr(out, "labels") <- labels
  out
}
