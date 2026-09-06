#!/usr/bin/env ruby
# frozen_string_literal: true

# pins.rb — read recipe.yml's `tools:` block (the repo's toolchain pin
# SSOT) and emit KEY=VALUE lines for $GITHUB_ENV. The workflows carry NO
# version or digest literals — every value flows from the recipe.
#
#   ruby tools/pins.rb <tool-platform> [--env]
#   ruby tools/pins.rb --release-only
#
# <tool-platform> is the tebako release asset platform (macos-arm64,
# linux-gnu-x86_64, windows-ucrt64). --release-only skips the per-platform
# tool asset/digest keys (dogfood's cold-install path) but still emits the
# java edge's JAVA_* keys — the dogfood install pre-stages the spawned
# runtime through them.
# Unknown platform / missing pin is a named error, never a guess
# (spec 00 §9).
#
# NEVER emit a bare TEBAKO_VERSION: tools/build uses that name for the
# RUNTIME release line (recipe build.runtime.tebako) with an env
# override, so a tools-version export silently clobbers the runtime pin
# (the 2026-08-27 collision: the press resolved runtime release v0.3.1,
# exit 124). The tools version lives inside the computed ASSET names.

require "yaml"

def die(msg)
  warn "pins.rb: #{msg}"
  exit 64
end

root = File.expand_path("..", __dir__)
recipe = YAML.load_file(File.join(root, "recipe.yml"))
tools = recipe.fetch("tools")
release = tools.fetch("release")
version = release.sub(/\Av/, "")
die "recipe.yml tools.sha256 missing" unless tools["sha256"].is_a?(Hash)

pairs = {
  "TEBAKO_RELEASE" => release,
  "PKG_NAME" => recipe.fetch("name"),
  "PKG_VERSION" => recipe.dig("upstream", "version") ||
                   die("recipe.yml upstream.version missing"),
  # The spawned java runtime's release line (recipe.java — spec 30). The
  # workflows scope this to TEBAKO_RUNTIME_MIRROR at install/publish
  # steps ONLY (never at dispatch — one base for all engines), and write
  # the JAVA_VERSION/JAVA_TEBAKO preference into the config so the edge's
  # download resolves to the exact pinned pair (a pref-less pick queries
  # the factory's default line, which hosts no java).
  "JAVA_RELEASES_BASE" => recipe.dig("java", "releases_base") ||
                   die("recipe.yml java.releases_base missing"),
  "JAVA_VERSION" => recipe.dig("java", "version") ||
                   die("recipe.yml java.version missing"),
  "JAVA_TEBAKO" => recipe.dig("java", "tebako") ||
                   die("recipe.yml java.tebako missing"),
  # The nested python runtime behind the spec-32 xml2rfc executable edge
  # (recipe.python — the java block's analogue). Same scoping rules: the
  # base feeds TEBAKO_RUNTIME_MIRROR at install/publish steps ONLY, and
  # the PYTHON_VERSION/PYTHON_TEBAKO preference lands in the config so the
  # provider's nested edge resolves to the exact pinned pair.
  "PYTHON_RELEASES_BASE" => recipe.dig("python", "releases_base") ||
                   die("recipe.yml python.releases_base missing"),
  "PYTHON_VERSION" => recipe.dig("python", "version") ||
                   die("recipe.yml python.version missing"),
  "PYTHON_TEBAKO" => recipe.dig("python", "tebako") ||
                   die("recipe.yml python.tebako missing"),
}

unless ARGV.include?("--release-only")
  platform = ARGV[0] or die "usage: pins.rb <tool-platform> [--env] | pins.rb --release-only"
  exe = platform.start_with?("windows") ? ".exe" : ""
  { "tebako" => "TEBAKO", "tebako-shim" => "SHIM", "tfs" => "TFS" }.each do |tool, key|
    sha = tools.dig("sha256", tool, platform) or
      die "recipe.yml: no tools.sha256.#{tool}.#{platform} pin"
    pairs["#{key}_ASSET"] = "#{tool}-#{version}-#{platform}#{exe}"
    pairs["#{key}_SHA256"] = sha
  end
end

if ARGV.include?("--env") || ARGV.include?("--release-only")
  pairs.each { |k, v| puts "#{k}=#{v}" }
else
  pairs.each { |k, v| puts "export #{k}=#{v}" }
end
