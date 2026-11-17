#!/usr/bin/env ruby
# frozen_string_literal: true

# set_registry_default.rb — move this registry's `default:` for OUR OWN
# payload entry to the version a tag publish just published (the product
# line's current release). Runs in the build-payload publish step, after
# the per-ruby-line `tebako publish` loop and before the registry bot PR.
#
#   ruby tools/set_registry_default.rb <payload-name> <version>
#
# The name flows from pins.rb's PKG_NAME; the version is the DEFAULT ruby
# line's PAYLOAD_VERSION captured inside the publish loop (today the bare
# upstream version — pins.rb owns the line→version mapping; never a
# `-ruby<line>` sibling).
#
# WHY A FEEDSTOCK-SIDE STEP — the default-write lives in the product CLI,
# not here: tamatebako/tebako's crates/tebako-cli/src/publish.rs
# upsert_registry pins `default:` ONLY WHEN ABSENT (`if payload.default
# .is_none()`), and no CLI verb moves an existing one (`tebako publish`
# has no flag; `tebako registry` knows validate/retire/doctor/snapshot/
# log). Only-when-absent is the right floor for a NEW package — the CLI
# cannot know a feedstock's release policy — but left alone it pins the
# default to the FIRST-EVER publish: `default: 1.17.0` sat through the
# whole 1.18 line until the installer seed's bare `tebako install
# metanorma` resolved it against the current runtime line and the abi
# gate refused the composition (issue #144; the 1.18.6 move was a one-off
# hand edit, PR #143).
#
# THE TWO AXES, kept apart deliberately:
#   * the ruby-LINE axis (pins.rb's "publish order matters"): which line's
#     entry the CLI's first-publish pin lands on. Load-bearing only while
#     `default:` is absent — a NEW payload's first publish. RUBY_LINES
#     stays default-line-first so that floor pick is the default line.
#   * the payload-VERSION axis (THIS tool): which version `default:`
#     names as the product line advances. The feedstock's release policy:
#     a tag publish IS the deliberate decision that moves it — the default
#     tracks the just-published default-line version, every publish,
#     idempotently (a re-run of the same tag is a loud no-op).
#
# GUARDS (named failures, never a silent guess — spec 00 §9): the named
# payload entry must exist, and it must already CARRY the target version
# row — the publish loop upserted it; a `default:` naming an absent row
# would break every bare resolve. The tool writes the `default:` key
# ONLY; `versions:` accumulation (older versions keep serving) stays the
# CLI upsert's territory, and the mirrored sibling entries (the spawned
# runtimes, the requires-closure payloads) are never touched.

require "yaml"

module SetRegistryDefault
  # the named fail-closed error: a structural skew between the publish
  # loop and the registry file — never a resolution guess
  class Error < StandardError; end

  # Move entry `name`'s `default:` in the registry at `path` to `version`.
  # Returns true when the file changed, false on an idempotent no-op.
  def self.run(path, name, version)
    reg = YAML.load_file(path)
    entry = (reg["payloads"] || []).find { |p| p["name"] == name } or
      raise Error, "#{path}: no payloads entry named #{name} — the publish loop must upsert it before the default moves"
    carried = (entry["versions"] || []).map { |v| v["version"] }
    carried.include?(version) or
      raise Error, "#{path}: #{name} carries no #{version} row (carries: #{carried.join(' ')}) — `default:` never names a row the registry lacks"
    old = entry["default"]
    if old == version
      puts "#{name}: default already #{version} — nothing to move"
      return false
    end
    entry["default"] = version
    File.write(path, reg.to_yaml)
    puts "#{name}: default #{old || '(absent)'} → #{version}"
    true
  end
end

if __FILE__ == $PROGRAM_NAME
  name = ARGV[0].to_s
  version = ARGV[1].to_s
  if name.empty? || version.empty?
    abort "NAMED FAILURE: usage: set_registry_default.rb <payload-name> <version>"
  end
  begin
    SetRegistryDefault.run("tpkg-registry.yaml", name, version)
  rescue SetRegistryDefault::Error => e
    abort "NAMED FAILURE: #{e.message}"
  end
end
