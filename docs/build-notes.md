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
staging/exec runtime is ruby 3.3.7) with **`implementation: mri`** named
alongside `abi` (spec 28 §8's native law — enforced at press/publish per
tebako#556's authoring gate), per spec 05 §5.

Everything else in the closure is pure ruby — including the heavy data
gems (isodoc-i18n, twitter_cldr, the relaton family) and `mn2pdf 2.62`,
which wraps a Java jar: **PDF output spawns `java` at exec time** — a
spec-30 `kind: runtime` edge (`engine: java`) that `tebako install`
pre-stages from the tebako-packages/openjdk runtime release. The JVM is
a child process dispatched from the store (never a host-PATH lookup; a
host without java compiles identically). See §7.4.

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
- **`metanorma` pinned to 2.5.4** (metanorma-cli's `~> 2.5.1` would float).
  2.5.4 materialises absolute pdf-portfolio cover/keystore directive paths
  into the output folder (metanorma/metanorma#596): mn2pdf's JVM reads those
  directives from the collection XML itself, and an in-VFS gem path is not a
  real host path it can open. 2.5.2→2.5.4 runtime dependencies are
  byte-identical, so the closure is a one-line version+digest change per
  triplet (digest from the rubygems compact index, same source as
  tools/gen_closure). The gem ships no executables (`executables: []`), so
  the 66-entrypoint inventory is unaffected.
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
- **Full compile through the payload (bonus, beyond the brief)** —
  `fixtures/site.adoc` compiled by the same dispatcher-equivalent exec
  (`compile -x xml,html,pdf`; doc output omitted locally — that is the
  leg that rasterizes the figure via inkscape, and no inkscape payload
  exists for this triplet yet): exit 0, `site.xml` +
  `site.presentation.xml` + `site.html` + `site.pdf` produced, PDF magic
  bytes `%PDF-` verified. mn2pdf 2.62's jar ran as a java subprocess off
  the extracted tree (the memfs-invisible-file trick does not apply to
  extracted payloads); fontist provisioned fonts into
  `~/.metanorma/fonts` (one non-fatal registration warning,
  `NISC18030.ttf`). This also proves the fixture compiles clean — the CI
  dogfood runs it with the default extension set (incl. doc → vectory →
  the inkscape payload).
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
- CI (`.github/workflows/build-payload.yml`): the mac leg runs the same
  build on `macos-14` with the tebako/tfs **release binaries** (v0.2.0,
  sha256-pinned — releases are the interface; the earlier from-source
  CLI build via vcpkg is retired, same repair as tebako-packages/fontist),
  runtime line 0.16.6, boot-smoke gate, tag-triggered publish. The
  `x86_64-linux-gnu` leg runs the same POSIX shim staging on
  `ubuntu-24.04` and publishes together with the mac leg (§8). The
  `x86_64-windows-ucrt` leg publishes together with the mac + linux legs
  since the 0.16.6-line gate proved green (PR #22; §7).
- The dogfood (`.github/workflows/dogfood.yml`) runs the published
  payload on macos + linux (see the workflow header): the figure path
  rides the inkscape toolkit payload, and the PDF leg's java need is
  answered by the spec-30 runtime edge — install pre-stages the openjdk
  runtime and mn2pdf's `java` spawn dispatches it from the store (§7.4).
  The windows leg joins when the windows payload publishes.
- Source-only natives for FUTURE triplets (per the task brief, "document
  any source-only ones as triplet-specific follow-ups"): brotli, ox,
  oga+ruby-ll, psych(+libyaml), websocket-driver all build from source
  per triplet; the macOS leg proves the shim pattern (SDK header dir +
  RUBYOPT preload), the linux leg proves the same POSIX shim pattern off
  the CLI-provisioned runtime SDK alone (§8), and the windows leg proves
  the driver-image pattern (§7).

## 7. Windows leg (`x86_64-windows-ucrt`) — build green, publication gated at the runtime layer

### 7.1 Platform key

The payload platform axis is the spec 03 §3 vcpkg-triplet vocabulary
(`tpkg::Platform` in tamatebako/tebako is the single owner): the windows
leg is **`x86_64-windows-ucrt`** — the same GNU-style form as the existing
`aarch64-macos`. `windows-ucrt64` is the *release-asset-name* form of the
same platform and appears only in tool/runtime artifact names
(`tfs-0.1.1-windows-ucrt64.exe`,
`tebako-runtime-0.16.2-3.3.7-windows-ucrt64`). `universal` is NOT
available: §1 — the closure carries native extensions (nokogiri, ffi,
libpng, parsanol, sqlite3 precompiled per platform — swapped for their
`x64-mingw-ucrt` variants in the windows closure; brotli, ox, oga,
ruby-ll, psych, websocket-driver compiled per triplet), so the payload
ships per-triplet with the ABI-line `runtime_requirement ~> 3.3.0`
(`abi: x64-mingw-ucrt`, the staging runtime's `Gem::Platform.local`).

### 7.2 The leg (mirrors the mac leg, one shell branch per divergence)

- **Packager**: `tebako`/`tfs` windows binaries from tamatebako/tebako
  **release v0.1.1**, sha256-pinned in the workflow (v0.1.1 predates the
  release's SHA256SUMS asset; digests in §7.5 — identical values are
  pinned in the fontist and openjdk feedstocks). The runtime
  (`tebako-runtime-0.16.2-3.3.7-windows-ucrt64` + env `.tfs`) is fetched
  directly and verified against the tebako-runtime-ruby release
  SHA256SUMS.txt — the resolver's own fallback index — because
  `tebako press` cannot run on windows today: its bootstrap resolution
  asks the tebako-bootstrap index for `windows-ucrt64`, but that release
  line still names its windows asset `windows-x86_64` (exit 131; the
  same rename the runtime line already went through). No shim is needed
  on this leg anyway (there is none on Windows).
- **Staging without a shim**: the deploy-driver ruby shim the mac leg
  stages through is **POSIX-only by construction** (tebako-cli
  `deploy.rs`), and the memfs-exec spawn patch is POSIX-only too. The
  windows leg runs its staging scripts as **entries of a purpose-built
  driver image**: `tfs mkimage` a dir with `stage_app.rb` /
  `stage_native_manual.rb`, then
  `rt.exe --tebako-image driver.tfs:-:/drv --tebako-entry /stage_app.rb`
  with `TEBAKO_RUNTIME_IMAGE=<env.tfs>` + `TEBAKO_PASS_THROUGH=1` (the
  spec 17 bare-image grammar; no tpkg trailer needed). The abi line is
  written out by `stage_app.rb` itself (`Gem::Platform.local` →
  `abi.txt`) — derived, never pinned.
- **The six source-only natives** (fontist had one; metanorma has six):
  rubygems' ExtConfBuilder spawns `Gem.ruby` — impossible on Windows.
  `tools/stage_native_manual.rb` instead runs each `extconf.rb`
  **in-process** (`$0` pinned to `extconf.rb` — mkmf anchors srcdir/TARGET
  on it), the host runs `make` (ucrt64 gcc), and the script installs the
  `.so` the way rubygems would (gem tree at `lib/<target>.so`, extensions
  bookkeeping with `Gem::Platform.local`, `gem.build_complete`,
  `spec.to_ruby` stub). **psych builds LAST**: `Gem::Package#spec` loads
  yaml, and once `psych.so` sits in the stage it shadows the runtime's
  static default psych in every subsequent driver process — and no
  dynamic `.so` loads on windows today (§7.3b), so any later driver call
  that activates psych dies with error 126 (observed in CI: the
  websocket-driver build after psych's place). With psych last no driver
  process ever sees it. The per-gem ext dirs and create_makefile targets
  (verified against the unpacked gems):

  | gem | extconf dir | target | placed at | notes |
  |-----|-------------|--------|-----------|-------|
  | brotli 0.8.0 | `ext/brotli` | `brotli/brotli` | `lib/brotli/brotli.so` | `--enable-vendor` (vendored sources) |
  | ox 2.14.28 | `ext/ox` | `ox/ox` | `lib/ox/ox.so` | — |
  | oga 3.5 | `ext/c` | `liboga` | `lib/liboga.so` | — |
  | ruby-ll 2.2.0 | `ext/c` | `libll` | `lib/libll.so` | — |
  | psych 5.2.6 | `ext/psych` | `psych` | `lib/psych.so` | dir_config against the host-built static libyaml (below) |
  | websocket-driver 0.8.2 | `ext/websocket-driver` | `websocket_mask` | `lib/websocket_mask.so` | — |
- **psych's libyaml**: with `--with-libyaml-source-dir` psych's extconf
  runs libyaml's `configure` via `system()` — a shell script a mingw ruby
  cannot exec (no POSIX spawn). The leg therefore builds libyaml 0.2.5
  **on the host** (msys2 `configure --disable-shared && make`, same pin
  as the mac leg) and psych's extconf rides the plain dir_config path
  (`--with-libyaml-include`/`--with-libyaml-lib`), statically folding
  `libyaml.a` into `psych.so` — the same self-contained outcome as the
  mac leg's `--with-libyaml-source-dir` build.
- **mkmf inputs**: headers from the recipe-pinned ruby 3.3.7 tarball
  (configure'd for x64-mingw-ucrt under MSYS2 — configure only; the
  generated `config.h` is all the build needs) and an **import library**
  whose def is parsed from the facet DLL's own export table
  (`objdump -p` → def → `dlltool --input-def`), the facet being the
  sha256-verified artifact fetched in the runtime step — the SSOT for
  its export surface. Extensions therefore import
  `x64-ucrt-ruby330.dll` (`$DLL_INSTALL_AS`, manifest-asserted), the
  same module the runtime's own env-image extensions import
  (tebako-runtime-ruby#40's gate). The earlier shape — `dlltool
  --export-all` over a locally built static libruby — offered ~102
  internals the facet does not export (mkexports `PrivateNames`:
  `Init_*`, `InitVM_*`, `threadptr`, `DllMain`); every mingw
  extension's CRT startup references `DllMain`, so the link bound it
  against the ruby DLL and the boot smoke's `LoadLibrary` died
  `ERROR_PROC_NOT_FOUND` (exit 127, psych.so simply loaded first).
  Deriving the def from the facet makes a runtime-missing import
  impossible by construction and retires the local ruby compile (and
  with it the `win32_clock_rename_msys` patch — build-only; the
  configure invocation is unchanged, so the generated `config.h` matches
  the archive-era one).
- **Closure**: `closure/1.16.9-x86_64-windows-ucrt.txt` — the mac
  resolution with the five precompiled natives swapped for their
  `x64-mingw-ucrt` variants (`/info` checksums; all five exist —
  nokogiri, ffi, libpng, parsanol, sqlite3). Imaging: `tfs mkimage`
  (the release CLI's in-process Writer, same as the mac leg).
- **Vendored DLL siblings** (`tools/vendor_siblings.rb`, a driver entry
  run after the payload tree is assembled): the libpng gem's
  `x64-mingw-ucrt` package vendors `libpng16.dll` (loaded by full path
  via `ffi_lib File.expand_path(...)`) but NOT the `zlib1.dll` it
  imports — vendored nowhere in the payload, not a Windows system DLL,
  so every PNG embed died LoadError 126 once the runtime-layer classes
  unblocked (packed-mn#251 class 2; class 1 — `libwinpthread-1.dll` on
  the source-built `.so` set — is the runtime factory's fix,
  tebako-runtime-ruby#133). Spec 22 §2.1 resolves such non-system,
  non-runtime imports importer-dir-relative, so the fix is payload-side:
  the toolchain's `zlib1.dll` (`$MSYSTEM_PREFIX/bin`, pinned as
  `mingw-w64-ucrt-x86_64-zlib` in the workflow) is copied next to every
  `libpng16.dll` in the payload tree — keyed by an explicit
  importer=>siblings map, fail-closed (a named error when an importer's
  sibling cannot be sourced), keeping the runtime free of gem-specific
  hacks. Unit specs: `spec/vendor_siblings_spec.rb` (`bundle exec rspec`).
- **Entrypoint**: `templates/bin/metanorma` carries the windows
  mount-addressing guard (VFS-rooted paths stay lexical in
  `File.expand_path`/`File.realpath`; host paths keep real semantics) —
  the fontist payload's provisional convention, plus one metanorma-driven
  widening: `realpath` is variadic because `Pathname#realpath` passes a
  base arg on ruby 3.3 and metanorma-cli's exe calls exactly that
  (`Pathname.new(__FILE__).realpath` — fontist's exe never does, so its
  1-arg guard never saw the call; same widening belongs upstream in
  fontist's template as a follow-up).

### 7.3 Runtime-layer gaps found by this leg (same two as fontist)

### 7.3a Mount addressing on windows (G1 — only partly payload-guardable)

- **Drive re-rooting.** ruby on windows re-roots drive-relative absolute
  paths onto the cwd drive (`File.expand_path`) or the
  `GetFullPathNameW` answer (`File.realpath` — rubygems' PathSupport
  calls it on every gem path). A payload mounted at `/` escapes the VFS
  the moment ruby computes on its paths (`/lib/...` → `D:/lib/...`, a
  host path). The mount triple grammar cannot carry a drive-letter mount
  (colons split file:slot:mount — `A:/p` parses as slot `A`), so the
  entrypoint wrapper keeps VFS-rooted paths literal instead. That carries
  boot through gem activation, bin resolution, and the exe load — all
  served from the VFS.
- **The C-level wall (not payload-fixable).** `require` expands each
  load-path candidate with `rb_file_expand_path_internal` at the C
  level, where no Ruby-level guard can intercept — drive-relative VFS
  paths re-root to the cwd drive and the require dies (`cannot load such
  file -- metanorma/cli`). Until the runtime/shim defines the windows
  mount-addressing convention (tamatebako/tebako#365), payload exec on
  windows stops here.
- **`tebako press` bootstrap index.** The CLI's bootstrap resolution asks
  the tebako-bootstrap index for `windows-ucrt64`; that release line
  still names its windows asset `windows-x86_64` (exit 131). The leg
  fetches the runtime directly (SHA256SUMS-verified).

### 7.3b The publication blocker: windows runtimes load no dynamic native extensions

The build above is green, but the boot smoke **cannot pass** against the
published windows runtimes (the fontist feedstock's evidence, runtime
0.16.2/3.3.7 — the same runtime this leg stages against):

1. `tebako-runtime-0.16.2-3.3.7-windows-ucrt64` is a static ruby
   (`--disable-shared --with-static-linked-ext`). Its PE has **no export
   table** and imports only system DLLs — there is no symbol provider a
   native extension could bind to.
2. The release ships **no ruby DLL** — not as an asset, not inside the
   env image. The image's own three dynamic extensions (`debug`,
   `racc/cparse`, `rbs_extension`) import **`ruby.exp.dll`** — a module
   that exists nowhere; they only fail silently because all three gems
   have pure-ruby fallbacks.
3. Precompiled windows gems are equally dead: `nokogiri-...-x64-mingw-ucrt`'s
   `.so` imports `x64-msvcrt-ruby330.dll` (the RubyInstaller ABI name) —
   also absent. metanorma's closure carries FIVE such precompiled natives
   (nokogiri, ffi, libpng, parsanol, sqlite3) plus six per-triplet
   builds importing `ruby.exp.dll` — every one of them is a hard
   LoadError at boot (`metanorma version` loads the flavor requires
   chain, which pulls nokogiri immediately).
4. Fix shape (runtime factory, not this feedstock —
   tamatebako/tebako-runtime-ruby#40): link the `ruby.exp` export object
   into the interpreter exe and ship a `ruby.exp.dll`-named forwarding
   alias + import library, plus an `x64-msvcrt-ruby330.dll` alias if
   precompiled RubyInstaller gems should load.

RESOLVED 2026-08-23 — PR #22 proved the gate green on the 0.16.6 line
(incl. the html-xml check with the tebako#437 CA-bundle workaround) and
the publish wiring now includes the windows artifact (needs +
--payload + registry). The rest of this section is the pre-resolution
record, kept as the incident log.

Until then the windows leg stays build-only: `tools/smoke_verdict` turns
exactly the known LoadError signature green
(`cannot load such file -- (metanorma|nokogiri|ffi|brotli|ox|liboga|libll|psych|sqlite3|libpng|parsanol|websocket)`),
fails any other failure mode, and **no windows artifact is published**
(the publish job needs only the mac leg; the registry gains the windows
entry when the gate is enforced — the same gate as tebako-packages/fontist).

### 7.4 The openjdk dependency (spec 30 runtime edge — toolkit mount retired)

The manifest's java edge is platform-agnostic and is now a **runtime**
edge:

```yaml
- kind: runtime
  engine: java
  constraint: ">= 21, < 26"
  expose: [java]
```

The earlier toolkit form (`{kind: toolkit, name: openjdk, mount:
/opt/openjdk}`) is retired. A toolkit mount exists only inside the
interpreter's userspace VFS, so a subprocess cannot exec `java` from it —
the kernel needs a real host path, strictest on windows where the JVM's
own DLL search never follows the VFS. The runtime edge instead pre-stages
the JVM as real store artifacts at install (spec 30 §3
`install_runtime_edge`: exe + env `.tfs` + trust markers under
`~/.tebako/runtimes/java-*`), and at exec time mn2pdf's `java` spawn is
rewritten to a full dispatch of that runtime's wrapper exe with
`TEBAKO_RUNTIME_IMAGE` and the driver-computed union jail (spec 30 §4) —
no `/opt/openjdk` mount, no `JAVA_HOME`, no host-PATH fallback, on every
platform. The inkscape edge stays a toolkit mount (its windows payload is
a separate follow-up — inkscape ships `x86_64-linux-gnu` only today).

### 7.5 Tool provenance (this era)

| tool | source | sha256 |
|------|--------|--------|
| `tebako-0.1.1-windows-ucrt64.exe` | tamatebako/tebako v0.1.1 | `9cd4f2e0922acb776797a284f2f3ea1448f93c228c92e84b0f1f7a322857c2b8` |
| `tfs-0.1.1-windows-ucrt64.exe` | tamatebako/tebako v0.1.1 | `82ed22135321449c81530e1fabeba73555195ea411e0d9cca4458a23fe5ad01c` |
| `tebako-0.1.1-macos-arm64` | tamatebako/tebako v0.1.1 | `025fdf6948ab678895004349c7ada9c4a13676de5d1eb71bdac40dedcae73d84` |
| `tfs-0.1.1-macos-arm64` | tamatebako/tebako v0.1.1 | `b1848bda4d12ec520faa682adf293f58e07ba6fedc28e373911cff24e56fe412` |
| runtime (both legs) | tebako-runtime-ruby v0.16.2, ruby 3.3.7 | release manifest / SHA256SUMS (verified) |
| ruby SDK tarball (native builds) | cache.ruby-lang.org `ruby-3.3.7.tar.gz` | `9c37c3b1…8628` (recipe pin) |
| `win32_clock_rename_msys.patch` (windows SDK) | tamatebako/ruby v0.2.14 | `6158e743…d875` |
| libyaml | pyyaml.org `yaml-0.2.5.tar.gz` | `c642ae9b…8ef4` (recipe pin) |

## 8. Linux leg (`x86_64-linux-gnu`) — build + boot smoke green, publishes with the mac leg

Proven in CI (PR #9, run
[31398143330](https://github.com/tebako-packages/metanorma/actions/runs/31398143330),
job `x86_64-linux-gnu`, ubuntu-24.04): tools fetch sha256-pinned and
cross-checked, runtime 0.16.3 resolved, all 260 gems staged, the six
source-only natives compiled, image written, boot smoke `BOOT-SMOKE-OK`
(`Metanorma::Cli 1.16.9` exec'd from the mounted image through the
published linux runtime driver — the same hard gate as the mac leg).

### 8.1 The leg shape: POSIX shim staging, no feedstock SDK

The leg is the macOS POSIX shape, not the windows driver-image shape: a
stub `tebako press` resolves the runtime (`tebako-runtime-
0.16.3-3.3.7-linux-gnu-x86_64` + env `.tfs`, sha256-verified by the CLI
resolver) and yields the deploy-driver shim (`o/p/ruby`); every ruby
process of the staging runs through it.

The one deliberate divergence from the macOS arm: **no feedstock SDK and
no `sdk_patch.rb` preload**. On POSIX the CLI's press itself provisions
the runtime SDK (tebako-cli `sdk.rs`: the patched ruby source release
the runtime was built from, configure args replayed from the runtime's
own rbconfig, plus a symbol-stub archive re-declaring the runtime exe's
exported ruby-ABI symbols) and the shim's driver applies the mkmf
overrides itself (`rubyhdrdir`/`rubyarchhdrdir` → the SDK header tree,
`LIBRUBYARG` → the stub — probe executables only; the shipped `.so`
links no libruby and resolves against the runtime executable at load
time, the linux dynamic-lookup default). The feedstock SDK + preload
exist for the darwin link shape (`-undefined dynamic_lookup`,
`-bundle_loader` strip) — neither has a linux reading, so the leg rides
the CLI SDK alone. Psych's libyaml still builds from the pinned
`yaml-0.2.5` source via `--with-libyaml-source-dir` (its configure runs
in-process on POSIX; it picked up the runner's gcc — the §6 "unproven"
note, now proven).

### 8.2 Platform keys and the closure

- Triplet (spec 03 §3): `x86_64-linux-gnu`; release-asset/runtime form:
  `linux-gnu-x86_64` (`metanorma-1.16.9-linux-gnu-x86_64.tfs`).
- The staging runtime reports `RbConfig arch = x86_64-linux`,
  `Gem::Platform.local = x86_64-linux` (the manifest's `abi:` line is
  derived from it, never pinned). The five precompiled natives ship two
  spellings for glibc x86_64 — `nokogiri/ffi/sqlite3` as
  `-x86_64-linux-gnu`, `libpng/parsanol` as plain `-x86_64-linux`; both
  match the runtime's platform under rubygems' normalized-linux version
  rule (`Gem::Platform#===`), install from the explicit `.gem` file, and
  activate at boot — proven by the smoke.
- `closure/1.16.9-x86_64-linux-gnu.txt`: the macOS resolution with those
  five swaps; every sha256 re-verified against the downloaded `.gem`
  (== its `/info/<gem>` checksum). The six source-only natives stay
  per-triplet source builds (SOEXT `so`; the extensions bookkeeping tree
  keys on `x86_64-linux/3.3.0-static`).

### 8.3 Tool provenance (this leg)

| tool | source | sha256 |
|------|--------|--------|
| `tebako-0.1.2-linux-gnu-x86_64` | tamatebako/tebako v0.1.2 | `8b45d11199a5b878abcae3746f8c0ecb6a53e871890bdbd5d9d1e537a8d1f59e` |
| `tfs-0.1.2-linux-gnu-x86_64` | tamatebako/tebako v0.1.2 | `07e47cf05fe19cbc726ad028e2ec8463502809c819c71d78449bc7a5650b95b4` |
| runtime | tebako-runtime-ruby v0.16.3, ruby 3.3.7, `linux-gnu-x86_64` | release manifest / SHA256SUMS (CLI-verified) |
| runtime SDK (mkmf inputs) | CLI-provisioned from tamatebako/ruby `tfs-ruby-3.3.7-src.tar.gz` (v0.2.1) + the runtime's rbconfig | SHA256SUMS-verified by the CLI |
| libyaml (psych) | pyyaml.org `yaml-0.2.5.tar.gz` | `c642ae9b…8ef4` (recipe pin) |

First green image: `metanorma-1.16.9-linux-gnu-x86_64.tfs`,
sha256 `15140aa885409e86de4ba4c3b1b175a2097b56efcc3da153ab3cb1b671594c1f`
(CI-built bytes; any rebuild re-images from the same pinned inputs).

## 9. The ruby axis (roadmap 77): one recipe, two payload flavors

The feedstock builds the payload per RUBY LINE (`build.runtime.lines`):
the default line `3.3` (ruby 3.3.12, ABI `~> 3.3.0`) and the `4.0` line
(ruby 4.0.6, ABI `~> 4.0.0`), sharing the runtime release line
(`build.runtime.tebako: 0.16.22`). The line key drives everything
per-line — the staging/exec runtime version, the entrypoint ABI
constraint (the manifest's `@@CONSTRAINT@@` placeholder, filled per
line at build), the mkmf SDK pin, the closure file, and the registry
version entry: the default line keeps the bare upstream version
(`1.16.9`), other lines suffix (`1.16.9-ruby4.0`). One upstream version,
one registry entry per line; the user picks through the spec 07 §2.1
version chain (`TEBAKO_METANORMA_VERSION` / `.tebako-tools.yaml` /
`defaults:`), and a native-extension payload stays locked to its ABI
line (spec 28 §8 — the dispatcher refuses a cross-line pairing by name,
exit 69, never a segfault).

Publish order is load-bearing: the CLI's registry upsert sets
`default:` only when absent, so the default line's entry must land
first — `pins.rb` emits `RUBY_LINES` default-first and the publish job
loops it in that order into one `--registry-out`.

The SDK pins' provenance is tamatebako/ruby's `versions.yml` (the
source factory SSOT): it owns each version's upstream tarball url +
sha256, and the recipe carries the flowed copy per line
(`build.runtime.lines.<line>.sdk` — 3.3.12 `b06d63be…`, 4.0.6
`837d299e…`, both diff-verified against versions.yml).

### 9.1 The 4.0 closure: a fresh per-line resolution

Closures are per line and pinned per release — the 3.3 files
(`closure/1.16.9-*.txt`) are untouched; the 4.0 files
(`closure/1.16.9-ruby4.0-*.txt`) were resolved fresh against the 4.0.6
runtime's own shim (`tools/resolve_closure`, 311-spec lock) and
rendered per platform by `tools/gen_closure`:

- **Platform candidates** (new in gen_closure): a precompiled native is
  emitted in the first candidate spelling present in the lock
  (`x86_64-linux-gnu` → plain `x86_64-linux` fallback — libpng/parsanol
  publish only the plain spelling), else swapped in by name with the
  `/info/<gem>` checksum (fail-closed when absent). Windows resolved all
  five swap-ins (`nokogiri/ffi/libpng/parsanol/sqlite3` as
  `-x64-mingw-ucrt`), including `sqlite3-2.9.6-x64-mingw-ucrt`.
- **The closure serves the manifest's declared commands.** The naive
  fresh resolution dropped `lutaml-xsd` (with its `xsdvi`/`rng`/`tty-*`
  subtree) and `ukiryu` (with `versionian` + `json-schema`) — no current
  gem depends on either (mn2pdf 2.72 dropped ukiryu) — but
  `manifests/payload.yaml` DECLARES both commands, and `tools/build`'s
  declaration-drift guard failed closed, one at a time ("executable of 0
  staged gems"). Dropping the declarations would regress the PUBLISHED
  contract (the 1.16.9 payload ships them; `lutaml-xsd` is even
  PATH-active), so both gems are now explicit resolution roots in
  `tools/resolve_closure` — on both lines, keeping future
  re-resolutions symmetric.
- **Net drift after the roots: the gem SETS are identical but for one
  gem** — 261 gems vs the 3.3 line's 260; the only 4.0-only name is
  `postsvg` (vectory 0.12.0's new dependency), and nothing the 3.3 line
  ships is absent. `ukiryu`'s `git ~> 3.0` pin also restored `git
  3.1.1` (fresh resolution otherwise floats to 5.4.1) and with it
  `process_executer 1.3.0` — byte-identical sha256s with the published
  3.3 closure; the remaining drift is ~68 version bumps from the
  fresh-resolution patch train (`mn2pdf 2.62→2.72`,
  `moxml 0.1.26→0.5.30`, `canon 0.2.12→0.3.29`, `xmi 0.6.2→0.7.4`,
  `mnconvert 1.87→1.89`, `ferrum 0.17.2→0.18.0`, the metanorma-* patch
  releases, …). Bundler cannot silently drop a still-required edge —
  absence means the newer parents no longer depend on them.
- The `liquid 5.6.0` pin is retained on BOTH lines (5.13.0 resolves
  today; the pin re-applies — parity with the 3.3 line, the original
  justification stands).
- The six source-only natives are unchanged and still source-built per
  line (`brotli 0.8.0`, `ox 2.14.29`, `oga 3.5`, `ruby-ll 2.2.0`,
  `psych 5.2.6`, `websocket-driver 0.8.2`) — the 4.0 line's mkmf rides
  the same SDK preload flow against the 4.0.6 SDK pin.

### 9.2 skip_defaults re-validated against the 4.0.6 runtime

The `skip_defaults` set is shared by both lines; the 4.0 line required
an edge-by-edge re-validation (a skipped default is a promise that the
runtime's bundled copy satisfies every consumer's constraint). The
4.0.6 runtime's default+bundled list (84 gems, captured from the
runtime's own shim — `gem list` on the pressed runtime) satisfies all
49 requires-edges the closure's gems declare onto the skipped defaults
(script-validated against `/info`: every edge's requirement ⊆ the
bundled version, 0 unsatisfied). Notables on the 4.0 line:
`strscan 3.1.6`, `psych 5.3.1` (default), `json 2.18.0`,
`bigdecimal 4.0.1`, `singleton 0.3.0`, `net-ftp 0.3.9`.

The one candidate conflict validates clean: `versionian` (back via the
`ukiryu` root, §9.1) constrains `singleton ~> 0.2` — [0.2, 1.0) — and
the 4.0.6 runtime bundles `singleton 0.3.0`, which satisfies it (the
same reading as the 3.3 line's long-standing skip). No per-line
`pins:`/`skip_defaults:` override is needed today; the escape hatch
shape (per-line blocks under `build.runtime.lines.<line>` merged over
the top-level set) is documented in recipe.yml for future drift —
derive any delta from the line runtime's own `gem list --default`,
never by guess.

`psych` stays in the payload on the 4.0 line even though the runtime's
bundled 5.3.1 would satisfy the constraint: the windows leg's manual
staging flow and the pinned-libyaml build keep the payload
self-contained, identical in shape to the 3.3 line.

### 9.3 The dogfood repair (spec 32 fallout — pre-existing on main)

The dual-line work surfaced that the nightly dogfood was already red on
main (since 2026-09-06): tag 1.16.9-9 added the spec-32 xml2rfc
`kind: executable` edge, so install additionally needs (a) the xml2rfc
provider registry, (b) the python runtime preference, (c) a COMBINED
java+python local mirror (`TEBAKO_RUNTIME_MIRROR` is one base for ALL
engines — the bare java base misdirects the python leg). Reproduced
locally by name (exit 65, "requires executable xml2rfc … no registered
registry carries it"), repaired, rehearsed green in a scratch
TEBAKO_HOME (store: payloads metanorma+inkscape+xml2rfc, runtimes
java+python pre-staged at install).

A second lurking break surfaced at dispatch: pref-less ruby resolution
rides the factory's DEFAULT index line, which lags the recipe pin
(3.3.12-**0.16.18** vs the pinned 0.16.22) — and the lagging driver
predates spec 32, dying on the payload manifest's `kind: executable`
edge (`unknown variant 'executable'`). Fix: every main-leg config pins
`runtimes.ruby` to the recipe pair (`RUBY_V`/`RUNTIME_TEBAKO` from
pins.rb — the collision-free name, see the pins.rb header). Proven
locally: the pref'd dispatch of the published 1.16.9 downloads
`ruby-3.3.12-0.16.22` and runs (`Metanorma::Cli 1.16.9`, rc 0). The
factory default-index lag itself is a tebako-runtime-ruby-side
observation (flagged in the PR); the dogfood must not ride it.

A third lurking break surfaced at COMPILE (the full legs, 2026-09-10):
the spawned java runtime's launcher co-mounts this payload (mn2pdf's
jar lives in its image) and parses its manifest — and the pinned
openjdk line (2.1.5) predates spec 32, dying on the same
`kind: executable` edge (`Jing failed with error: … unknown variant
'executable'`). Masked since 09-06 because install was already failing
(the registry gap above). Fix: `recipe.yml java.tebako` 2.1.5 → **2.4.0**
— the oldest spec-32-era openjdk line, and the LAST temurin-only one:
v2.4.1/v2.5.0 turn manifest.json into a two-flavor list (graalvm
25.0.4.1 first), and the v2.2.0 resolver takes the first platform match
ignoring the `version: "21.0.12"` pref (reproduced locally: the spawn
fetch asked for `tebako-runtime-2.5.0-25.0.4.1-macos-arm64`). The
flavor-mispick is a product-side resolver observation (flagged in the
PR); the pin advances past 2.4.0 only with a CLI that selects by
version. Rehearsed green in the scratch store: pref 2.4.0, the spawn
edge downloaded + cached `java-21.0.12-2.4.0-macos-arm64` at dispatch,
and the fixture compile produced the PDF (mn2pdf + Jing both ran on
the spawned runtime).

The `dogfood-ruby40` job is the 4.0 flavor's slim proof: install
`metanorma@1.16.9-ruby4.0`, run `metanorma version` through the env
link of the version chain, and force the ABI guard — the 4.0 flavor
pinned onto the 3.3-line runtime preference with `TEBAKO_OFFLINE=1`
must fail with spec 28 §8's named error. Proven locally in the mirror
direction (pref 4.0.6 against the ~> 3.3.0 payload): rc 69,
"…a native-extension payload locks to its ABI line…". The guard step
runs BEFORE any 4.0 runtime is cached (a cached COMPATIBLE runtime
silently beats a conflicting pref — resolver semantics observed
locally), with the config riding a save/restore. The job skips loudly
(via the `ruby40-published` gate probing the published registry) until
the first dual-line tag publishes the flavor — the registries it rides
are the published ones, and this wiring lands before that tag by
construction.

### 9.4 Local validation (2026-09-10, macOS arm64)

Both lines built + boot-smoked locally with the recipe-pinned tools
(tebako/tfs/tebako-shim 2.2.0):

| line | gems | natives (all six, source-built) | manifest fill | boot smoke |
|------|------|--------------------------------|---------------|------------|
| 3.3 (default) | 260 | `arm64-darwin-23/3.3.0-static` | `1.16.9` / `~> 3.3.0` | BOOT-SMOKE-OK |
| 4.0 | 261 | `arm64-darwin-23/4.0.0-static` | `1.16.9-ruby4.0` / `~> 4.0.0` | BOOT-SMOKE-OK |

- 3.3 image: `metanorma-1.16.9-macos-arm64.tfs` sha256
  `3ea7f688698fea0fe90a8f574595dd15ecb5ee7796d7db4ab91710c70b401a64`;
  smoke through `ruby-3.3.12-0.16.22` → `Metanorma::Cli 1.16.9`.
- 4.0 image: `metanorma-1.16.9-ruby4.0-macos-arm64.tfs` sha256
  `4a5627e91737b7c3b7fc1a1e38d14030cb9e80e13cfcab4798ac68f03973522c`;
  smoke through `ruby-4.0.6-0.16.22` → `Metanorma::Cli 1.16.9`.
- The declaration-drift guard passed on both lines ("declared commands
  staged and verified against the closure") — after it caught the two
  manifest-contract drops that motivated the resolve_closure roots.
- Skip re-validation: 49 edges onto skipped defaults, 0 unsatisfied
  (§9.2).
- Static gates: `bash -n` all touched shell, `ruby -c` pins.rb + both
  templates, recipe + manifest YAML parse, `actionlint -shellcheck=`
  clean on both workflows, `bundle exec rspec` 7/7.
- The linux + windows 4.0 legs are exercised only in CI (local builds
  are macOS arm64): their closure spellings are `/info`-verified, but
  the windows manual native staging on 4.0 has no local rehearsal.

### 9.5 Side-by-side coexistence (local, 2026-09-10)

Both locally-built flavors installed into one scratch store via
content-addressed file refs (`tebako install file://…tfs?sha256=…` —
the CLI fails closed on a bare file ref, exit 64, demanding the content
address). The install resolved the inkscape + xml2rfc edges from the
published registries and pre-staged the spawned java + python runtimes
through the combined mirror (the §9.3 wiring), identical for both
flavors. With both ruby runtimes cached (3.3.12 + 4.0.6, both 0.16.22)
and each flavor dispatched with the OTHER line's payload AND runtime
physically absent plus `TEBAKO_OFFLINE=1`:

- 4.0 flavor → `Metanorma::Cli 1.16.9`, `Standoc 3.4.10/IsoDoc 3.7.3`,
  `Jis 1.1.6` — on ruby 4.0.6 by exclusion (no 3.3-line runtime
  existed in the process's universe; the ABI guard bars cross-pairing).
- 3.3 flavor → `Metanorma::Cli 1.16.9`, `Standoc 3.4.9/IsoDoc 3.7.0`,
  `Jis 1.1.5` — on ruby 3.3.12 by the same exclusion.

Observed product behavior worth a product-side look (not this repo's):
a `file://` install registers the payload under the artifact FILENAME
rather than the manifest identity, so two same-command flavors collide
at provider selection ("provided by more than one installed payload",
exit 65) before the version chain can apply. The published path is
unaffected — both flavors are versions of the ONE `metanorma` registry
entry, which is exactly what the dogfood-ruby40 leg exercises.
