#!/usr/bin/env Rscript
# Prepare a local mirror of R package binaries for Windows systems.
#
# Usage (from the project root):
#
#   Rscript r-build-mirror.R
#
# The script reads package names from ``r_requirements.txt`` (one package per
# line, comments starting with ``#`` are ignored) and downloads the Windows
# binary builds into ``C:/admin/r_mirror``. Only package names are required;
# versions are resolved automatically by CRAN.

get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- "--file="
  file_args <- args[grepl(paste0("^", file_arg), args)]

  if (!length(file_args)) {
    return(normalizePath(getwd(), winslash = "\\", mustWork = TRUE))
  }

  normalizePath(dirname(sub(file_arg, "", file_args[1])), winslash = "\\", mustWork = TRUE)
}

default_requirements <- file.path(get_script_dir(), "r_requirements.txt")
default_destination <- normalizePath("C:/admin/r_mirror", winslash = "\\", mustWork = FALSE)

ensure_windows <- function() {
  if (!identical(tolower(Sys.info()[["sysname"]]), "windows")) {
    stop("This script is intended to run on Windows hosts only.")
  }
}

read_requirements <- function(path) {
  if (!file.exists(path)) {
    stop(sprintf("Missing requirements file at: %s", path))
  }

  entries <- readLines(path, warn = FALSE)
  entries <- trimws(entries)
  entries <- entries[entries != "" & !grepl("^#", entries)]
  unique(entries)
}

prepare_repos <- function() {
  options(repos = c(CRAN = "https://cloud.r-project.org"))
}

mirror_packages <- function(requirements_path, destination) {
  ensure_windows()
  packages <- read_requirements(requirements_path)

  if (!length(packages)) {
    message(sprintf("No packages listed in %s; nothing to mirror.", requirements_path))
    return(invisible(NULL))
  }

  prepare_repos()

  r_version <- paste(R.version$major, sub("\\..*$", "", R.version$minor), sep = ".")
  mirror_dir <- file.path(destination, "bin", "windows", "contrib", r_version)

  if (!dir.exists(mirror_dir)) {
    dir.create(mirror_dir, recursive = TRUE, showWarnings = FALSE)
  }

  download.packages(pkgs = packages, destdir = mirror_dir, type = "win.binary")
  tools::write_PACKAGES(dir = mirror_dir, type = "win.binary")
}

mirror_packages(default_requirements, default_destination)
