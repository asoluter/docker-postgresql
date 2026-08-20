VERSION ?= $(shell cat VERSION)
MAJOR ?= $(shell cat VERSION | cut -d. -f1)
IMAGE ?= asoluter/postgresql

all: build

build:
	@docker build --tag=$(IMAGE):latest --tag=$(IMAGE):$(MAJOR) .

release: build
	@docker build --tag=$(IMAGE):$(VERSION) --tag=$(IMAGE):$(MAJOR) --tag=$(IMAGE):latest .

update-version:
	@./scripts/update-version.sh
