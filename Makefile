.PHONY: all build release publish docker-push update-version

VERSION ?= $(shell cat VERSION)
MAJOR ?= $(shell cat VERSION | cut -d. -f1)
IMAGE ?= asoluter/postgresql

all: build

build:
	@docker build --tag=$(IMAGE):latest --tag=$(IMAGE):$(MAJOR) .

release:
	@docker build --tag=$(IMAGE):$(VERSION) --tag=$(IMAGE):$(MAJOR) --tag=$(IMAGE):latest .

publish: release
	@docker push $(IMAGE):$(VERSION)
	@docker push $(IMAGE):$(MAJOR)
	@docker push $(IMAGE):latest

docker-push: publish

update-version:
	@./scripts/update-version.sh
