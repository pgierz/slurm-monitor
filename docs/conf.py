# Sphinx configuration.

project = "slurm-monitor"
copyright = "2025, AWI HPC Team"
author = "AWI HPC Team"
release = "0.5.0"

extensions = [
    "myst_parser",
]

myst_enable_extensions = [
    "colon_fence",
    "deflist",
    "linkify",
    "tasklist",
]

source_suffix = {
    ".rst": "restructuredtext",
    ".md": "markdown",
}

templates_path = ["_templates"]
exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]

html_theme = "pydata_sphinx_theme"
html_static_path = ["_static"]
