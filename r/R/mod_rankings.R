# Rankings page: filters, sortable table, charts and player detail.

rankings_ui <- function(id) {
  ns <- NS(id)
  layout_sidebar(
    sidebar = sidebar(
      width = 300,
      actionButton(ns("refresh"), "Refresh data", icon = icon("rotate"), class = "btn-primary"),
      uiOutput(ns("status")),
      selectizeInput(ns("pos"), "Position", choices = POSITION_ORDER, multiple = TRUE,
                     options = list(placeholder = "All positions")),
      checkboxGroupInput(ns("conf"), "Conference", c("AFC", "NFC"), inline = TRUE),
      selectizeInput(ns("div"), "Division", choices = NULL, multiple = TRUE,
                     options = list(placeholder = "All divisions")),
      selectizeInput(ns("team"), "Team", choices = NULL, multiple = TRUE,
                     options = list(placeholder = "All teams")),
      textInput(ns("search"), "Player search", placeholder = "Name contains…"),
      sliderInput(ns("weeks"), "Weeks", min = 1, max = 18, value = c(1, 18), step = 1, ticks = FALSE),
      numericInput(ns("min_games"), "Minimum games", value = 0, min = 0, step = 1),
      checkboxInput(ns("qual_only"), "Qualified players only", value = TRUE)
    ),
    navset_card_tab(
      full_screen = TRUE,
      nav_panel("Table", reactableOutput(ns("table"))),
      nav_panel(
        "Top players",
        div(class = "d-flex gap-3 align-items-end",
            numericInput(ns("top_n"), "Show top", value = 25, min = 5, max = 100, step = 5, width = "120px")),
        plotlyOutput(ns("bar"), height = "640px")
      ),
      nav_panel(
        "Scatter",
        div(class = "d-flex gap-3",
            selectInput(ns("x"), "X axis", choices = NULL, width = "240px"),
            selectInput(ns("y"), "Y axis", choices = NULL, width = "240px")),
        plotlyOutput(ns("scatter"), height = "600px")
      )
    ),
    card(
      card_header(uiOutput(ns("detail_title"))),
      layout_columns(
        col_widths = c(6, 6),
        div(h6("Score breakdown (percentile vs qualified players at the position)"),
            plotlyOutput(ns("breakdown"), height = "320px")),
        div(div(class = "d-flex gap-2 align-items-center",
                h6(class = "mb-0", "Weekly trend"),
                selectInput(ns("trend_stat"), NULL, choices = TREND_STATS, width = "220px")),
            plotlyOutput(ns("trend"), height = "300px"))
      )
    )
  )
}

rankings_server <- function(id, data_rv, model_rv, refresh) {
  moduleServer(id, function(input, output, session) {
    observeEvent(input$refresh, refresh())

    output$status <- renderUI({
      m <- data_rv()$meta
      div(class = "small text-body-secondary", data_status_text(m))
    })

    # Week slider follows the weeks present in the data.
    observeEvent(data_rv(), {
      wk <- data_rv()$weeks_available
      if (length(wk)) {
        updateSliderInput(session, "weeks", min = min(wk), max = max(wk), value = c(min(wk), max(wk)))
      }
    })

    # Division choices follow the conference; team choices follow both.
    observe({
      teams <- data_rv()$teams
      divs <- sort(unique(teams$division[!length(input$conf) | teams$conference %in% input$conf]))
      updateSelectizeInput(session, "div", choices = divs, selected = intersect(isolate(input$div), divs))
    })
    observe({
      teams <- data_rv()$teams
      keep <- (!length(input$conf) | teams$conference %in% input$conf) &
        (!length(input$div) | teams$division %in% input$div)
      t <- teams[keep, ]
      t <- t[order(t$name), ]
      choices <- setNames(t$abbr, sprintf("%s (%s)", t$name, t$abbr))
      updateSelectizeInput(session, "team", choices = choices, selected = intersect(isolate(input$team), t$abbr))
    })

    weeks <- debounce(reactive(input$weeks), 400)
    frame <- reactive(player_frame(data_rv(), weeks()))
    ranked <- reactive(ranked_players(frame(), model_rv()))

    filtered <- reactive({
      p <- ranked()$players
      if (length(input$pos)) p <- p[p$pos_group %in% input$pos, ]
      if (length(input$conf)) p <- p[p$conference %in% input$conf, ]
      if (length(input$div)) p <- p[p$division %in% input$div, ]
      if (length(input$team)) p <- p[p$team %in% input$team, ]
      s <- trimws(input$search %||% "")
      if (nzchar(s)) p <- p[grepl(tolower(s), tolower(p$player_display_name), fixed = TRUE), ]
      p <- p[!is.na(p$games) & p$games >= (input$min_games %||% 0), ]
      if (isTRUE(input$qual_only)) p <- p[p$qualified %in% TRUE, ]
      p <- p[order(-ifelse(is.na(p$score), -Inf, p$score), p$player_display_name), ]
      p$rank <- seq_len(nrow(p))
      p
    })

    single_pos <- reactive(if (length(input$pos) == 1) input$pos else NULL)

    table_data <- reactive({
      p <- filtered()
      base <- data.frame(
        rank = p$rank, headshot = p$headshot_url, player = p$player_display_name,
        team = p$team, pos = p$position, group = p$pos_group, games = p$games,
        score = round(p$score, 1), pos_rank = p$pos_rank,
        qualified = ifelse(p$qualified %in% TRUE, "", "NQ"),
        stringsAsFactors = FALSE
      )
      labels <- character()
      if (!is.null(single_pos())) {
        wide <- metric_wide(ranked()$breakdown, single_pos())
        if (!is.null(wide)) {
          labels <- attr(wide, "labels")
          vals <- wide[match(p$player_id, wide$player_id), names(labels), drop = FALSE]
          base <- cbind(base, vals)
        }
      } else {
        for (nm in names(GENERIC_STATS)) base[[GENERIC_STATS[[nm]]]] <- p[[GENERIC_STATS[[nm]]]]
        labels <- setNames(names(GENERIC_STATS), GENERIC_STATS)
      }
      list(df = base, labels = labels, metric_mode = !is.null(single_pos()))
    })

    output$table <- renderReactable({
      td <- table_data()
      df <- td$df
      cols <- list(
        rank = colDef(name = "#", width = 50, align = "right"),
        headshot = colDef(name = "", width = 48, sortable = FALSE, cell = function(v) {
          if (is.na(v)) "" else htmltools::img(src = v, height = 32, style = "border-radius:50%;object-fit:cover;", alt = "")
        }),
        player = colDef(name = "Player", minWidth = 170),
        team = colDef(name = "Team", width = 64),
        pos = colDef(name = "Pos", width = 56),
        group = colDef(show = FALSE),
        games = colDef(name = "G", width = 50, align = "right"),
        score = colDef(name = "Score", minWidth = 150, cell = score_bar_cell, defaultSortOrder = "desc"),
        pos_rank = colDef(name = "Pos rank", width = 80, align = "right",
                          cell = function(v, i) if (is.na(v)) "—" else paste0(df$group[i], v)),
        qualified = colDef(name = "", width = 44)
      )
      for (k in names(td$labels)) {
        lab <- td$labels[[k]]
        cols[[k]] <- colDef(
          name = lab, align = "right", minWidth = 90,
          cell = if (td$metric_mode) local({ l <- lab; function(v) format_metric(v, l) })
                 else function(v) if (is.na(v)) "—" else format(round(v, 1), big.mark = ",")
        )
      }
      reactable(
        df, columns = cols, selection = "single", onClick = "select", highlight = TRUE,
        compact = TRUE, striped = TRUE, defaultPageSize = 25, showPageSizeOptions = TRUE,
        pageSizeOptions = c(25, 50, 100), defaultSelected = if (nrow(df)) 1L else NULL,
        theme = reactableTheme(rowSelectedStyle = list(backgroundColor = "rgba(42,120,214,.15)")),
        language = reactableLang(noData = "No players match these filters")
      )
    })

    selected_player <- reactive({
      p <- filtered()
      if (!nrow(p)) return(NULL)
      sel <- getReactableState("table", "selected")
      i <- if (length(sel) && sel[1] <= nrow(p)) sel[1] else 1L
      p[i, ]
    })

    observeEvent(selected_player(), {
      sp <- selected_player()
      if (!is.null(sp)) updateSelectInput(session, "trend_stat", selected = default_trend_stat(sp$pos_group))
    }, ignoreNULL = TRUE)

    output$detail_title <- renderUI({
      sp <- selected_player()
      if (is.null(sp)) return("Select a player")
      tagList(
        strong(sp$player_display_name), " · ", sp$position, " · ", sp$team_name %||% sp$team,
        span(class = "text-body-secondary ms-2",
             sprintf("Score %s%s", ifelse(is.na(sp$score), "—", sprintf("%.1f", sp$score)),
                     ifelse(is.na(sp$pos_rank), " (not qualified)", sprintf(" · #%d %s", sp$pos_rank, sp$pos_group))))
      )
    })

    output$breakdown <- renderPlotly({
      sp <- selected_player()
      if (is.null(sp)) return(empty_plot("No player selected"))
      b <- ranked()$breakdown
      b <- b[b$player_id == sp$player_id & b$pos_group == sp$pos_group, ]
      if (!nrow(b)) return(empty_plot("No metrics"))
      b$pct100 <- round(100 * b$pct, 1)
      b$label <- factor(b$label, levels = rev(b$label))
      b$color <- ifelse(b$weight > 0, ACCENT, MUTED)
      b$hover <- sprintf("%s<br>Value: %s<br>Percentile: %s<br>Weight: %s%s",
                         b$label, format_metric(b$value, as.character(b$label)),
                         ifelse(is.na(b$pct100), "—", b$pct100), b$weight,
                         ifelse(b$higher_is_better, "", "<br>(lower is better)"))
      plot_ly(b, x = ~pct100, y = ~label, type = "bar", orientation = "h",
              marker = list(color = ~color), text = ~hover, hoverinfo = "text", textposition = "none") |>
        layout(xaxis = list(title = "Percentile", range = c(0, 100), gridcolor = "rgba(127,127,127,.2)"),
               yaxis = list(title = "")) |>
        plotly_defaults()
    })

    output$trend <- renderPlotly({
      sp <- selected_player()
      stat <- input$trend_stat
      if (is.null(sp) || is.null(stat)) return(empty_plot("No player selected"))
      w <- data_rv()$week
      w <- w[w$player_id %in% sp$player_id, , drop = FALSE]
      w <- w[order(w$week), ]
      if (!nrow(w) || !stat %in% names(w)) return(empty_plot("No weekly data"))
      label <- names(TREND_STATS)[TREND_STATS == stat]
      w$y <- w[[stat]]
      w$hover <- sprintf("Week %d vs %s<br>%s: %s", w$week, w$opponent_team, label,
                         ifelse(is.na(w$y), "—", format(round(w$y, 2))))
      plot_ly(w, x = ~week, y = ~y, type = "scatter", mode = "lines+markers",
              line = list(color = ACCENT, width = 2), marker = list(color = ACCENT, size = 8),
              text = ~hover, hoverinfo = "text") |>
        layout(xaxis = list(title = "Week", dtick = 1, gridcolor = "rgba(127,127,127,.2)"),
               yaxis = list(title = label, gridcolor = "rgba(127,127,127,.2)", zerolinecolor = "rgba(127,127,127,.4)")) |>
        plotly_defaults()
    })

    output$bar <- renderPlotly({
      p <- filtered()
      p <- p[!is.na(p$score), ]
      n <- max(5, min(100, input$top_n %||% 25))
      p <- head(p, n)
      if (!nrow(p)) return(empty_plot("No players match these filters"))
      p$label <- factor(sprintf("%d. %s (%s, %s)", p$rank, p$player_display_name, p$position, p$team),
                        levels = rev(sprintf("%d. %s (%s, %s)", p$rank, p$player_display_name, p$position, p$team)))
      p$hover <- sprintf("%s<br>%s · %s<br>Score %.1f", p$player_display_name, p$team_name, p$division, p$score)
      plt <- plot_ly(height = max(320, 22 * nrow(p) + 80))
      for (cf in names(CONF_COLORS)) {
        d <- p[p$conference %in% cf, ]
        if (nrow(d)) plt <- add_trace(plt, data = d, x = ~score, y = ~label, type = "bar", orientation = "h",
                                      name = cf, marker = list(color = CONF_COLORS[[cf]]),
                                      text = ~hover, hoverinfo = "text", textposition = "none")
      }
      plt |>
        layout(barmode = "overlay", bargap = 0.25,
               xaxis = list(title = "Score", range = c(0, 100), gridcolor = "rgba(127,127,127,.2)"),
               yaxis = list(title = "", categoryorder = "array", categoryarray = levels(p$label)),
               legend = list(orientation = "h", y = 1.02, x = 0, yanchor = "bottom")) |>
        plotly_defaults()
    })

    # Scatter axes: model metrics when one position is selected, otherwise generic stats.
    observe({
      pos <- single_pos()
      ch <- c("Score" = "score")
      if (!is.null(pos)) {
        mets <- model_rv()$positions[[pos]]$metrics
        ch <- c(ch, setNames(vapply(mets, `[[`, "", "key"), vapply(mets, `[[`, "", "label")))
      } else {
        ch <- c(ch, GENERIC_STATS, "Games" = "games")
      }
      x_sel <- if (isolate(input$x) %in% ch) isolate(input$x) else ch[min(2, length(ch))]
      y_sel <- if (isolate(input$y) %in% ch) isolate(input$y) else "score"
      updateSelectInput(session, "x", choices = ch, selected = x_sel)
      updateSelectInput(session, "y", choices = ch, selected = y_sel)
    })

    output$scatter <- renderPlotly({
      p <- filtered()
      req(input$x, input$y)
      getv <- function(key) {
        if (key %in% names(p)) return(p[[key]])
        b <- ranked()$breakdown
        b <- b[b$key == key & b$pos_group %in% (single_pos() %||% ""), ]
        b$value[match(p$player_id, b$player_id)]
      }
      p$xv <- getv(input$x)
      p$yv <- getv(input$y)
      p <- p[!is.na(p$xv) & !is.na(p$yv), ]
      if (!nrow(p)) return(empty_plot("No players with both values"))
      p$hover <- sprintf("%s (%s, %s)<br>x: %s<br>y: %s<br>Score %s", p$player_display_name, p$position,
                         p$team, signif(p$xv, 4), signif(p$yv, 4),
                         ifelse(is.na(p$score), "—", sprintf("%.1f", p$score)))
      plt <- plot_ly()
      for (cf in names(CONF_COLORS)) {
        d <- p[p$conference %in% cf, ]
        if (nrow(d)) plt <- add_trace(plt, data = d, x = ~xv, y = ~yv, type = "scatter", mode = "markers",
                                      name = cf, text = ~hover, hoverinfo = "text",
                                      marker = list(color = CONF_COLORS[[cf]], size = 9, opacity = 0.85,
                                                    line = list(color = "#fcfcfb", width = 1)))
      }
      lab <- function(k) {
        all <- c(Score = "score", GENERIC_STATS, Games = "games")
        if (k %in% all) return(names(all)[all == k][1])
        mets <- model_rv()$positions[[single_pos() %||% ""]]$metrics
        for (m in mets) if (identical(m$key, k)) return(m$label)
        k
      }
      plt |>
        layout(xaxis = list(title = lab(input$x), gridcolor = "rgba(127,127,127,.2)"),
               yaxis = list(title = lab(input$y), gridcolor = "rgba(127,127,127,.2)"),
               legend = list(orientation = "h", y = 1.02, x = 0, yanchor = "bottom")) |>
        plotly_defaults()
    })
  })
}
