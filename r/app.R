# NFL Player Rankings (2026) - Shiny app.
# Run: r/run.bat (Windows) or r/run.command (macOS/Linux), or from the project root:
#   Rscript -e "shiny::runApp('r', launch.browser = TRUE)"
# Files in r/R/ are sourced automatically by Shiny.

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(reactable)
  library(plotly)
})

ROOT <- project_root(getwd())

ui <- page_navbar(
  title = "NFL Player Rankings",
  theme = bs_theme(version = 5, primary = ACCENT),
  fillable = FALSE,
  nav_panel("Rankings", rankings_ui("rank")),
  nav_panel("Model", model_ui("model")),
  nav_spacer(),
  nav_item(uiOutput("data_badge"))
)

server <- function(input, output, session) {
  data_rv <- reactiveVal(load_data(ROOT))
  default_model <- read_model(default_model_path(ROOT))
  model_rv <- reactiveVal(default_model) # working model, used by both pages
  saved_rv <- reactiveVal(default_model) # last saved/loaded, baseline for rank movement

  output$data_badge <- renderUI({
    span(class = "small text-body-secondary", data_status_text(data_rv()$meta))
  })

  refresh <- function() {
    withProgress(message = "Refreshing 2026 data", value = 0, {
      res <- tryCatch({
        refresh_data(ROOT, progress = function(msg) incProgress(0.3, detail = msg))
        data_rv(load_data(ROOT))
        NULL
      }, error = function(e) conditionMessage(e))
      if (is.null(res)) {
        showNotification(paste("Data refreshed:", data_status_text(data_rv()$meta)), type = "message")
      } else {
        showNotification(paste("Refresh failed; existing data kept.", res), type = "error", duration = NULL)
      }
    })
  }

  rankings_server("rank", data_rv, model_rv, refresh)
  model_server("model", data_rv, model_rv, saved_rv, ROOT)
}

shinyApp(ui, server)
