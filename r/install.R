# Installs the R packages the Shiny app needs into the user library (Windows, macOS, Linux).
# Does nothing when everything is already installed, so the launchers run it every time.
lib <- Sys.getenv("R_LIBS_USER")
if (!dir.exists(lib)) dir.create(lib, recursive = TRUE)
.libPaths(c(lib, .libPaths()))
pkgs <- c("shiny", "bslib", "reactable", "plotly", "yaml", "jsonlite", "testthat")
missing <- pkgs[!pkgs %in% rownames(installed.packages())]
if (length(missing)) {
  cat("Installing:", paste(missing, collapse = ", "), "\n")
  cran <- "https://cloud.r-project.org"
  p3m <- "https://p3m.dev/cran/latest"
  is_windows <- .Platform$OS.type == "windows"
  is_mac <- Sys.info()[["sysname"]] == "Darwin"
  # Windows: Posit Package Manager first, because CRAN only builds Windows binaries
  # for the newest R release. macOS/Linux: CRAN first, Posit as a fallback.
  repos <- if (is_windows) c(P3M = p3m, CRAN = cran) else c(CRAN = cran, P3M = p3m)
  type <- if (is_windows || is_mac) "binary" else "source"
  install.packages(missing, lib = lib, repos = repos, type = type)
}
ok <- pkgs %in% rownames(installed.packages())
if (all(ok)) {
  cat("R packages ready.\n")
} else {
  cat("Still missing:", paste(pkgs[!ok], collapse = ", "), "- re-run this script.\n")
  quit(status = 1)
}
