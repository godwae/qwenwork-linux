SHELL := /bin/bash

.PHONY: help deps build-app run-app deb rpm pacman package install check-update clean check

help:
	@echo "Targets:"
	@echo "  make deps"
	@echo "  make build-app"
	@echo "  make build-app DMG=/path/to/QwenWorkCN.dmg"
	@echo "  make run-app"
	@echo "  make deb"
	@echo "  make rpm"
	@echo "  make pacman"
	@echo "  make package"
	@echo "  make install"
	@echo "  make check-update"
	@echo "  make check"
	@echo "  make clean"

deps:
	bash scripts/install-deps.sh

build-app:
	@if [ -n "$(DMG)" ]; then bash install.sh "$(DMG)"; else bash install.sh; fi

run-app:
	bash qwenwork-app/start.sh

deb:
	bash scripts/build-deb.sh

rpm:
	bash scripts/build-rpm.sh

pacman:
	bash scripts/build-pacman.sh

package:
	bash scripts/package.sh

install:
	bash scripts/install-package.sh

check-update:
	@bash scripts/check-upstream-version.sh; \
	rc=$$?; \
	if [ $$rc -eq 1 ]; then exit 0; fi; \
	exit $$rc

check:
	bash -n install.sh scripts/*.sh scripts/lib/*.sh

clean:
	rm -rf qwenwork-app qwenwork-app-next dist dist-next
	rm -rf .asar-tool .asar-extract .test-repack.asar .test-repack.asar.unpacked
	rm -f .tmp-asar-tool.js .tmp-asar-repack.js
