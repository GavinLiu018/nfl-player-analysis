r_dir <- normalizePath(file.path(testthat::test_path(), "..", ".."))
for (f in list.files(file.path(r_dir, "R"), pattern = "[.]R$", full.names = TRUE)) source(f)

test_that("percentile counts ties as half and ignores NA", {
  ref <- c(1, 2, 2, 3, NA)
  expect_equal(percentile_of(c(0, 1, 2, 3, 4, NA), ref), c(0, 0.125, 0.5, 0.875, 1, NA))
  expect_true(all(is.na(percentile_of(c(1, 2), numeric()))))
})

test_that("zscore maps the mean to 0.5 and needs spread", {
  expect_equal(zscore_of(2, c(1, 2, 3)), 0.5)
  expect_true(is.na(zscore_of(2, c(2, 2, 2))))
})

test_that("validate_expr allows arithmetic over known columns only", {
  cols <- c("a", "b")
  expect_true(validate_expr("(a + b) / 2 - -a * 3", cols)$ok)
  expect_false(validate_expr("system('x')", cols)$ok)
  expect_false(validate_expr("a ^ 2", cols)$ok)
  expect_false(validate_expr("c + 1", cols)$ok)
  expect_false(validate_expr("a; b", cols)$ok)
  expect_false(validate_expr("a$b", cols)$ok)
  expect_false(validate_expr("", cols)$ok)
  expect_match(validate_expr("zzz / a", cols)$error, "Unknown column: zzz")
})

test_that("eval_metric turns division by zero into NA", {
  df <- data.frame(a = c(1, 0, 4), b = c(2, 0, 0))
  expect_equal(eval_metric("a / b", df), c(0.5, NA, NA))
})

test_that("score_players ranks qualified players and flips lower-is-better", {
  df <- data.frame(
    player_id = c("p1", "p2", "p3", "p4"), pos_group = "QB",
    games = c(10, 10, 10, 1), yds = c(300, 200, 100, 999), ints = c(1, 5, 9, 0)
  )
  model <- normalize_model(list(positions = list(QB = list(
    qualify = list(min_games = 4, volume = "games", min_volume = 0),
    metrics = list(
      list(key = "y", label = "Y", expr = "yds", higher_is_better = TRUE, weight = 1),
      list(key = "i", label = "I", expr = "ints", higher_is_better = FALSE, weight = 1)
    )
  ))))
  s <- score_players(df, model)$scores
  expect_equal(s$pos_rank, c(1L, 2L, 3L, NA))
  expect_equal(s$qualified, c(TRUE, TRUE, TRUE, FALSE))
  expect_equal(s$score[1], 100 * (5 / 6))
  expect_equal(s$score[4], 100)  # NQ player still scored against the qualified pool
})

test_that("save_model sanitizes names and round-trips", {
  root <- tempfile(); dir.create(file.path(root, "config"), recursive = TRUE)
  m <- normalize_model(list(positions = list(K = list(
    qualify = list(min_games = 1, volume = "games", min_volume = 0),
    metrics = list(list(key = "x", label = "X", expr = "fg_made", weight = 3))
  ))))
  p <- save_model(m, root, "My model / v2")
  expect_equal(basename(p), "My_model_v2.yaml")
  expect_equal(read_model(p)$positions$K$metrics[[1]]$weight, 3)
  expect_error(safe_model_filename("../.."))
})
