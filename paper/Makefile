LATEXMK ?= latexmk
LATEXMKFLAGS ?= -pdf -interaction=nonstopmode -halt-on-error
TECTONIC ?= tectonic
PDFLATEX ?= pdflatex
BIBTEX ?= bibtex

.PHONY: all figures clean distclean

all: main.pdf

main.pdf: main.tex abstract.tex 02-introduction.tex \
	03-background-motivations.tex 04-contributions.tex 05-evaluation.tex \
	06-related.tex 07-conclusion.tex reference.bib
	@if command -v $(LATEXMK) >/dev/null 2>&1; then \
		$(LATEXMK) $(LATEXMKFLAGS) main.tex; \
	elif command -v $(TECTONIC) >/dev/null 2>&1; then \
		$(TECTONIC) main.tex; \
	elif command -v $(PDFLATEX) >/dev/null 2>&1 && \
	     command -v $(BIBTEX) >/dev/null 2>&1; then \
		$(PDFLATEX) -interaction=nonstopmode -halt-on-error main.tex && \
		$(BIBTEX) main && \
		$(PDFLATEX) -interaction=nonstopmode -halt-on-error main.tex && \
		$(PDFLATEX) -interaction=nonstopmode -halt-on-error main.tex; \
	else \
		echo "No supported TeX toolchain found (latexmk, tectonic, or pdflatex+bibtex)."; \
		exit 1; \
	fi

figures:
	@if [ -f ../scripts/paper/make_figures.py ]; then \
		python3 ../scripts/paper/make_figures.py --all; \
	else \
		echo "Figure generator not present yet; scaffold contains no generated figures."; \
	fi

clean:
	@if command -v $(LATEXMK) >/dev/null 2>&1; then \
		$(LATEXMK) -c main.tex; \
	else \
		$(RM) main.aux main.bbl main.bcf main.blg main.fdb_latexmk \
			main.fls main.log main.out main.run.xml main.toc; \
	fi

distclean:
	@$(MAKE) clean
	$(RM) main.pdf
