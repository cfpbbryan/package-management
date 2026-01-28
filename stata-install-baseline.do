/***************************************************************************************************
 * Install Stata packages directly into the managed shared ado tree using requirement metadata.
 *
 * The script reads `stata_requirements.txt` in this repository (a CSV with headers `packagename,url`),
 * sets the ado install directory to the shared ado location (no PLUS subfolder), ensures per-letter
 * package folders exist, and installs each package from its upstream source with `replace` enabled so
 * repeated runs are idempotent. Verbose messaging highlights configuration and per-package results.
 *
 * Usage (from the project root on Windows):
 *   - Right-click this file and choose "Do" in Stata, or run via Stata's batch CLI if available.
 *
 * Requirements:
 *   - Windows host.
 *   - `stata_requirements.txt` saved in this repository's root with headers `packagename,url`.
 *   - Shared ado directory at `C:\\Program Files\\Stata18\\shared_ado` (created if missing).
 ***************************************************************************************************/

version 17.0

local requirements "`c(pwd)'\stata_requirements.txt"
local shared_root "C:\\Program Files\\Stata18\\shared_ado"

if (lower(c(os)) != "windows") {
    display as error "Windows only."
    exit 9
}

capture confirm file "`requirements'"
if (_rc) {
    display as error "Missing requirements file: `requirements'"
    exit 601
}

// Ensure the shared ado directory exists and is used for installs (no PLUS folder).
cap mkdir "`shared_root'"
adopath ++ "`shared_root'"
net set ado "`shared_root'"

// Show configuration for easier troubleshooting.
display as text "Installing from: `requirements'"
display as text "Shared ado target: `shared_root'"

display as text "Reading requirements..."
import delimited using "`requirements'", clear stringcols(_all) varnames(1)

rename packagename pkg

if (_N == 0) {
    display "Nothing to install."
    exit 0
}

display as text "Found `_N' packages to process."

set more off

local failures 0
local failed_list ""

forvalues i = 1/`=_N' {
    local p = trim(pkg[`i'])
    local src = trim(url[`i'])

    if ("`p'" == "" | "`src'" == "") {
        display as result "Skipping row `i' (missing package or URL)."
        continue
    }

    local first = substr(lower("`p'"), 1, 1)
    if (!regexm("`first'", "[a-z]")) {
        local first "_"
    }

    cap mkdir "`shared_root'\\`first'"

    display as text "[`i'/`=_N'] Installing `p' from `src' into `shared_root'\\`first'"

    // Use ssc install for SSC packages (Boston College RePEc archive), net install otherwise.
    if (strpos("`src'", "fmwww.bc.edu/RePEc/bocode") > 0) {
        display as text "    (using ssc install)"
        quietly cap ssc install `p', replace
    }
    else {
        quietly cap net install `p', from(`"`src'"') replace
    }
    local rc = _rc

    if (`rc') {
        display as error "    Failed: `p' (_rc = `rc')"
        local failures = `failures' + 1
        local failed_list = trim("`failed_list' `p'(_rc=`rc')")
        continue
    }

    display as result "    Success: `p' installed."
}

if (`failures') {
    display as error "Completed with `failures' failure(s): `failed_list'"
    exit 498
}

display as result "All packages installed successfully."
exit 0
