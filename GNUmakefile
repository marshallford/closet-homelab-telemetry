.PHONY: default
default: lint

.DELETE_ON_ERROR:

CONTAINER_FLAGS += --rm
ifeq ($(shell tty > /dev/null && echo 1 || echo 0), 1)
CONTAINER_FLAGS += -i
endif

CONTAINER_RUNTIME ?= docker
COMPOSE ?= $(CONTAINER_RUNTIME) compose
CONTAINER_MOUNT_FLAGS := ro,z
CONTAINER_RUN := $(CONTAINER_RUNTIME) run $(CONTAINER_FLAGS)
CONTAINER_PULL := $(CONTAINER_RUNTIME) pull -q

EDITORCONFIG_CHECKER_VERSION ?= 3.11.1
EDITORCONFIG_CHECKER_IMAGE ?= docker.io/mstruebing/editorconfig-checker:v$(EDITORCONFIG_CHECKER_VERSION)
EDITORCONFIG_CHECKER := $(CONTAINER_RUN) -v=$(CURDIR):/check:$(CONTAINER_MOUNT_FLAGS) $(EDITORCONFIG_CHECKER_IMAGE)

YAMLLINT_VERSION ?= 0.35.13
YAMLLINT_IMAGE ?= docker.io/pipelinecomponents/yamllint:$(YAMLLINT_VERSION)
YAMLLINT := $(CONTAINER_RUN) -v=$(CURDIR):/code:$(CONTAINER_MOUNT_FLAGS) $(YAMLLINT_IMAGE) yamllint

SHELLCHECK_VERSION ?= 0.11.0
SHELLCHECK_IMAGE ?= docker.io/koalaman/shellcheck:v$(SHELLCHECK_VERSION)
SHELLCHECK := $(CONTAINER_RUN) -v=$(CURDIR):/mnt:$(CONTAINER_MOUNT_FLAGS) $(SHELLCHECK_IMAGE)

OTELCOL_VERSION ?= 0.159.0
OTELCOL_IMAGE ?= docker.io/otel/opentelemetry-collector-contrib:$(OTELCOL_VERSION)
OTELCOL_ENV := -e=COLLECTOR_ENDPOINT=localhost:4317 -e=NODE_HOST=node -e=NODE_MACHINE_ID=0
OTELCOL := $(CONTAINER_RUN) $(OTELCOL_ENV) -v=$(CURDIR):/mnt:$(CONTAINER_MOUNT_FLAGS) $(OTELCOL_IMAGE)

TANKA_VERSION ?= 0.38.0
TANKA_IMAGE ?= docker.io/grafana/tanka:$(TANKA_VERSION)
TANKA_RUN := $(CONTAINER_RUN) -u=$(shell id -u):$(shell id -g) -v=$(CURDIR)/dashboards:/w:z -w=/w
JB := $(TANKA_RUN) --entrypoint=jb $(TANKA_IMAGE)
TK := $(TANKA_RUN) --entrypoint=tk $(TANKA_IMAGE)

OTELCOL_CONFIG := $(wildcard config/*/otel-collector.yaml)
OTELCOL_LINT := $(patsubst config/%/otel-collector.yaml,lint/otelcol/%,$(OTELCOL_CONFIG))

DASHBOARD_SRC := $(wildcard dashboards/*.jsonnet)
DASHBOARD_LIB := $(wildcard dashboards/*.libsonnet)
DASHBOARD_JSON := $(patsubst dashboards/%.jsonnet,dashboards/rendered/%.json,$(DASHBOARD_SRC))


.PHONY: pull pull/editorconfig pull/yamllint pull/shellcheck pull/otelcol pull/tanka
pull: pull/editorconfig pull/yamllint pull/shellcheck pull/otelcol pull/tanka

pull/editorconfig:
	$(CONTAINER_PULL) $(EDITORCONFIG_CHECKER_IMAGE)

pull/yamllint:
	$(CONTAINER_PULL) $(YAMLLINT_IMAGE)

pull/shellcheck:
	$(CONTAINER_PULL) $(SHELLCHECK_IMAGE)

pull/otelcol:
	$(CONTAINER_PULL) $(OTELCOL_IMAGE)

pull/tanka:
	$(CONTAINER_PULL) $(TANKA_IMAGE)

.PHONY: lint lint/editorconfig lint/yamllint lint/shell lint/otelcol $(OTELCOL_LINT) lint/jsonnet
lint: lint/editorconfig lint/yamllint lint/shell lint/otelcol lint/jsonnet

lint/editorconfig:
	$(EDITORCONFIG_CHECKER)

lint/yamllint:
	$(YAMLLINT) .

lint/shell:
	$(SHELLCHECK) scripts/*.sh

lint/otelcol: $(OTELCOL_LINT)

$(OTELCOL_LINT): lint/otelcol/%:
	$(OTELCOL) validate --config=/mnt/config/$*/otel-collector.yaml

lint/jsonnet:
	$(TK) lint $(notdir $(DASHBOARD_SRC))

.PHONY: fmt fmt/jsonnet
fmt: fmt/jsonnet

fmt/jsonnet:
	$(TK) fmt $(notdir $(DASHBOARD_SRC))

dashboards/vendor: dashboards/jsonnetfile.lock.json
	$(JB) install
	@touch $@

.PHONY: dashboards
dashboards: $(DASHBOARD_JSON)

dashboards/rendered:
	mkdir -p $@

dashboards/rendered/%.json: dashboards/%.jsonnet $(DASHBOARD_LIB) dashboards/vendor | dashboards/rendered
	$(TK) eval $(notdir $<) > $@

.PHONY: screenshots
screenshots: dashboards
	@scripts/$@.sh

.PHONY: compare
compare:
	@scripts/$@.sh

.PHONY: annotate unannotate
annotate:
	@scripts/$@.sh

unannotate:
	@scripts/$@.sh

.PHONY: up down purge
up: dashboards
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

purge:
	$(COMPOSE) down --volumes
