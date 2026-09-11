#!/usr/bin/env ruby
# frozen_string_literal: true

# pins.rb — read recipe.yml's `tools:` block (the repo's toolchain pin
# SSOT) and emit KEY=VALUE lines for $GITHUB_ENV. The workflows carry NO
# version or digest literals — every value flows from the recipe.
#
#   ruby tools/pins.rb <tool-platform> [--ruby-line <line>] [--env]
#   ruby tools/pins.rb --release-only [--ruby-line <line>]
#
# <tool-platform> is the tebako release asset platform (macos-arm64,
# linux-gnu-x86_64, windows-ucrt64). --release-only skips the per-platform
# tool asset/digest keys (dogfood's cold-install path) but still emits the
# java edge's JAVA_* keys — the dogfood install pre-stages the spawned
# runtime through them.
#
# --ruby-line selects the ruby line (recipe build.runtime.lines; default:
# build.runtime.default_line) and drives the RUBY_* / SDK_* /
# PAYLOAD_VERSION values. RUBY_LINES always lists every line, default
# first — publish order matters: the CLI's registry upsert sets `default:`
# only when absent, so the default line's entry must land first.
# Unknown platform / missing pin / unknown line is a named error, never a
# guess (spec 00 §9).
#
# NEVER emit a bare TEBAKO_VERSION: tools/build uses that name for the
# RUNTIME release line (recipe build.runtime.tebako) with an env
# override, so a tools-version export silently clobbers the runtime pin
# (the 2026-08-27 collision: the press resolved runtime release v0.3.1,
# exit 124). The tools version lives inside the computed ASSET names; the
# runtime release line is emitted as RUNTIME_TEBAKO (a distinct name —
# the collision lesson applied to the new key).

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

# --- the ruby line (roadmap 77) ------------------------------------------
runtime = recipe.fetch("build").fetch("runtime")
lines = runtime.fetch("lines")
default_line = runtime.fetch("default_line")
ruby_line = default_line
if (i = ARGV.index("--ruby-line"))
  ruby_line = ARGV[i + 1] or die "usage: pins.rb <tool-platform> [--ruby-line <line>] [--env]"
  ARGV.delete_at(i + 1)
  ARGV.delete_at(i)
end
line = lines[ruby_line] or
  die "recipe.yml: no build.runtime.lines.#{ruby_line} (known: #{lines.keys.join(' ')})"
sdk = line.fetch("sdk")
pkg_version = recipe.dig("upstream", "version") || die("recipe.yml upstream.version missing")
# The registry version entry (tebako-resolve treats it as an opaque string;
# dotted compare orders the suffixed form after the bare one): the default
# line keeps the bare upstream version, other lines suffix -ruby<line>.
payload_version = ruby_line == default_line ? pkg_version : "#{pkg_version}-ruby#{ruby_line}"

pairs = {
  "TEBAKO_RELEASE" => release,
  "PKG_NAME" => recipe.fetch("name"),
  "PKG_VERSION" => pkg_version,
  # The ruby axis: every line (default first), the selected line, its
  # runtime version + ABI constraint, its mkmf SDK pin, and the registry
  # version entry the build publishes under.
  "RUBY_LINES" => ([default_line] + (lines.keys - [default_line]).sort).join(" "),
  "RUBY_LINE" => ruby_line,
  "RUBY_V" => line.fetch("version"),
  "RUBY_CONSTRAINT" => line.fetch("constraint"),
  "SDK_URL" => sdk.fetch("url"),
  "SDK_SHA256" => sdk.fetch("sha256"),
  "PAYLOAD_VERSION" => payload_version,
  # The runtime release line (recipe build.runtime.tebako) under a
  # collision-free name — see the header's TEBAKO_VERSION warning.
  "RUNTIME_TEBAKO" => runtime.fetch("tebako"),
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
  # Signing (spec 09 §9 — opt-in via the recipe's signing: block; the
  # hello pattern): the tamatebako root's PRIMARY keyid (low 64). The
  # publish step passes it to `tebako publish --sign=`; empty when the
  # recipe declares no signing (unsigned stays first-class, loudly).
  "SIGNING_KEYID" => recipe.dig("signing", "keyid").to_s,
}

unless ARGV.include?("--release-only")
  platform = ARGV[0] or die "usage: pins.rb <tool-platform> [--ruby-line <line>] [--env] | pins.rb --release-only [--ruby-line <line>]"
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
  # the eval-able form: values may carry spaces (RUBY_LINES) or shell
  # metacharacters (RUBY_CONSTRAINT's "~>") — single-quote, always.
  pairs.each { |k, v| puts "export #{k}='#{v.to_s.gsub("'", "'\\\\''")}'" }
end
