SWIFTFORMAT ?= swiftformat
SWIFTLINT ?= swiftlint

.PHONY: check build test format docs-check package-app smoke-app-fixture
build:
	swift build

test:
	./Scripts/test.sh

format:
	$(SWIFTFORMAT) Sources Tests

check:
	$(SWIFTFORMAT) Sources Tests --lint
	DYLD_FRAMEWORK_PATH="$$(xcode-select -p)/usr/lib$${DYLD_FRAMEWORK_PATH:+:$$DYLD_FRAMEWORK_PATH}" $(SWIFTLINT) --strict
	swift build
	./Scripts/test.sh
	python3 Scripts/check-docs.py

docs-check:
	python3 Scripts/check-docs.py

package-app:
	./Scripts/package-app.sh

smoke-app-fixture:
	python3 Scripts/smoke-app-fixture.py
