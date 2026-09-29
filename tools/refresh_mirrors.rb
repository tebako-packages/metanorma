#!/usr/bin/env ruby
# frozen_string_literal: true

# refresh_mirrors.rb — re-render this registry's MIRROR rows in place:
# the spawned-runtime rows (java/python, rendered from Tebakofile's pins
# via tools/pins.rb — never hand-duplicated) and the requires-closure
# payload mirrors (inkscape, xml2rfc — copied WHOLESALE from the provider
# registries; the provider registry is the SSOT, this is the L3 mirror by
# value, replaced by entry name).
#
# Why a tool: the publish job ran this as an inline ruby -e, so the
# mirror rows only re-derived at metanorma publish time and went stale
# between publishes (the inkscape 1.4.3-4 ↔ provider 1.4.3-5 divergence,
# 2026-09-29). The same render now serves BOTH the publish job and the
# refresh-mirrors workflow (scheduled + dispatched), so the two paths can
# never diverge again.
#
#   ruby tools/refresh_mirrors.rb <inkscape-registry.yaml> <xml2rfc-registry.yaml>
#
# Env (flowed from tools/pins.rb): JAVA_VERSION, JAVA_TEBAKO,
# PYTHON_VERSION, PYTHON_TEBAKO. Operates on tpkg-registry.yaml in the
# current directory; named failures only, never a guess (spec 00 §9).

require "yaml"

path = "tpkg-registry.yaml"
inkscape_path = ARGV[0] or abort "NAMED FAILURE: usage: refresh_mirrors.rb <inkscape-registry.yaml> <xml2rfc-registry.yaml>"
xml2rfc_path = ARGV[1] or abort "NAMED FAILURE: usage: refresh_mirrors.rb <inkscape-registry.yaml> <xml2rfc-registry.yaml>"

reg = YAML.load_file(path)

# The spawned-runtime registry entries (spec 04 §2's kind: runtime,
# schema MINOR 1 — the resolver's channel 3): without them a real-world
# `tebako install metanorma` (no mirror, no config source pin) cannot
# source the java/python runtimes. Versions accumulate by key (older
# pinned lines keep serving older payload versions). The implementation
# key is load-bearing, not decoration: spec 28 §8 narrows the resolver's
# entry scan to entries carrying the edge's named implementation (the
# xml2rfc python edge names cpython) — an entry without it is invisible
# to that edge (exit 69). The release refs carry the v-prefixed tag
# verbatim — the resolver composes {base}/{tag} from it.
entries = [
  { "name" => "tebako-runtime-java-temurin", "kind" => "runtime",
    "engine" => "java", "implementation" => "temurin",
    "versions" => [ { "version" => "#{ENV.fetch("JAVA_VERSION")}-#{ENV.fetch("JAVA_TEBAKO")}",
                      "platforms" => "universal",
                      "release" => { "ref" => "tfs:github:tamatebako/tebako-runtime-openjdk:v#{ENV.fetch("JAVA_TEBAKO")}" } } ] },
  { "name" => "tebako-runtime-python", "kind" => "runtime",
    "engine" => "python", "implementation" => "cpython",
    "versions" => [ { "version" => "#{ENV.fetch("PYTHON_VERSION")}-#{ENV.fetch("PYTHON_TEBAKO")}",
                      "platforms" => "universal",
                      "release" => { "ref" => "tfs:github:tamatebako/tebako-runtime-python:v#{ENV.fetch("PYTHON_TEBAKO")}" } } ] },
]
entries.each do |entry|
  existing = reg["payloads"].find { |p| p["name"] == entry["name"] }
  if existing.nil?
    reg["payloads"] << entry
  else
    entry["versions"].each do |v|
      slot = existing["versions"].find { |ev| ev["version"] == v["version"] }
      slot ? existing["versions"][existing["versions"].index(slot)] = v : existing["versions"] << v
    end
    %w[kind engine implementation].each { |k| entry.key?(k) ? existing[k] = entry[k] : existing.delete(k) }
  end
end

# The requires-closure payload mirrors (the toolkit inkscape and the
# spec-32 executable xml2rfc): a wild `tebako install metanorma`
# registers only THIS registry, so every non-runtime requires edge must
# resolve here too. The entries are copied WHOLESALE (platforms +
# digests + signature + release.ref) from the provider registries —
# version accumulation belongs to the providers, not the mirror.
{
  "inkscape" => inkscape_path,
  "xml2rfc" => xml2rfc_path,
}.each do |name, mirror_path|
  provider = YAML.load_file(mirror_path)
  entry = provider["payloads"].find { |p| p["name"] == name } or
    abort "NAMED FAILURE: provider registry #{mirror_path} carries no #{name} entry"
  existing = reg["payloads"].find { |p| p["name"] == name }
  existing ? reg["payloads"][reg["payloads"].index(existing)] = entry : reg["payloads"] << entry
end

File.write(path, reg.to_yaml)
