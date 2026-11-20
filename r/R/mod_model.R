# Model page: per-position metrics, weights, direction, qualification and custom metrics.

MODEL_CSS <- "
.metric-row > div { min-width: 0; }
.metric-row .shiny-input-container { width: 100% !important; margin-bottom: 0; }
.metric-row .checkbox { margin: 0; }
"

model_ui <- function(id) {
  ns <- NS(id)
  tagList(tags$head(tags$style(HTML(MODEL_CSS))), layout_sidebar(
    sidebar = sidebar(
      width = 320,
      selectInput(ns("pos"), "Position", choices = POSITION_ORDER),
      radioButtons(ns("norm"), "Normalization", inline = TRUE,
                   choices = c("Percentile" = "percentile", "Z-score" = "zscore")),
      h6(class = "mt-2", "Qualification"),
      uiOutput(ns("qual_ui")),
      uiOutput(ns("vol_msg")),
      hr(),
      h6("Saved models"),
      uiOutput(ns("model_name")),
      selectInput(ns("load_name"), NULL, choices = NULL),
      div(class = "d-flex gap-2",
          actionButton(ns("load"), "Load", class = "btn-outline-primary btn-sm"),
          actionButton(ns("reset"), "Reset to default", class = "btn-outline-secondary btn-sm")),
      textInput(ns("save_name"), "Save as", placeholder = "e.g. Efficiency"),
      actionButton(ns("save"), "Save model", icon = icon("floppy-disk"), class = "btn-primary btn-sm"),
      div(class = "small text-body-secondary mt-1",
          "Saved to config/models/ — the Python app can load the same files.")
    ),
    layout_columns(
      col_widths = c(7, 5),
      card(
        card_header("Metrics and weights"),
        div(class = "small text-body-secondary mb-2",
            "Each metric is converted to a percentile against qualified players at this position. ",
            "The score is the weighted average, 0–100."),
        uiOutput(ns("metrics_ui")),
        card_footer(
          h6("Add a custom metric"),
          div(class = "d-flex gap-2 flex-wrap align-items-end",
              textInput(ns("new_label"), "Label", placeholder = "Scrimmage yds / g", width = "200px"),
              textInput(ns("new_expr"), "Expression", placeholder = "(rushing_yards + receiving_yards) / games", width = "320px"),
              actionButton(ns("add"), "Add", class = "btn-outline-primary mb-3")),
          uiOutput(ns("expr_msg")),
          div(class = "d-flex gap-2 align-items-end",
              selectInput(ns("remove_key"), "Remove a custom metric", choices = NULL, width = "240px"),
              actionButton(ns("remove"), "Remove", class = "btn-outline-danger mb-3"))
        )
      ),
      card(
        card_header("Preview: top 20 (full season)"),
        uiOutput(ns("preview_note")),
        reactableOutput(ns("preview"))
      )
    )
  ))
}

model_server <- function(id, data_rv, model_rv, saved_rv, root) {
  moduleServer(id, function(input, output, session) {
    ui_version <- reactiveVal(0)
    bump <- function() ui_version(ui_version() + 1)
    allowed_cols <- reactive(numeric_columns(data_rv()$players))
    mid <- function(field, pos, i) paste0(field, "_", pos, "_", i, "_v", ui_version())

    refresh_saved_list <- function(selected = NULL) {
      ch <- c("Default model" = "__default__", setNames(names(list_saved_models(root)), names(list_saved_models(root))))
      updateSelectInput(session, "load_name", choices = ch, selected = selected)
    }
    refresh_saved_list()

    sync_inputs <- function() {
      m <- model_rv()
      spec <- m$positions[[input$pos]]
      updateRadioButtons(session, "norm", selected = m$normalization)
      customs <- Filter(function(x) isTRUE(x$custom), spec$metrics)
      updateSelectInput(session, "remove_key",
                        choices = setNames(vapply(customs, `[[`, "", "key"), vapply(customs, `[[`, "", "label")))
    }
    observeEvent(input$pos, sync_inputs())

    output$model_name <- renderUI(div(class = "small", "Active: ", strong(model_rv()$name)))

    # ---- metric rows -------------------------------------------------------
    output$metrics_ui <- renderUI({
      pos <- input$pos
      ui_version()
      mets <- isolate(model_rv())$positions[[pos]]$metrics
      ns <- session$ns
      rows <- lapply(seq_along(mets), function(i) {
        m <- mets[[i]]
        div(
          class = "d-flex align-items-center gap-2 border-bottom py-1 metric-row",
          div(style = "flex:0 0 28px;", checkboxInput(ns(mid("inc", pos, i)), NULL, value = isTRUE(m$include))),
          div(style = "flex:1 1 140px;overflow-wrap:anywhere;",
              strong(m$label), if (isTRUE(m$custom)) span(class = "badge text-bg-info ms-1", "custom"),
              br(), tags$code(class = "small", m$expr)),
          div(style = "flex:0 0 150px;", sliderInput(ns(mid("w", pos, i)), NULL, min = 0, max = 10, step = 1,
                                                     value = m$weight, ticks = FALSE, width = "100%")),
          div(style = "flex:0 0 150px;", selectInput(ns(mid("dir", pos, i)), NULL, width = "100%",
                                                  choices = c("Higher is better" = "TRUE", "Lower is better" = "FALSE"),
                                                  selected = as.character(isTRUE(m$higher_is_better))))
        )
      })
      tagList(rows)
    })

    # Copy metric inputs back into the model.
    observe({
      pos <- input$pos
      ui_version()
      m <- isolate(model_rv())
      mets <- m$positions[[pos]]$metrics
      changed <- FALSE
      for (i in seq_along(mets)) {
        inc <- input[[mid("inc", pos, i)]]
        w <- input[[mid("w", pos, i)]]
        dir <- input[[mid("dir", pos, i)]]
        if (is.null(inc) || is.null(w) || is.null(dir)) next
        if (!identical(mets[[i]]$include, isTRUE(inc))) { mets[[i]]$include <- isTRUE(inc); changed <- TRUE }
        if (!identical(mets[[i]]$weight, as.numeric(w))) { mets[[i]]$weight <- as.numeric(w); changed <- TRUE }
        hib <- identical(dir, "TRUE")
        if (!identical(mets[[i]]$higher_is_better, hib)) { mets[[i]]$higher_is_better <- hib; changed <- TRUE }
      }
      if (changed) {
        m$positions[[pos]]$metrics <- mets
        model_rv(m)
      }
    })

    observeEvent(input$norm, {
      m <- model_rv()
      if (!identical(m$normalization, input$norm)) { m$normalization <- input$norm; model_rv(m) }
    }, ignoreInit = TRUE)

    # Qualification inputs are keyed by position (like metric rows) so switching
    # positions can never write one position's values into another.
    output$qual_ui <- renderUI({
      pos <- input$pos
      ui_version()
      q <- isolate(model_rv())$positions[[pos]]$qualify
      ns <- session$ns
      tagList(
        numericInput(ns(mid("mg", pos, 0)), "Minimum games", value = q$min_games, min = 0, step = 1),
        textInput(ns(mid("ve", pos, 0)), "Volume expression", value = q$volume),
        numericInput(ns(mid("mv", pos, 0)), "Minimum volume", value = q$min_volume, min = 0, step = 0.5)
      )
    })
    vol_check <- reactive({
      ve <- input[[mid("ve", input$pos, 0)]]
      if (is.null(ve)) return(list(ok = TRUE))
      validate_expr(ve, allowed_cols())
    })
    output$vol_msg <- renderUI({
      v <- vol_check()
      if (!v$ok) div(class = "small text-danger", v$error)
    })
    observe({
      pos <- input$pos
      mg <- input[[mid("mg", pos, 0)]]
      mv <- input[[mid("mv", pos, 0)]]
      ve <- input[[mid("ve", pos, 0)]]
      if (is.null(mg) || is.na(mg) || is.null(mv) || is.na(mv) || is.null(ve)) return()
      m <- isolate(model_rv())
      q <- m$positions[[pos]]$qualify
      new_q <- list(min_games = as.numeric(mg), volume = if (vol_check()$ok) ve else q$volume,
                    min_volume = as.numeric(mv))
      if (!identical(q[c("min_games", "volume", "min_volume")], new_q)) {
        m$positions[[pos]]$qualify <- new_q
        model_rv(m)
      }
    })

    # ---- custom metrics ----------------------------------------------------
    expr_check <- reactive({
      e <- trimws(input$new_expr %||% "")
      if (!nzchar(e)) return(NULL)
      validate_expr(e, allowed_cols())
    })
    output$expr_msg <- renderUI({
      v <- expr_check()
      if (is.null(v)) return(div(class = "small text-body-secondary mb-2",
                                 "Use + - * / and parentheses with any stats column name, e.g. passing_tds, targets, games."))
      if (!v$ok) return(div(class = "small text-danger mb-2", v$error))
      p <- data_rv()$players
      p <- p[p$pos_group == input$pos, ]
      vals <- eval_metric(trimws(input$new_expr), p)
      top <- head(p$player_display_name[order(-vals, na.last = NA)], 3)
      div(class = "small text-success mb-2",
          sprintf("Valid. %d players with a value; highest: %s", sum(!is.na(vals)), paste(top, collapse = ", ")))
    })

    observeEvent(input$add, {
      v <- expr_check()
      label <- trimws(input$new_label %||% "")
      if (is.null(v) || !v$ok) return(showNotification("Enter a valid expression first", type = "warning"))
      if (!nzchar(label)) return(showNotification("Enter a label for the metric", type = "warning"))
      m <- model_rv()
      pos <- input$pos
      keys <- vapply(m$positions[[pos]]$metrics, `[[`, "", "key")
      key <- paste0("custom_", gsub("[^a-z0-9]+", "_", tolower(label)))
      while (key %in% keys) key <- paste0(key, "_2")
      m$positions[[pos]]$metrics[[length(m$positions[[pos]]$metrics) + 1]] <- list(
        key = key, label = label, expr = trimws(input$new_expr), higher_is_better = TRUE,
        weight = 5, include = TRUE, custom = TRUE)
      model_rv(m)
      updateTextInput(session, "new_label", value = "")
      updateTextInput(session, "new_expr", value = "")
      sync_inputs()
      bump()
    })

    observeEvent(input$remove, {
      req(input$remove_key)
      m <- model_rv()
      pos <- input$pos
      m$positions[[pos]]$metrics <- Filter(function(x) !identical(x$key, input$remove_key), m$positions[[pos]]$metrics)
      model_rv(m)
      sync_inputs()
      bump()
    })

    # ---- load / save / reset ----------------------------------------------
    apply_model <- function(m) {
      model_rv(m)
      saved_rv(m)
      sync_inputs()
      bump()
    }
    observeEvent(input$reset, {
      apply_model(read_model(default_model_path(root)))
      showNotification("Default model restored", type = "message")
    })
    observeEvent(input$load, {
      req(input$load_name)
      path <- if (input$load_name == "__default__") default_model_path(root) else list_saved_models(root)[[input$load_name]]
      m <- tryCatch(read_model(path), error = function(e) e)
      if (inherits(m, "error")) return(showNotification(paste("Could not load:", conditionMessage(m)), type = "error"))
      bad <- unlist(lapply(m$positions, function(s) vapply(s$metrics, function(x) {
        v <- validate_expr(x$expr, allowed_cols()); if (v$ok) "" else paste0(x$label, ": ", v$error)
      }, "")))
      bad <- bad[nzchar(bad)]
      if (length(bad)) return(showNotification(paste("Model has invalid metrics:", paste(bad, collapse = "; ")), type = "error"))
      apply_model(m)
      showNotification(sprintf("Loaded \"%s\"", m$name), type = "message")
    })
    observeEvent(input$save, {
      name <- trimws(input$save_name %||% "")
      path <- tryCatch(save_model(model_rv(), root, name), error = function(e) e)
      if (inherits(path, "error")) return(showNotification(conditionMessage(path), type = "error"))
      m <- model_rv(); m$name <- name
      model_rv(m)
      saved_rv(m)
      refresh_saved_list(selected = tools::file_path_sans_ext(basename(path)))
      showNotification(sprintf("Saved to %s", path), type = "message")
    })

    # ---- preview -----------------------------------------------------------
    preview_data <- reactive({
      pos <- input$pos
      p <- data_rv()$players
      p <- p[p$pos_group == pos, ]
      cur <- score_players(p, model_rv())$scores
      old <- score_players(p, saved_rv())$scores
      cur$saved_rank <- old$pos_rank[match(cur$player_id, old$player_id)]
      cur <- cur[!is.na(cur$pos_rank), ]
      cur <- cur[order(cur$pos_rank), ]
      info <- p[match(cur$player_id, p$player_id), ]
      list(n_qual = nrow(cur), n_all = nrow(p), df = head(data.frame(
        rank = cur$pos_rank, player = info$player_display_name, team = info$team,
        score = round(cur$score, 1), move = cur$saved_rank - cur$pos_rank, stringsAsFactors = FALSE
      ), 20))
    })
    output$preview_note <- renderUI({
      pd <- preview_data()
      div(class = "small text-body-secondary mb-2",
          sprintf("%d of %d %s players qualify. Movement is compared with the last saved/loaded model (%s).",
                  pd$n_qual, pd$n_all, input$pos, saved_rv()$name))
    })
    output$preview <- renderReactable({
      df <- preview_data()$df
      reactable(df, compact = TRUE, pagination = FALSE, sortable = FALSE, columns = list(
        rank = colDef(name = "#", width = 36, align = "right"),
        player = colDef(name = "Player", minWidth = 110),
        team = colDef(name = "Team", width = 60),
        score = colDef(name = "Score", width = 130, cell = function(v) score_bar_cell(v, bar_px = 70)),
        move = colDef(name = "Δ", width = 52, align = "right", cell = function(v) {
          if (is.na(v)) return(span(class = "text-body-secondary", "new"))
          if (v > 0) return(span(class = "text-success", paste0("▲", v)))
          if (v < 0) return(span(class = "text-danger", paste0("▼", -v)))
          span(class = "text-body-secondary", "–")
        })
      ))
    })
  })
}
