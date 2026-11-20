r_dir <- normalizePath(file.path(testthat::test_path(), "..", ".."))
for (f in list.files(file.path(r_dir, "R"), pattern = "[.]R$", full.names = TRUE)) source(f)

settings <- list(
  season = 2026L,
  required_columns = list(reg = c("player_id", "season")),
  position_groups = list(QB = "QB", DB = c("CB", "SAF"))
)

test_that("validate_download rejects other seasons and missing columns", {
  expect_silent(validate_download(data.frame(player_id = "a", season = 2026), "reg", settings))
  expect_error(validate_download(data.frame(player_id = "a", season = 2025), "reg", settings), "expected only 2026")
  expect_error(validate_download(data.frame(player_id = c("a", "b"), season = c(2026, 2025)), "reg", settings), "2025")
  expect_error(validate_download(data.frame(season = 2026), "reg", settings), "missing columns: player_id")
})

test_that("assign_pos_group maps nflverse positions and drops unknown ones", {
  expect_equal(assign_pos_group(c("QB", "SAF", "OT"), settings), c("QB", "DB", NA))
})

test_that("aggregate_weeks sums counts and recomputes shares from team totals", {
  week <- data.frame(
    player_id = c("p1", "p1", "p2", "p2", NA), player_name = "x", player_display_name = c("A", "A", "B", "B", NA),
    position = "QB", position_group = "QB", headshot_url = NA, season = 2026, season_type = "REG",
    week = c(1, 2, 1, 2, 2), team = c("KC", "KC", "KC", "KC", "KC"),
    attempts = c(10, 30, 0, 0, 0), passing_cpoe = c(1, 5, NA, NA, NA),
    targets = c(2, 2, 6, 6, 4), receiving_air_yards = c(10, 10, 30, 30, 20),
    passing_yards = c(100, 200, 0, 0, 0), passing_air_yards = c(50, 100, 0, 0, 0),
    receiving_yards = c(0, 0, 50, 70, 0), fg_made = 0, fg_att = 0, pat_made = 0, pat_att = 0,
    stringsAsFactors = FALSE
  )
  data <- list(
    week = week, settings = c(settings, list()),
    roster = data.frame(gsis_id = character(), status = character(), jersey_number = character(), team = character()),
    teams = data.frame(abbr = "KC", name = "Chiefs", conference = "AFC", division = "AFC West", color = "#E31837")
  )
  a <- aggregate_weeks(data, 1, 2)
  p1 <- a[a$player_id == "p1", ]
  expect_equal(p1$games, 2)
  expect_equal(p1$passing_yards, 300)
  expect_equal(p1$passing_cpoe, (1 * 10 + 5 * 30) / 40)
  expect_equal(p1$pacr, 2)
  expect_equal(p1$target_share, 4 / 20)  # team total includes the row without a player_id
  expect_equal(p1$conference, "AFC")
  expect_equal(nrow(aggregate_weeks(data, 2, 2)), 2)
})
