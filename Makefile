# butschster/windows — initialize, verify, and publish a standalone Kickside module.
MODULE := windows
TYPE   := plugin
VIS    := private

# pipefail lets the test targets both stream runner output and keep its exit
# code while grepping the log afterwards.
SHELL := bash
.SHELLFLAGS := -o pipefail -ec

.PHONY: init setup check lint late-locals test test-pg postgres-up postgres-down verify release-check publish
init:
	node scripts/init-module.mjs --organization "$(ORG)" --module "$(MODULE_NAME)" --title "$(TITLE)" $(if $(NAMESPACE),--namespace "$(NAMESPACE)",) $(if $(TAG),--tag "$(TAG)",) $(if $(GITHUB_OWNER),--github-owner "$(GITHUB_OWNER)",)
setup:
	$(WIPPY) update
	cd test && $(WIPPY) update
check:
	node scripts/check-module.mjs
	node scripts/test-initializer.mjs
# Поздние `local` — объявленные ниже того места, где их читают. Выше
# объявления локальная читается как ГЛОБАЛЬНАЯ, то есть как nil, и отказа при
# этом не происходит: функция не вызывается, надпись не рисуется, право не
# проверяется. За одну ночь этот класс укусил пять раз, и ни разу не дал
# ошибки — все пять нашлись живым запуском или снимком.
#
# Стоит ПЕРЕД `wippy lint`, потому что дешевле и потому что `wippy lint` этого
# не ловит вовсе.
lint:
	python3 tools/late-locals.py src
	python3 tools/late-locals.py test
	$(WIPPY) lint
# The runner exits 0 when it discovers zero tests, which turns a broken
# discovery setup into a false-green run. An empty discovery is always a
# defect here — the template ships suites — so both targets fail on it.
# Модуль объявляет собственный terminal.host — ему нужен hide_logs, — и с
# этого момента автодетект терминального хоста в CLI отказывается выбирать:
# он просто считает записи kind terminal.host, а их теперь две. Набор идёт на
# обычном хосте приложения; свой нужен только десктопу.
# Чем запускать. Модуль объявляет записи с модулем `gfx`, а его нет в
# релизном рантайме: `wippy` из PATH (0.3.40a) не грузит модуль ВОВСЕ и
# сообщает об этом как «node with ID … not found» — по такому сообщению
# причину не угадать. Поэтому здесь локальная сборка, и переопределяется она
# одной переменной:
#
#   make test WIPPY=wippy
WIPPY ?= /home/butschster/repos/wippy/runtime/dist/wippy-linux-amd64

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
release-check: verify
	$(WIPPY) auth status
	$(WIPPY) publish --dry-run --create --module-visibility $(VIS) --module-type $(TYPE)
publish:
	node scripts/check-module.mjs
	$(WIPPY) auth status
	$(WIPPY) publish --create --module-visibility $(VIS) --module-type $(TYPE)
