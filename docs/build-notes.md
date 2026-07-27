# metanorma feedstock — build notes

Everything a reviewer needs to reproduce or extend the `1.16.9` /
`aarch64-macos` payload: what the dependency tree looks like, how the
build is self-hosted, what was proven, and what is deferred.

## 1. Dependency-tree verdict: **triplet-bound**

`metanorma-cli 1.16.9` runtime deps (rubygems API): `git (>= 3)`,
`liquid (~> 5)`, `lutaml-model`, `metanorma (~> 2.5.1)`, and the twelve
flavor gems (`metanorma-iso ~> 3.4.2`, `-iec`, `-ietf`, `-itu`, `-ogc`,
`-cc`, `-bipm`, `-generic`, `-ieee`, `-iho`, `-jis`, `-unece`).

The transitive closure — resolved by the runtime ruby's bundler
(`tools/resolve_closure`, multi-platform lock of 310 specs) and pinned in
`closure/1.16.9-aarch64-macos.txt` — carries **260 gems** after the
skip-defaults policy, with these **native extensions**:

| gem | native? | how the payload gets it |
|-----|---------|--------------------------|
| nokogiri 1.19.4 | C (vendored libxml2/libxslt) | **precompiled** `arm64-darwin` gem, sha256-verified against its `/info` checksum |
| ffi 1.17.4 | C | **precompiled** `arm64-darwin` gem, sha256-verified (via sys-proctable, table_tennis, libpng) |
| libpng 1.6.58.6 | C (vendored libpng) | **precompiled** `arm64-darwin` gem (via emfsvg — the SVG→EMF chain) |
| parsanol 1.3.11 | C++ | **precompiled** `arm64-darwin` gem (via expressir — EXPRESS schemas) |
| sqlite3 2.9.5 | C (vendored sqlite) | **precompiled** `arm64-darwin` gem (via ea — EXPRESS archive) |
| brotli 0.8.0 | C (vendored brotli) | no precompiled gem → **built per triplet** (fontist pattern, `--enable-vendor`) |
| ox 2.14.28 | C | no precompiled gem → **built per triplet** (via omml/plurimath/unitsml — the math chain, unavoidable) |
| oga 3.5 + ruby-ll 2.2.0 | C (liboga, libll) | no precompiled gems → **built per triplet** (oga via omml 0.2.5 `~> 3.4`; ruby-ll is oga's parser dep) |
| psych 5.2.6 | C + libyaml | no precompiled gem, no vendored libyaml → **built per triplet** against the pinned libyaml 0.2.5 tarball (`--with-libyaml-source-dir`; needed because relaton-bib/-core demand `psych ~> 5.2.0` and the runtime default is 5.1.2) |
| websocket-driver 0.8.2 | C (optional) | **built per triplet** (has a LoadError fallback to pure ruby; built anyway — the ext is trivial against the SDK headers) |
| json 2.7.2, bigdecimal 3.1.5, strscan 3.0.9, racc 1.7.3, date 3.3.4 | C | **runtime-provided** (default/bundled gems of the ruby 3.3.7 runtime) |

So the payload is **not** `universal`: it ships per-triplet and the
entrypoint's `runtime_requirement` is the ABI line **`~> 3.3.0`** (the
staging/exec runtime is ruby 3.3.7), per spec 05 §5.

Everything else in the closure is pure ruby — including the heavy data
gems (isodoc-i18n, twitter_cldr, the relaton family) and `mn2pdf 2.62`,
which wraps a Java jar: **PDF output needs a `java` on PATH at exec
time** (GitHub runners ship one; the payload cannot and should not
bundle a JRE).

### Reverse-dependency map of the natives (who drags in what)

- `libpng` ← emfsvg 0.1.2 (isodoc's SVG→EMF for Word output)
- `sqlite3` ← ea 0.4.0 (expressir's .ea archives)
- `parsanol` ← expressir 2.4.0
- `brotli` ← fontisan 0.4.45 (WOFF2, same as the fontist feedstock)
- `ffi` ← sys-proctable 1.3.0, table_tennis 0.0.7, libpng
- `ox` ← omml 0.2.5, plurimath 0.11.6, unitsml 0.6.8
- `psych (~> 5.2.0)` ← relaton-bib 2.1.6, relaton-core 0.0.13
- `nokogiri` ← ~30 gems (isodoc, metanorma, relaton-*, vectory, ...)

### The inkscape link (spec 03 DEPENDS)

The figure path: isodoc rasterizes SVG figures through **vectory 0.10.1**,
which shells out to `inkscape` on PATH. The payload therefore declares

```yaml
requires:
  - {kind: toolkit, name: inkscape, constraint: ">= 1.3", mount: /opt/inkscape}
```

and the dispatcher mounts the inkscape toolkit payload at the
consumer-declared point. The dogfood compile (`fixtures/site.adoc`, one
SVG figure) exercises exactly this chain.

## 2. Self-hosting: no host ruby anywhere

Every ruby process in the build runs on the **published tebako runtime**
(`tebako-runtime-0.15.9-3.3.7-macos-arm64`, sha256-verified against the
tebako-runtime-ruby release manifest by tebako-cli's resolver), driven
through the deploy-driver shim that tebako-cli's own `press` produces —
the fontist feedstock's mechanism, unchanged. Gem fetch is plain HTTPS
(curl/python), never ruby: each `.gem` is sha256-verified against the
compact index `/info/<gem>` checksum before staging.

## 3. Staging (what `tools/build` does)

1. Stub press → runtime resolved + deploy-driver shim.
2. SDK header dir from the pinned `ruby-3.3.7.tar.gz` (the runtime image
   ships no headers; `RUBYOPT` preloads `tools/sdk_patch.rb` for mkmf).
3. Pinned `yaml-0.2.5.tar.gz` (libyaml) extracted for psych's
   `--with-libyaml-source-dir` build — psych's extconf configures and
   statically links it into `psych.bundle`.
4. `gem install --local --ignore-dependencies` of the 260 pinned gems
   into the staging `GEM_HOME`. brotli (`--enable-vendor`), ox, psych,
   websocket-driver compile here (host clang, runtime ruby driving mkmf).
   `PKG_CONFIG_LIBDIR=/nonexistent` keeps Homebrew's libbrotli/libyaml out
   of the link. Verified: `otool -L` on all four `.bundle`s lists only
   `libSystem`.
5. Assemble the payload root (`bin/metanorma` self-locating wrapper,
   `local/stub.rb` v0.15.x launcher-ABI compat, `lib/ruby/gems/3.3.0/`),
   then `mkdwarfs-t` (pinned libtfs release asset) →
   `metanorma-1.16.9-aarch64-macos.tfs`.

### Resolution policy (pins and skips — each justified)

- **`liquid` pinned to 5.6.0** (same as fontist). liquid ≥ 5.6.1 requires
  `strscan >= 3.1.1`; strscan is source-only and the runtime's default is
  3.0.9. All liquid dependents accept 5.6.0 (`~> 5`, `>= 4.0, < 6.0`).
- **Default-gem skips.** Constraints satisfied by the ruby 3.3.7 runtime's
  own default/bundled gems are not duplicated into the payload. Validated
  mechanically: the runtime's full default+bundled set was dumped through
  the shim (72 gems) and every dependency edge onto each candidate was
  checked against the shipped version.
  - fontist-class: `json` (fontist: ~> 2.0 → 2.7.2), `bigdecimal`
    (json-schema: >= 3.1, < 5 → 3.1.5; ox: >= 3.0), `strscan` (via the
    liquid pin), `racc` (bibtex-ruby: ~> 1.7 → 1.7.3; nokogiri: ~> 1.4),
    `drb`, `uri` (>= 0.13.1), `minitest` (>= 5.1), `securerandom` (>= 0.3),
    `benchmark`, `ostruct`, `rexml` (json-ld/omnizip/rdf-xsd: ~> 3.2 /
    ~> 3.3 → 3.3.9), `date` (psych/time: unconstrained → 3.3.4), `time`
    (net-ftp: unconstrained → 0.3.0).
  - metanorma-class: `nkf` (mechanize: unconstrained → 0.1.3), `reline`
    (readline: unconstrained → 0.5.10), `io-console` (only reline 0.6.3's
    `~> 0.5`, moot once reline is skipped → 0.7.1), `prism` (only the
    skipped minitest 6.0.6's `~> 1.5`), `stringio` (psych: unconstrained
    → 3.1.1), `timeout` (net-protocol: unconstrained → 0.4.1), `yaml`
    (oscal: unconstrained → 0.3.0), `singleton` (versionian: ~> 0.2
    → 0.2.0), `ruby2_keywords` (faraday: >= 0.0.4 → 0.0.5), `readline`
    (sparql: ~> 0.0 → 0.0.4), `net-protocol` (net-ftp: unconstrained
    → 0.2.2), `matrix` (sxp: ~> 0.4 → 0.4.2, runtime-bundled like racc).
  - **checked and NOT skipped** (constraint exceeds the default):
    `base64 0.3.0` (down: ~> 0.3 vs 0.2.0), `csv 3.3.5` (relaton-ccsds /
    table_tennis: ~> 3.3 vs 3.2.8), `logger 1.7.0` (bibtex-ruby: ~> 1.7
    vs 1.6.0), `psych 5.2.6` (relaton: ~> 5.2.0 vs 5.1.2),
    `net-ftp 0.1.4` (relaton-3gpp: **~> 0.1.0** — three segments, i.e.
    < 0.2.0 — vs runtime-bundled 0.3.4; this one was mis-skipped on the
    first pass and caught by the activation check in §4: `gem "net-ftp",
    "~> 0.1.0"` answered `did find: [net-ftp-0.3.4]` → restored).
  - **absent from the runtime entirely** (must ship): `scanf 1.0.0`,
    `webrick 1.9.2`.

## 4. Verification (2026-07-27, macOS arm64)

- **Staging + native builds** — 260 gems installed by the runtime ruby
  (no host ruby anywhere); all six per-triplet extensions present and
  linked only against libSystem (`otool -L`):
  `brotli-0.8.0/brotli/brotli.bundle`, `ox-2.14.28/ox/ox.bundle`,
  `oga-3.5/liboga.bundle`, `ruby-ll-2.2.0/libll.bundle`,
  `psych-5.2.6/psych.bundle` (pinned libyaml 0.2.5 static),
  `websocket-driver-0.8.2/websocket_mask.bundle`.
- **Image integrity** — `tfs stat/ls` (in-process libtfs mount):
  `/bin/metanorma`, `/local/stub.rb`, and the gem tree
  (`metanorma-cli-1.16.9` under `/lib/ruby/gems/3.3.0/gems`) present;
  `tfs extract` round-trip clean (`tools/boot_smoke`).
- **Registry payload exec (dispatcher-equivalent)** — the published
  tebako runtime + the extracted payload tree + the manifest entrypoint,
  network-free:

  ```
  $ <runtime-ruby shim> run.rb        # ARGV=["--version"]; load bin/metanorma
  Metanorma 2.5.2
  Metanorma::Cli 1.16.9
  Metanorma::Standoc 3.4.9/IsoDoc 3.7.0
  Metanorma::Iso 3.4.9
  Metanorma::Iec 2.8.11
  ... (all 14 flavors print)
  ```

  Every native in the load path (nokogiri, ffi, ox, oga, psych, ...) is
  exercised by this boot — the flavor requires chain loads them.
  (`undefined method 'version' for nil` printed after the flavor list is
  upstream metanorma-cli noise from its registry walk, also seen with
  conventional gem installs.)
- **Activation check** — during closure work, `gem "net-ftp", "~> 0.1.0"`
  against the runtime answered `did find: [net-ftp-0.3.4]`
  (Gem::MissingSpecVersionError), catching the one mis-skipped gem before
  release; all other skips activate cleanly under the payload GEM_PATH.
- **Dispatcher resolution** — an installed payload record
  (`~/.tebako/payloads/metanorma/1.16.9.tfs` + `.sha256` + manifest
  mirror) is picked up by tebako-shim (`list` shows metanorma 1.16.9
  resolved from the user default; `doctor` reports no record problems).
  `tebako-shim which metanorma` reads the DEPENDS edge and **fails
  closed**: `"metanorma" requires toolkit inkscape but no satisfying
  version is installed (installed: none)` — the inkscape chain is
  enforced, and cannot resolve green on this machine because the inkscape
  feedstock currently ships `x86_64-linux-gnu` only (phase A). The full
  green chain is exactly what the dogfood CI proves on linux.
- **Known boundary (honest, same as fontist)**: the published v0.15.9
  runtime requires a tpkg trailer on `--tebako-image` and mounts a single
  memfs, so the exec proof above is the dispatcher-equivalent form
  (runtime + extracted tree), not the spec-07 bare-image multi-mount
  dispatch — that is the v0.1.0-era runtime ABI. Until then the payload
  carries `/local/stub.rb` (v0.15.x compat). The shim's manifest mirror
  format is the flat `{name, version, entrypoints, requires}` surface —
  the release carries the full spec-03 manifest; the mirror extraction is
  the v0.1.0 installer's job (done by hand for the local record).
- **Release integrity** —
  `metanorma-1.16.9-aarch64-macos.tfs` 158 774 837 bytes,
  sha256 `9f66b31d9e633b07e50d9851fd2a54e7318d7e121fbe35224cd47d7da78cf0e0`;
  re-downloaded from the release and re-hashed (match);
  `tpkg-registry.yaml` pinned to the same digests.

## 5. Tool provenance

| tool | source | pin |
|------|--------|-----|
| tebako-cli 0.15.9 | tamatebako/tebako-rs workspace build | `cargo build --release -p tebako-cli` |
| runtime | tebako-runtime-ruby v0.15.9, `tebako-runtime-0.15.9-3.3.7-macos-arm64` | sha256 per release manifest (CLI-verified) |
| mkdwarfs-t (image build) | tamatebako/libtfs **v0.13.0** asset `mkdwarfs-macos-arm64` (v0.14.1) | SHA256SUMS-verified |
| ruby SDK headers | cache.ruby-lang.org `ruby-3.3.7.tar.gz` | sha256 `9c37c3b1…8628` |
| libyaml | pyyaml.org `yaml-0.2.5.tar.gz` | sha256 `c642ae9b…8ef4` |

## 6. What ran vs what is deferred

- Ran locally: closure resolution (runtime bundler), sha256-verified
  fetch of all 260 gems, the six per-triplet native builds (pre-flown
  into a scratch GEM_HOME first), staging, image, boot-smoke, dispatcher
  record resolution, and the publish itself — transcripts in §4.
  Release: https://github.com/tebako-packages/metanorma/releases/tag/1.16.9
- The committed `tools/build` reproduces the payload end-to-end (stub
  press → SDK → libyaml → verified gems → stage → tree → image →
  manifest); the release image was built by it.
- Deferred to CI (`.github/workflows/build-payload.yml`): the same build
  on `macos-14`, boot-smoke gate, tag-triggered publish; additional
  triplets need the closure re-resolved per triplet (same lock —
  `tools/gen_closure <lock> <platform>` — plus per-triplet native
  rebuilds; linux triplets additionally need the SDK config.h for their
  arch, a tools/build follow-up).
- The dogfood (`.github/workflows/dogfood.yml`) is **gated** until
  tebako-rs v0.1.0 ships release binaries incl. tebako-shim — see the
  workflow header. Also blocked on: an inkscape payload for the dogfood
  triplet (today: `x86_64-linux-gnu` only, so the linux leg goes first)
  and a Java runtime for the mn2pdf PDF leg (GitHub runners ship one).
- Source-only natives for FUTURE triplets (per the task brief, "document
  any source-only ones as triplet-specific follow-ups"): brotli, ox,
  oga+ruby-ll, psych(+libyaml), websocket-driver all build from source
  per triplet; the macOS leg proves the pattern (SDK header dir +
  RUBYOPT preload). linux legs additionally need an `rbconfig`-matching
  `config.h` (tools/build currently emits the darwin one) and psych's
  libyaml configure will pick up the triplet's CC — same pattern, no new
  machinery expected, but unproven until a linux leg runs.
