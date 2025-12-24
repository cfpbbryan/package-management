#!/usr/bin/env Rscript
# Install R packages from a local Windows mirror into the primary library.
#
# Usage (from the project root):
#
#   Rscript r-install-baseline.R
#
# The script expects packages listed one per line in ``r_requirements.txt`` and
# mirrored Windows binaries under ``C:/admin/r_mirror``. It installs the
# binaries into the first entry of ``.libPaths()`` after ensuring the current
# process has permission to write to that library.

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
default_mirror <- normalizePath("C:/admin/r_mirror", winslash = "\\", mustWork = FALSE)

default_library <- function() {
  lib <- .libPaths()[1]

  if (!dir.exists(lib)) {
    dir.create(lib, recursive = TRUE, showWarnings = FALSE)
  }

  if (file.access(lib, 2) != 0) {
    stop(
      sprintf(
        "Library path %s is not writable. Run from an elevated R session or update .libPaths() to a writable location.",
        lib
      )
    )
  }

  lib
}

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

resolve_local_repo <- function(path) {
  if (!dir.exists(path)) {
    stop(
      sprintf("Local mirror not found at %s. Run r-build-mirror.R first to populate the mirror.", path)
    )
  }

  paste0("file:///", normalizePath(path, winslash = "/", mustWork = TRUE))
}

install_baseline <- function(requirements_path, mirror_path) {
  ensure_windows()
  packages <- read_requirements(requirements_path)

  base_packages <- rownames(installed.packages(priority = c("base", "recommended")))
  requested <- packages
  packages <- setdiff(packages, base_packages)

  if (!length(packages)) {
    message(sprintf(
      "No packages to install after excluding base/recommended packages from %s.",
      requirements_path
    ))
    return(invisible(NULL))
  }

  skipped <- setdiff(requested, packages)

  if (length(skipped)) {
    message(sprintf(
      "Skipping %d base/recommended package(s): %s",
      length(skipped),
      paste(skipped, collapse = ", ")
    ))
  }

  repo <- resolve_local_repo(mirror_path)
  library_path <- default_library()

  install.packages(
    pkgs = packages,
    repos = repo,
    type = "win.binary",
    lib = library_path,
    dependencies = TRUE
  )
}

install_baseline(default_requirements, default_mirror)
