# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The tool is a driver-entry script whose main is guarded by
# __FILE__ == $PROGRAM_NAME: loading it here defines VendorSiblings
# without running the entrypoint.
load File.expand_path("../tools/vendor_siblings.rb", __dir__)

RSpec.describe VendorSiblings do
  # the real in-image shape (closure pin: libpng-1.6.58.6-x64-mingw-ucrt)
  IMPORTER_REL = "lib/ruby/gems/3.3.0/gems/libpng-1.6.58.6-x64-mingw-ucrt/lib/libpng"

  let(:payload) { Dir.mktmpdir("payload") }
  let(:toolchain) { Dir.mktmpdir("toolchain") }
  let(:src_dirs) { [File.join(toolchain, "bin")] }

  after do
    FileUtils.remove_entry(payload)
    FileUtils.remove_entry(toolchain)
  end

  def plant_importer(rel_dir = IMPORTER_REL)
    dir = File.join(payload, rel_dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "libpng16.dll"), "fake-libpng16")
    dir
  end

  def plant_source(content = "fake-zlib1")
    bin = File.join(toolchain, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "zlib1.dll"), content)
  end

  it "vendors the sibling next to the importer (happy path)" do
    dir = plant_importer
    plant_source
    described_class.run(payload, src_dirs)
    expect(File.read(File.join(dir, "zlib1.dll"))).to eq("fake-zlib1")
  end

  it "vendors next to every instance of the importer" do
    dirs = [plant_importer, plant_importer("lib/ruby/gems/3.3.0/gems/libpng-9.9.9-x64-mingw-ucrt/lib/libpng")]
    plant_source
    described_class.run(payload, src_dirs)
    dirs.each do |dir|
      expect(File.read(File.join(dir, "zlib1.dll"))).to eq("fake-zlib1")
    end
  end

  it "is a no-op when the sibling is already next to the importer" do
    dir = plant_importer
    File.write(File.join(dir, "zlib1.dll"), "already-here")
    plant_source("would-overwrite")
    described_class.run(payload, src_dirs)
    expect(File.read(File.join(dir, "zlib1.dll"))).to eq("already-here")
  end

  it "fails closed (named error) when the sibling cannot be sourced" do
    plant_importer
    FileUtils.mkdir_p(File.join(toolchain, "bin")) # source dir exists but carries no zlib1.dll
    expect { described_class.run(payload, src_dirs) }
      .to raise_error(VendorSiblings::Error, /zlib1\.dll.*present in none of/)
    expect(Dir.glob(File.join(payload, "**", "zlib1.dll"))).to be_empty
  end

  it "is a no-op when no libpng16.dll is in the tree" do
    described_class.run(payload, src_dirs)
    expect(Dir.glob(File.join(payload, "**", "zlib1.dll"))).to be_empty
  end

  describe ".default_src_dirs" do
    around do |example|
      saved = ENV.to_h.slice("VENDOR_DLL_SRC", "MSYSTEM_PREFIX")
      ENV.delete("VENDOR_DLL_SRC")
      ENV.delete("MSYSTEM_PREFIX")
      example.run
      ENV.delete("VENDOR_DLL_SRC")
      ENV.delete("MSYSTEM_PREFIX")
      saved.each { |k, v| ENV[k] = v }
    end

    it "searches VENDOR_DLL_SRC, then MSYSTEM_PREFIX/bin, then RbConfig bindir" do
      ENV["VENDOR_DLL_SRC"] = "/explicit/src"
      ENV["MSYSTEM_PREFIX"] = "/ucrt64"
      expect(described_class.default_src_dirs)
        .to eq(["/explicit/src", "/ucrt64/bin", RbConfig::CONFIG["bindir"]])
    end

    it "falls back to RbConfig's bindir when no env source is set" do
      expect(described_class.default_src_dirs).to eq([RbConfig::CONFIG["bindir"]])
    end
  end
end
