# Builds and tests cl-probe. Used inside the base image build stage and locally.
# SPDX-License-Identifier: Apache-2.0
CC      ?= cc
CFLAGS  ?= -O2
HARDEN  := -std=c11 -Wall -Wextra -Werror -Wformat -Werror=format-security \
           -fstack-protector-strong -fstack-clash-protection -D_FORTIFY_SOURCE=2 -fPIE
LDHARD  := -static-pie -Wl,-z,relro,-z,now
OUT     ?= .

.PHONY: all test clean
all: $(OUT)/cl-probe

$(OUT)/cl-probe: main.c cl_probe.c cl_probe.h
	$(CC) $(CFLAGS) $(HARDEN) -o $@ main.c cl_probe.c $(LDHARD)
	strip $@

$(OUT)/test_cl_probe: test_cl_probe.c cl_probe.c cl_probe.h
	$(CC) $(CFLAGS) $(HARDEN) -o $@ test_cl_probe.c cl_probe.c $(LDHARD)

test: $(OUT)/test_cl_probe $(OUT)/cl-probe
	$(OUT)/test_cl_probe $(OUT)/cl-probe

clean:
	rm -f $(OUT)/cl-probe $(OUT)/test_cl_probe
