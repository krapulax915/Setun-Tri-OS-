# Setun Tri OS — thin wrapper; the real driver is tools/mk.py (D-025).
PY ?= python

.PHONY: test run assemble image profile isa-doc clean

test:
	$(PY) tools/mk.py test

run:
	$(PY) tools/mk.py run

assemble:
	$(PY) tools/mk.py assemble

image:
	$(PY) tools/mk.py image

profile:
	$(PY) tools/mk.py profile WORKLOAD=$(WORKLOAD)

isa-doc:
	$(PY) tools/mk.py isa-doc

clean:
	$(PY) tools/mk.py clean
