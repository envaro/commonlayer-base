# CommonLayer project Makefile.
#
# Identical in the project template and every CommonLayer project (the
# template's drift check verifies this). All logic lives in scripts/, so the same
# commands run locally and in CI.
#
#   make validate build test scan sbom chart-test
#
# Useful variables (environment): CL_PLATFORM (default: this machine),
# CL_VERSIONS (limit version lines, e.g. "1.30"), CL_REVISION (default 0),
# CL_IMAGE_PREFIX (default localhost/commonlayer), CL_EXTRA_CA_FILE.
.POSIX:
SHELL = /bin/sh

.PHONY: help all validate build test scan sbom licenses chart-test chart-test-kind tools clean

help:
	@echo "targets: validate build test scan sbom licenses chart-test chart-test-kind tools clean all"

all: validate build test scan sbom chart-test

validate:
	@scripts/validate.sh

build:
	@scripts/build.sh

test:
	@scripts/test.sh

scan:
	@scripts/scan.sh

sbom:
	@scripts/generate-sbom.sh

licenses:
	@scripts/generate-license-inventory.sh

chart-test:
	@scripts/test-chart.sh

chart-test-kind:
	@scripts/test-chart-kind.sh

tools:
	@scripts/install-tools.sh

clean:
	rm -rf .build
