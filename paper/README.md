# Final WireGuard article

This directory contains the ACM-style source for the final research article.
The repository's `report/` directory is a historical internship report and is
unrelated to this final article.

## Local build

The preferred build uses `latexmk`:

```sh
make
```

This runs:

```sh
latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex
```

When `latexmk` is unavailable, the Makefile can use `tectonic`. The conventional
`pdflatex`/`bibtex` sequence remains the portable fallback below.

If `latexmk` is unavailable, run the following commands from `paper/`:

```sh
pdflatex -interaction=nonstopmode -halt-on-error main.tex
bibtex main
pdflatex -interaction=nonstopmode -halt-on-error main.tex
pdflatex -interaction=nonstopmode -halt-on-error main.tex
```

No shell escape is required. Use `make clean` to remove normal auxiliary files,
or `make distclean` to remove auxiliary files and `main.pdf`.

## Overleaf

Upload or import the contents of `paper/` as one Overleaf project and select
`main.tex` as the main document. The project uses the standard `acmart` class
and does not require `minted` or shell escape.

## Generated figures

Vector figures under `figures/generated/` are produced from committed
experimental evidence. After the technical plotting scripts are added, run:

```sh
make figures
```

The scripts and the exact raw-data provenance are documented in
`../docs/paper/FIGURE_DATA_SOURCES.md`.
