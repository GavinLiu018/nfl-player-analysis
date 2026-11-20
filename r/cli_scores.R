# Usage: Rscript r/cli_scores.R [model.yaml] [from_week to_week]
# Writes data/out/scores_r.csv and data/out/breakdown_r.csv for the R/Python parity check.
args <- commandArgs(trailingOnly = TRUE)
script_dir <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])))
for (f in list.files(file.path(script_dir, "R"), pattern = "[.]R$", full.names = TRUE)) source(f)

root <- project_root(script_dir)
data <- load_data(root)
model <- read_model(if (length(args) >= 1 && nzchar(args[1])) args[1] else default_model_path(root))
weeks <- if (length(args) >= 3) as.integer(args[2:3]) else NULL
frame <- player_frame(data, weeks)
res <- score_players(frame, model)
out <- file.path(root, "data", "out")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
s <- res$scores[order(res$scores$pos_group, res$scores$player_id), ]
b <- res$breakdown[order(res$breakdown$pos_group, res$breakdown$player_id, res$breakdown$key), ]
utils::write.csv(s, file.path(out, "scores_r.csv"), row.names = FALSE, na = "")
utils::write.csv(b, file.path(out, "breakdown_r.csv"), row.names = FALSE, na = "")
cat(sprintf("Season %s through week %s (fetched %s): scored %d players, %d qualified -> %s\n",
            data$meta$season, data$meta$latest_week, data$meta$fetched_at,
            nrow(s), sum(s$qualified), file.path(out, "scores_r.csv")))
