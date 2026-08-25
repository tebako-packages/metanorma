# Runs INSIDE the tebako runtime ruby (the windows leg's driver entry —
# never the host ruby), AFTER tools/build has assembled the payload tree.
# Vendors DLL siblings next to the gem-vendored DLLs that import them.
#
# Why: the tfs PE closure walk (spec 22 §2.1) resolves a non-system,
# non-runtime DLL import IMPORTER-DIR-RELATIVE. The libpng gem's
# x64-mingw-ucrt package vendors libpng16.dll (its ruby side loads it by
# full path via `ffi_lib File.expand_path(...)`) but NOT zlib1.dll, which
# libpng16.dll imports and which is vendored nowhere in the payload and is
# not a Windows system DLL — every PNG embed died LoadError 126
# (packed-mn#251 windows-ucrt leg, class 2; class 1 — libwinpthread-1.dll
# on the source-built .so set — is the runtime factory's fix,
# tebako-runtime-ruby#133). The fix is payload-side by design: zlib1.dll
# is gem-peculiar, not toolchain runtime, so the importer's gem dir is its
# one owner and the runtime stays free of gem-specific hacks.
#
# The step is keyed by an explicit map (importer basename => the sibling
# DLLs it needs beside it) so a future importer is one map entry, not a
# code path. FAIL CLOSED: an importer present with no source for a sibling
# is a named error (non-zero exit) — never a silently broken payload.
#
# ENV in:  PAYLOAD_DIR      assembled payload tree (host path)
#          VENDOR_DLL_SRC   extra source dir for siblings, first in search
#                          order (tools/build passes the msys2 toolchain
#                          bin, windows form; optional)
require "fileutils"
require "rbconfig"

module VendorSiblings
  # importer basename => the sibling DLL basenames it needs beside it
  IMPORTER_SIBLINGS = { "libpng16.dll" => %w[zlib1.dll] }.freeze

  # the named fail-closed error: an importer was found but a sibling it
  # needs could not be sourced from any search dir
  class Error < StandardError; end

  # Source dirs in search order: the explicit VENDOR_DLL_SRC, the msys2
  # toolchain prefix bin (MSYSTEM_PREFIX), then this ruby's own bindir
  # (the RbConfig fallback — an msys2 ruby's bindir IS the toolchain bin).
  def self.default_src_dirs
    dirs = []
    dirs << ENV["VENDOR_DLL_SRC"] unless ENV["VENDOR_DLL_SRC"].to_s.empty?
    dirs << File.join(ENV["MSYSTEM_PREFIX"], "bin") unless ENV["MSYSTEM_PREFIX"].to_s.empty?
    dirs << RbConfig::CONFIG["bindir"]
    dirs
  end

  # Vendor each mapped sibling next to every instance of its importer under
  # payload_dir. No importers found -> the step is a no-op.
  def self.run(payload_dir, src_dirs)
    IMPORTER_SIBLINGS.each do |importer, siblings|
      found = Dir.glob(File.join(payload_dir, "**", importer)).sort
      if found.empty?
        puts "#{importer}: none under #{payload_dir} — nothing to vendor"
        next
      end
      found.each do |importer_path|
        siblings.each { |sibling| vendor_sibling(sibling, File.dirname(importer_path), src_dirs) }
      end
    end
  end

  def self.vendor_sibling(sibling, dir, src_dirs)
    dst = File.join(dir, sibling)
    if File.exist?(dst)
      puts "#{sibling}: already vendored next to #{dir} — no-op"
      return
    end
    src = src_dirs.map { |d| File.join(d, sibling) }.find { |p| File.file?(p) }
    unless src
      searched = src_dirs.empty? ? "(no source dirs)" : src_dirs.join(", ")
      raise Error, "#{sibling} required next to #{dir} but present in none of: #{searched}"
    end
    FileUtils.cp(src, dst)
    puts "vendored #{src} -> #{dst}"
  end
end

if __FILE__ == $PROGRAM_NAME
  VendorSiblings.run(ENV.fetch("PAYLOAD_DIR"), VendorSiblings.default_src_dirs)
end
