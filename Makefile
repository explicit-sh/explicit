.PHONY: build-cli build-cli-release build-server dev clean

ZIG ?= zig
# macOS 26 (Tahoe) is too new for Zig's linker — target macOS 15 for compat
ZIG_TARGET ?= aarch64-macos.15.0-none

build-cli:
	cd cli && $(ZIG) build-exe src/main.zig -target $(ZIG_TARGET) -ODebug
	mv cli/main cli/explicit

build-cli-release:
	cd cli && $(ZIG) build-exe src/main.zig -target $(ZIG_TARGET) -OReleaseSafe
	mv cli/main cli/explicit

build-server:
	cd server && MIX_ENV=prod mix release explicit_server --overwrite

# Dev mode: start server via mix (no release needed)
dev:
	cd server && mix deps.get && mix run --no-halt

clean:
	rm -f cli/explicit cli/main
	rm -rf cli/.zig-cache cli/zig-out
	rm -rf server/_build
