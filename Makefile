APP_DIR ?= $(HOME)/Applications
BUILD_DIR := build.noindex

.PHONY: build test app install quit uninstall run demo clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh $(BUILD_DIR)

## Builds the app, copies it to $(APP_DIR) and starts it.
install: app
	mkdir -p "$(APP_DIR)"
	@$(MAKE) --no-print-directory quit
	rm -rf "$(APP_DIR)/Unibrow.app"
	ditto --norsrc --noextattr "$(BUILD_DIR)/Unibrow.app" "$(APP_DIR)/Unibrow.app"
	@# An ad-hoc signed build is a "new app" to macOS, so an old Accessibility
	@# grant would show as ON in System Settings while doing nothing. Clear it
	@# so the settings tell the truth; re-enable it from the Unibrow menu.
	@if [ -z "$(CODESIGN_IDENTITY)" ]; then \
		tccutil reset Accessibility dev.andriitk.unibrow >/dev/null 2>&1 && \
		echo "Note: re-enable Exact Window Focus from the Unibrow menu (Accessibility was reset for this build)."; \
	fi
	open "$(APP_DIR)/Unibrow.app"
	@echo "Installed to $(APP_DIR)/Unibrow.app"

## Quits a running Unibrow and waits until it is gone (up to 5 s), so the
## next `open` does not race with the old process (LaunchServices error -600).
quit:
	-@osascript -e 'quit app "Unibrow"' 2>/dev/null
	@for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Unibrow || exit 0; sleep 0.5; done; \
		echo "Unibrow did not quit; stopping it"; pkill -x Unibrow; sleep 0.5

uninstall:
	@$(MAKE) --no-print-directory quit
	rm -rf "$(APP_DIR)/Unibrow.app" "$(HOME)/Library/Application Support/cc-unibrow"
	@echo "Removed. Also run: claude plugin uninstall cc-unibrow@cc-unibrow"

## Runs a debug build straight from SwiftPM (no bundle).
run: build
	"$$(swift build --show-bin-path)/Unibrow"

demo:
	scripts/demo.sh

clean:
	rm -rf .build $(BUILD_DIR)
