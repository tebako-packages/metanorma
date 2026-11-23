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

# lutaml#246 (https://github.com/lutaml/lutaml/issues/246): lutaml-lml 0.3.7
# pulls in bare lutaml, whose leptris fast path (plan_hydrator) passes a
# PARSED element to custom-method deserializers instead of the raw XML
# string the interpretive path has always passed — isodoc's
# bibdata_from_xml → Relaton::Cli.parse_xml → Moxml::Context#parse then
# dies `.read` on a Nokogiri::XML::Document, and every HTML compile fails
# (the 20261121 roll's dogfood, reproduced and reported upstream with the
# minimal case). Hold the line at the last working resolution until the
# upstream fix ships; REMOVE THIS CAP when lutaml#246 is released.
gem "lutaml-lml", "< 0.3.7"
gem "ukiryu"   # inactive-but-declared; its git ~> 3.0 pin is also WHY the
               # published 3.3 closure ships git 3.1.1 — parity, not drift
