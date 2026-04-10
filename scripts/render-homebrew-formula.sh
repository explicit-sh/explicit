#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: render-homebrew-formula.sh <version> <sha256>}"
SHA256="${2:?usage: render-homebrew-formula.sh <version> <sha256>}"

cat <<EOF
class Explicit < Formula
  desc "Real-time Elixir code analysis + documentation for Claude Code"
  homepage "https://github.com/explicit-sh/explicit"
  version "${VERSION}"
  url "https://github.com/explicit-sh/explicit/releases/download/v#{version}/explicit-v#{version}-macos-arm64.tar.gz"
  sha256 "${SHA256}"
  license "MIT"

  depends_on "nono"

  def install
    bin.install "bin/explicit"

    libexec.install Dir["lib/*"]

    (bin/"explicit-server").write <<~EOS
      #!/bin/bash
      export RELEASE_ROOT="#{libexec}"
      export RELEASE_TMP="\${TMPDIR:-/tmp}/explicit-server-tmp"
      mkdir -p "\$RELEASE_TMP"
      exec "#{libexec}/bin/explicit_server" "\$@"
    EOS
    chmod 0755, bin/"explicit-server"
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/explicit help 2>&1", 0)
  end
end
EOF
