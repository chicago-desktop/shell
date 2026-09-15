# chicago/shell — initialize, verify, and publish a standalone Kickside module.
MODULE := shell
TYPE   := plugin
VIS    := public

# pipefail lets the test targets both stream runner output and keep its exit
# code while grepping the log afterwards.
SHELL := bash
.SHELLFLAGS := -o pipefail -ec

.PHONY: init setup check lint late-locals test test-pg postgres-up postgres-down verify release-check publish probes check-probes shots
init:
	node scripts/init-module.mjs --organization "$(ORG)" --module "$(MODULE_NAME)" --title "$(TITLE)" $(if $(NAMESPACE),--namespace "$(NAMESPACE)",) $(if $(TAG),--tag "$(TAG)",) $(if $(GITHUB_OWNER),--github-owner "$(GITHUB_OWNER)",)
setup:
	$(WIPPY) update
	cd test && $(WIPPY) update
check:
	node scripts/check-module.mjs
	node scripts/test-initializer.mjs
# Late `local`s — declared below the place where they are read. Above its
# declaration a local is read as a GLOBAL, that is as nil, and no failure
# happens: a function is not called, a label is not drawn, a permission is not
# checked. In one night this class bit five times and not once produced an
# error — all five were found by a live run or a snapshot.
#
# It runs BEFORE `wippy lint`, because it is cheaper and because `wippy lint`
# does not catch this at all.
lint:
	python3 tools/late-locals.py src
	python3 tools/late-locals.py test
	$(WIPPY) lint
# The runner exits 0 when it discovers zero tests, which turns a broken
# discovery setup into a false-green run. An empty discovery is always a
# defect here — the template ships suites — so both targets fail on it.
# The module declares its own terminal.host — it needs hide_logs — and from
# that moment the CLI's terminal host autodetection refuses to choose: it simply
# counts entries of kind terminal.host, and now there are two. The suite runs on
# the application's ordinary host; only the desktop needs its own.
# What to run with. The module declares entries with the `gfx` module, and the
# release runtime does not have it: `wippy` from PATH (0.3.40a) does not load
# the module AT ALL and reports it as "node with ID … not found" — the cause
# cannot be guessed from such a message. Hence the local build here, and it is
# overridden with a single variable:
#
#   make test WIPPY=wippy
WIPPY ?= $(CURDIR)/../runtime/dist/wippy-linux-amd64

TEST_HOST := wippy.terminal:host
test:
	cd test && $(WIPPY) test --host $(TEST_HOST) 2>&1 | tee .wippy/last-test-run.log && ! grep -q "No tests found" .wippy/last-test-run.log
test-pg:
	cd test && $(WIPPY) test --host $(TEST_HOST) --profile postgres 2>&1 | tee .wippy/last-test-run.log && ! grep -q "No tests found" .wippy/last-test-run.log
postgres-up:
	docker compose -f compose.test.yaml up -d --wait
postgres-down:
	docker compose -f compose.test.yaml down -v
verify: setup check lint test
# The probes (tools/pixelprobe, tools/themeprobe) run the REAL theme files
# outside the runtime, glued into combined.lua by build.py. combined.lua is not
# stored in git, so a probe run days after the last build checks old code and
# does not say so. `probes` rebuilds both; `check-probes` builds in memory and
# fails when a combined.lua on disk differs — older than the harness or any
# source it embeds. Neither is part of lint or verify: the probes are a tool,
# not a gate. `check-probes` also RUNS each probe once on its fresh
# combined.lua — building the Go binary first when it is missing or older
# than its main.go or go.mod — and fails on a non-zero exit, showing the tail
# of the run. From 2026-09-08 to 2026-09-11 both probes built fine and
# crashed on their first `require`, and `--check` alone could not say so.
probes:
	python3 tools/pixelprobe/build.py
	python3 tools/themeprobe/build.py
PROBES := pixelprobe themeprobe
check-probes:
	python3 tools/pixelprobe/build.py --check
	python3 tools/themeprobe/build.py --check
	@for probe in $(PROBES); do \
		dir=tools/$$probe; \
		if [ ! -x $$dir/$$probe ] || [ $$dir/main.go -nt $$dir/$$probe ] || [ $$dir/go.mod -nt $$dir/$$probe ]; then \
			echo "building $$dir/$$probe"; (cd $$dir && go build -o $$probe .) || exit 1; \
		fi; \
		if (cd $$dir && ./$$probe combined.lua > last-run.log 2>&1); then \
			echo "$$probe ran: $$(tail -n 1 $$dir/last-run.log)"; \
		else \
			echo "$$probe FAILED, tail of $$dir/last-run.log:"; tail -n 20 $$dir/last-run.log; exit 1; \
		fi; \
	done
# PNG snapshots of the shell and the windows into test/shots. This is a
# `wippy run` — it brings the application up — so a person runs it; lint and
# test never do. The snapshots are evidence for the eye: no test compares them.
# Without a cell size paint-png takes a fallback and says so in its report:
#   make shots CELL=10x20
CELL ?=
shots:
	cd test && $(WIPPY) run --host wippy.terminal:host paint-png $(CELL)
release-check: verify
	$(WIPPY) auth status
	$(WIPPY) publish --dry-run --create --module-visibility $(VIS) --module-type $(TYPE)
publish:
	node scripts/check-module.mjs
	$(WIPPY) auth status
	$(WIPPY) publish --create --module-visibility $(VIS) --module-type $(TYPE)
