#!/usr/bin/env ruby
# frozen_string_literal: true

# render_sbom_sidecars.rb — re-render the SBOM sidecar pins on THIS
# repo's own registry rows in place (metanorma#168; tebako#1124's
# standing rules). For every version row whose release serves
# `<artifact-stem>.cdx.json`, the platform entry gains
#
#   sbom:
#     artifact: metanorma-<version>-<asset-platform>.cdx.json
#     sha256: <the release's own served digest>
#
# Additive by design (the registry evolution law): pre-SBOM readers
# ignore the key; the pinned CLI's upsert round-trips its serde model
# and DROPS unknown keys, so the pins are re-rendered from the release's
# served bytes at every publish — the same L3 mirror-by-value rule as
# the closure/inkscape mirror rows (tools/refresh_mirrors.rb), never
# hand-maintained. A version whose release serves no .cdx.json keeps no
# pin (any stale one is removed, loudly).
#
#   GH_TOKEN=… ruby tools/render_sbom_sidecars.rb [owner/repo]
#
# The repo argument defaults to $GITHUB_REPOSITORY. Operates on
# tpkg-registry.yaml in the current directory; named failures only,
# never a guess (spec 00 §9).

require "digest"
require "json"
require "open3"
require "yaml"

path = "tpkg-registry.yaml"
repo = ARGV[0] || ENV["GITHUB_REPOSITORY"] or
  abort "NAMED FAILURE: usage: render_sbom_sidecars.rb [owner/repo] (or set GITHUB_REPOSITORY)"
File.exist?(path) or abort "NAMED FAILURE: #{path} not found (run from the feedstock root)"
fixture_root = ENV["SBOM_SIDECAR_ASSETS_DIR"]
if !fixture_root && !ENV["GH_TOKEN"] && !ENV["GITHUB_TOKEN"]
  abort "NAMED FAILURE: GH_TOKEN unset — the release digests ride the gh api"
end

reg = YAML.load_file(path)
reg.is_a?(Hash) && reg["payloads"].is_a?(Array) or
  abort "NAMED FAILURE: #{path} does not parse as a tpkg registry"

# One gh api read per release tag, cached: name → sha256 digest of every
# asset the release serves (the same source the attach step's
# skip-if-current check uses — the served truth, never a recomputation).
# SBOM_SIDECAR_ASSETS_DIR swaps the source for a local fixture tree
# (<dir>/<tag>/<asset-name>, digests computed from the bytes) — the
# rehearsal/acceptance path, never set in CI.
asset_digests = {}
fetch_assets = lambda do |tag|
  asset_digests[tag] ||= begin
    if fixture_root
      dir = File.join(fixture_root, tag)
      unless Dir.exist?(dir)
        warn "render_sbom_sidecars: fixture carries no #{dir} — treated as a release serving no assets"
        next {}
      end
      Dir.children(dir).sort.to_h do |name|
        [name, Digest::SHA256.file(File.join(dir, name)).hexdigest]
      end
    else
      out, err, st = Open3.capture3(
        "gh", "api", "repos/#{repo}/releases/tags/#{tag}",
        "--jq", ".assets[] | .name + \" \" + (.digest // \"\" | sub(\"^sha256:\"; \"\"))"
      )
      st.success? or abort "NAMED FAILURE: cannot read the release #{tag} on #{repo}: #{err.strip}"
      out.each_line.to_h do |line|
        name, digest = line.strip.split(" ", 2)
        [name, digest]
      end
    end
  end
end

# release.ref grammar (spec 04 §1): tfs:github:<owner>/<repo>:<tag>,
# with an optional ?query / #fragment tail. Rows mirroring OTHER repos
# (the spawned runtimes, the requires-closure payloads) are not this
# tool's rows — skipped silently.
def parse_ref(ref)
  ref = ref.to_s.split(/[?#]/, 2).first
  m = %r{\Atfs:github:([^:]+/[^:]+):(.+)\z}.match(ref) or return nil
  [m[1], m[2]]
end

pinned = removed = skipped = 0
reg["payloads"].each do |payload|
  payload["versions"]&.each do |version|
    platforms = version["platforms"]
    unless platforms.is_a?(Hash)
      skipped += 1
      next # the universal shorthand names no per-triplet artifact — no sidecar to pin
    end
    ref_repo, tag = parse_ref(version.dig("release", "ref"))
    next unless ref_repo && tag
    next unless ref_repo.casecmp(repo).zero?
    assets = fetch_assets.call(tag)
    platforms.each_value do |row|
      next unless row.is_a?(Hash) && row["artifact"].is_a?(String)
      artifact = row["artifact"]
      next unless artifact.end_with?(".tfs")
      sbom_name = artifact.sub(/\.tfs\z/, ".cdx.json")
      digest = assets[sbom_name]
      if digest && !digest.empty?
        # Rebuild the row so the sidecar sits with the sha256-manifest-asc
        # family (right after the artifact's own anchor), never appended
        # at the tail.
        rebuilt = {}
        row.each do |k, v|
          rebuilt[k] = v
          if k == "sha256"
            rebuilt["sbom"] = { "artifact" => sbom_name, "sha256" => digest }
          end
        end
        row.replace(rebuilt)
        pinned += 1
      elsif row.delete("sbom")
        removed += 1
        warn "render_sbom_sidecars: #{version["version"]}: the release serves no #{sbom_name} — stale sbom pin removed"
      end
    end
  end
end

File.write(path, reg.to_yaml)
puts "render_sbom_sidecars: #{pinned} platform row(s) pinned, #{removed} stale pin(s) removed, #{skipped} non-triplet row(s) skipped"
