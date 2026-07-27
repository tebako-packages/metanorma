# tebako-packages/metanorma

Feedstock for **metanorma** — the flagship `kind: app` payload of the
`tebako-packages` org (a runtime-required ruby application) and the org's
CI dogfood: its payload declares a toolkit dependency on
[`inkscape`](https://github.com/tebako-packages/inkscape) (consumer-declared
mount `/opt/inkscape`), so installing it exercises the full dispatch chain.

- Upstream: [metanorma-cli](https://github.com/metanorma/metanorma-cli) 1.16.9 (RubyGems)
- Payload: `metanorma-1.16.9-aarch64-macos.tfs` (DwarFS image, per-triplet)
- Registry: `tfs:github:tebako-packages/metanorma` (see `tpkg-registry.yaml`)

## Layout

- `recipe.yml` — upstream, runtime, resolution pins, feedstock deps, platforms
- `manifests/payload.yaml` — the spec 03 payload manifest (filled at build)
- `tpkg-registry.yaml` — this feedstock's registry (pinned at release)
- `closure/1.16.9-aarch64-macos.txt` — the pinned, sha256-verified gem set
- `tools/` — `build` (stage → image → manifest), `boot_smoke`, `publish`,
  `resolve_closure` + `gen_closure` (re-resolve a new upstream version)
- `fixtures/` — the dogfood document (one figure through the inkscape path)
- `docs/build-notes.md` — dep-tree findings, what ran, what's deferred

## Why triplet-bound

metanorma's closure (260 gems) contains native extensions: nokogiri, ffi,
libpng, parsanol, sqlite3 (precompiled per platform) and brotli, ox, oga (+ ruby-ll),
psych, websocket-driver (compiled per triplet during the build). The payload ships
per-triplet and its runtime requirement is the ABI line `~> 3.3.0`, not a
pure-ruby range. Details: `docs/build-notes.md`.

## Using

```console
$ tebako add-registry tfs:github:tebako-packages/index
$ tebako install metanorma@1.16.9    # pulls the ruby runtime + inkscape too
$ metanorma --version                 # via the shim layer
```

## The dogfood

`.github/workflows/dogfood.yml` is the roadmap-32 proof: a bare runner
installs the tebako CLI from the tebako-rs release, installs this payload
through the index, compiles a document whose figure is rasterized by the
inkscape payload, and asserts the PDF's magic bytes — plus a tight-jail
variant. Gated until tebako-rs v0.1.0 ships (see the workflow header).
