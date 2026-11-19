# The closure resolution Gemfile — the ONE template both resolution paths
# render from: tools/resolve_closure (the maintainer's manual regen) and
# .github/workflows/release-monitor.yml (the automated roll's regen). The
# __VERSION__ placeholder is substituted by the caller (never edited in
# place — SSOT, spec 00 §10).
source "https://rubygems.org"

gem "metanorma-cli", "__VERSION__"

# Manifest-contract roots (the closure serves the manifest's declared
# commands): the current metanorma-cli graph no longer reaches these
# gems, but manifests/payload.yaml declares their commands — root them
# explicitly so declared providers never silently drop out of a fresh
# resolution (the 4.0-line fresh resolution dropped both;
# tools/build's declaration-drift guard caught them).
gem "lutaml-xsd"
gem "ukiryu"   # inactive-but-declared; its git ~> 3.0 pin is also WHY the
               # published 3.3 closure ships git 3.1.1 — parity, not drift

# fontisan pinned BELOW 0.4.48: that version added a Rust native tier
# (Phase 2, fontist/fontisan#162) whose source build needs cargo on the
# consumer — our audience law forbids compilation machinery, and the ucrt
# windows leg's build dies on it (the msys2 setup carries no Rust).
# Upstream's own direction (fontist/fontisan#173) is precompiled platform
# gems for every arch; this pin rides until those ship, then unpin.
gem "fontisan", "< 0.4.48"
