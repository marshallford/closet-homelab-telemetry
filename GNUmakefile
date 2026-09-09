.PHONY: default
default: lint

.DELETE_ON_ERROR:

DOCKER_FLAGS += --rm
ifeq ($(shell tty > /dev/null && echo 1 || echo 0), 1)
DOCKER_FLAGS += -i
endif

DOCKER ?= docker
COMPOSE ?= $(DOCKER) compose
DOCKER_MOUNT_FLAGS := ro,z
DOCKER_RUN := $(DOCKER) run $(DOCKER_FLAGS)
DOCKER_PULL := $(DOCKER) pull -q

EDITORCONFIG_CHECKER_VERSION ?= 3.11.1
EDITORCONFIG_CHECKER_IMAGE ?= docker.io/mstruebing/editorconfig-checker:v$(EDITORCONFIG_CHECKER_VERSION)
EDITORCONFIG_CHECKER := $(DOCKER_RUN) -v=$(CURDIR):/check:$(DOCKER_MOUNT_FLAGS) $(EDITORCONFIG_CHECKER_IMAGE)

YAMLLINT_VERSION ?= 0.35.13
YAMLLINT_IMAGE ?= docker.io/pipelinecomponents/yamllint:$(YAMLLINT_VERSION)
YAMLLINT := $(DOCKER_RUN) -v=$(CURDIR):/code:$(DOCKER_MOUNT_FLAGS) $(YAMLLINT_IMAGE) yamllint

SHELLCHECK_VERSION ?= 0.11.0
SHELLCHECK_IMAGE ?= docker.io/koalaman/shellcheck:v$(SHELLCHECK_VERSION)
SHELLCHECK := $(DOCKER_RUN) -v=$(CURDIR):/mnt:$(DOCKER_MOUNT_FLAGS) $(SHELLCHECK_IMAGE)

TANKA_VERSION ?= 0.38.0
TANKA_IMAGE ?= docker.io/grafana/tanka:$(TANKA_VERSION)
TANKA_RUN := $(DOCKER_RUN) -u=$(shell id -u):$(shell id -g) -v=$(CURDIR)/dashboards:/w:z -w=/w
JB := $(TANKA_RUN) --entrypoint=jb $(TANKA_IMAGE)
TK := $(TANKA_RUN) --entrypoint=tk $(TANKA_IMAGE)

DASHBOARD_SRC := $(wildcard dashboards/*.jsonnet)
DASHBOARD_LIB := $(wildcard dashboards/*.libsonnet)
DASHBOARD_JSON := $(patsubst dashboards/%.jsonnet,dashboards/rendered/%.json,$(DASHBOARD_SRC))


.PHONY: pull pull/editorconfig pull/yamllint pull/shellcheck pull/tanka
pull: pull/editorconfig pull/yamllint pull/shellcheck pull/tanka

pull/editorconfig:
	$(DOCKER_PULL) $(EDITORCONFIG_CHECKER_IMAGE)

pull/yamllint:
	$(DOCKER_PULL) $(YAMLLINT_IMAGE)

pull/shellcheck:
	$(DOCKER_PULL) $(SHELLCHECK_IMAGE)

pull/tanka:
	$(DOCKER_PULL) $(TANKA_IMAGE)

.PHONY: lint lint/editorconfig lint/yamllint lint/shell lint/jsonnet
lint: lint/editorconfig lint/yamllint lint/shell lint/jsonnet

lint/editorconfig:
	$(EDITORCONFIG_CHECKER)

lint/yamllint:
	$(YAMLLINT) .

lint/shell:
	$(SHELLCHECK) scripts/*.sh

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
