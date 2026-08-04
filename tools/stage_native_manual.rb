# Runs INSIDE the tebako runtime ruby (the windows leg's driver entry —
# never the host ruby). Builds and installs ONE source-only native gem
# WITHOUT rubygems' ExtConfBuilder: that builder spawns Gem.ruby as a
# subprocess, and on Windows there is no ruby shim and no memfs spawn
# (tebako-cli deploy.rs + the ruby spawn patch are POSIX-only), so
# `gem install` of a source-native gem cannot work there. Instead:
#
#   extconf  phase: unpack the gem, run its extconf.rb IN-PROCESS (mkmf
#                   only shells out to the C toolchain, never to ruby).
#                   `$0` is pinned to "extconf.rb" — mkmf anchors srcdir
#                   and the Makefile's TARGET on it (a plain `load` with
#                   a foreign $0 yields an empty TARGET).
#   place    phase: after the host ran make, install the built .so the
#                   way rubygems would: gem tree copy (lib/<target>.so),
#                   extensions bookkeeping dir
#                   (<platform>/<api>/<full_name>/<target>.so +
#                   gem.build_complete), and the installed-spec stub
#                   (spec.to_ruby — specifications/*.gemspec are ruby,
#                   not yaml).
#
# ENV in:  NATIVE_GEM    sha256-verified .gem file (host path)
#          NATIVE_EXTDIR extconf.rb's dir inside the unpacked gem (ext/...)
#          NATIVE_TARGET create_makefile's target (e.g. brotli/brotli,
#                        liboga) — fixes the .so's lib-relative path
#          NATIVE_ARGS   extconf argv, space-separated (extconf phase only;
#                        e.g. --enable-vendor, psych's dir_config flags)
#          NATIVE_BUILD  build workspace (host path)
#          STAGE_DIR     staging GEM_HOME (host path)
require "fileutils"
require "rubygems/package"

PHASE = ARGV.fetch(0)
GEM_FILE = ENV.fetch("NATIVE_GEM")
EXT_DIR = ENV.fetch("NATIVE_EXTDIR")
TARGET = ENV.fetch("NATIVE_TARGET")
BUILD_DIR = ENV.fetch("NATIVE_BUILD")
STAGE_DIR = ENV.fetch("STAGE_DIR")

spec = Gem::Package.new(GEM_FILE).spec
full_name = spec.full_name # e.g. brotli-0.8.0
so_name = File.basename(TARGET) # the make product: <so_name>.<DLEXT>

case PHASE
when "extconf"
  FileUtils.rm_rf(BUILD_DIR)
  FileUtils.mkdir_p(BUILD_DIR)
  Gem::Package.new(GEM_FILE).extract_files(BUILD_DIR)
  ext_dir = File.join(BUILD_DIR, EXT_DIR)
  Dir.chdir(ext_dir) do
    $0 = "extconf.rb"
    ARGV.replace(ENV.fetch("NATIVE_ARGS", "").split(" "))
    load "extconf.rb"
  end
  puts "EXTCONF-OK #{File.join(ext_dir, 'Makefile')}"
when "place"
  soext = RbConfig::CONFIG["DLEXT"]
  ext_dir = File.join(BUILD_DIR, EXT_DIR)
  built = File.join(ext_dir, "#{so_name}.#{soext}")
  raise "no built extension at #{built}" unless File.file?(built)

  gem_dir = File.join(STAGE_DIR, "gems", full_name)
  # the gem's files as installed (same as a rubygems install layout)
  FileUtils.rm_rf(gem_dir)
  Gem::Package.new(GEM_FILE).extract_files(gem_dir)
  lib_dest = File.join(gem_dir, "lib", "#{TARGET}.#{soext}")
  FileUtils.mkdir_p(File.dirname(lib_dest))
  FileUtils.cp(built, lib_dest)

  # the extensions bookkeeping tree (rubygems' installed layout: the
  # platform segment is Gem::Platform.local, NOT RbConfig's arch)
  ext_book = File.join(STAGE_DIR, "extensions",
                       Gem::Platform.local.to_s, Gem.extension_api_version,
                       full_name)
  book_dest = File.join(ext_book, "#{TARGET}.#{soext}")
  FileUtils.mkdir_p(File.dirname(book_dest))
  FileUtils.cp(built, book_dest)
  File.write(File.join(ext_book, "gem.build_complete"), "")
  mkmf_log = File.join(ext_dir, "mkmf.log")
  FileUtils.cp(mkmf_log, File.join(ext_book, "mkmf.log")) if File.file?(mkmf_log)

  spec_dir = File.join(STAGE_DIR, "specifications")
  FileUtils.mkdir_p(spec_dir)
  File.write(File.join(spec_dir, "#{full_name}.gemspec"), spec.to_ruby)
  puts "PLACE-OK #{gem_dir}"
else
  raise "usage: stage_native_manual.rb {extconf|place}"
end
