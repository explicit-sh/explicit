.PHONY: build-cli build-cli-release build-server dev debug test test-eval clean

ZIG ?= zig
# macOS 26 (Tahoe) is too new for Zig's linker — target macOS 15 for compat
ZIG_TARGET ?= aarch64-macos.15.0-none
INCLUDE_ERTS ?= true

ifneq ($(strip $(IN_NIX_SHELL)$(DEVENV_ROOT)),)
INCLUDE_ERTS := false
endif

build-cli:
	cd cli && $(ZIG) build-exe src/main.zig -target $(ZIG_TARGET) -ODebug
	mv cli/main cli/explicit

build-cli-release:
	cd cli && $(ZIG) build-exe src/main.zig -target $(ZIG_TARGET) -OReleaseSafe
	mv cli/main cli/explicit

build-server:
	cd server && MIX_ENV=prod INCLUDE_ERTS=$(INCLUDE_ERTS) mix release explicit_server --overwrite

# Build debug wrapper and server release into debug/
debug: build-cli build-server
	mkdir -p debug
	cp cli/explicit debug/explicit
	cp server/_build/prod/rel/explicit_server/bin/explicit_server debug/explicit-server
	codesign --sign - --force debug/explicit

# Dev mode: start server via mix (no release needed)
dev:
	cd server && mix deps.get && mix run --no-halt

# Run server tests
test:
	cd server && mix test

# Run eval (costs money — needs ANTHROPIC_API_KEY + Ollama or GEMINI_API_KEY)
test-eval:
	cd eval && mix test -- --include eval

clean:
	rm -f cli/explicit cli/main
	rm -rf cli/.zig-cache cli/zig-out
	rm -rf server/_build
