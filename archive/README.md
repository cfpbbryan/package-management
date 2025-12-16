# Archive scripts

Legacy and experimental helpers remain available in this directory. They are kept for reference and can be used when maintaining older workflows.

| Script / File Name           | What it does                                                           |
| ---------------------------- | ---------------------------------------------------------------------- |
| build-python-mirror.py       | Builds a Windows-oriented pip download mirror using `python_requirements.txt`. |
| find-new-python-packages.py  | Compares a `new.txt` list against `python_requirements.txt` and appends missing packages with latest versions. |
| freeze-python-packages.py    | Runs `py -m pip freeze` and writes the results to `python_requirements.txt` in the project root. |
| install-python-baseline.py   | Installs packages from `python_requirements.txt` into the system environment using the local mirror. |
| pip-cleanup-versions.ps1     | PowerShell cleaner that removes older or duplicate pip package versions from `C:\\admin\\pip_mirror`. |
| pip-cleanup-versions.py      | Python implementation that prunes older wheel and source distributions in `C:/admin/pip_mirror`. |
| print-python-csv.ps1         | Emits a tab-separated inventory of installed Python packages based on `python_requirements.txt`. |
| stata-print-csv.py           | Generates a tab-separated report of installed Stata packages from the shared ado tree. |
