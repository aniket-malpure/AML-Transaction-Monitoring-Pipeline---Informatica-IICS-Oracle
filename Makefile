# AML Transaction Monitoring Pipeline - common tasks
SHELL := /bin/bash
PY    ?= python3
DATE  ?= $(shell date -d yesterday +%Y%m%d)
ISO_DATE = $(shell date -d $(DATE) +%Y-%m-%d)

.PHONY: help data convert test db-up db-install db-test run-local run-iics clean

help:            ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

data:            ## generate 2M synthetic transactions for DATE (default yesterday)
	$(PY) data_generator/generate_transactions.py --accounts 50000 --transactions 2000000 \
	  --days 30 --run-date $(ISO_DATE) --out data/inbound

convert:         ## PowerCenter XML -> IICS mapping/task/taskflow specs + report
	$(PY) tools/pc_to_iics/convert_pc_to_iics.py

test:            ## Python + shell tests (no database needed)
	$(PY) -m pytest -q

db-up:           ## start Oracle 23ai Free in Docker
	docker compose up -d
	@echo "Waiting for Oracle..."; until docker inspect -f '{{.State.Health.Status}}' aml-oracle | grep -q healthy; do sleep 10; done; echo ready

db-install:      ## create AML_OWNER, install objects, run PL/SQL unit test
	scripts/setup_db.sh

db-test:         ## PL/SQL unit test only
	source scripts/lib/common.sh && run_sql "@sql/tests/test_aml_rules.sql"

run-local:       ## full nightly chain with SQL*Loader (no IICS)
	scripts/run_aml_batch.sh -d $(DATE) -m LOCAL

run-iics:        ## full nightly chain through IICS mapping tasks
	scripts/run_aml_batch.sh -d $(DATE) -m IICS

clean:           ## remove generated data, logs and run state
	find data -type f ! -name .gitkeep -delete; rm -rf logs run
