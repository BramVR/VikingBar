SWIFTFORMAT ?= swiftformat
SWIFTLINT ?= swiftlint
ACTIONLINT ?= actionlint

.PHONY: check build test format docs-check package-app smoke-app-fixture smoke-cli smoke-package workflow-check
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
	python3 Scripts/smoke-cli.py
	python3 -m unittest discover -s Scripts/tests -p 'test_*.py'

docs-check:
	python3 Scripts/check-docs.py

package-app:
	./Scripts/package-app.sh

smoke-app-fixture:
	python3 Scripts/smoke-app-fixture.py

smoke-cli: build
	python3 Scripts/smoke-cli.py

smoke-package:
	python3 Scripts/package-artifacts.py
	python3 Scripts/smoke-package.py

workflow-check:
	$(ACTIONLINT) -color

.PHONY: check-proof proof-live
check-proof:
	./Scripts/test.sh --filter Proof
	python3 Scripts/test-proof-runner.py

proof-live: build
	python3 Scripts/proof-live.py "$(CHECK)"
