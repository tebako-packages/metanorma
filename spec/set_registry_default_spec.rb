# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"

# The tool is a driver-entry script whose main is guarded by
# __FILE__ == $PROGRAM_NAME: loading it here defines SetRegistryDefault
# without running the entrypoint.
load File.expand_path("../tools/set_registry_default.rb", __dir__)

RSpec.describe SetRegistryDefault do
  let(:dir) { Dir.mktmpdir("registry") }
  let(:path) { File.join(dir, "tpkg-registry.yaml") }

  after { FileUtils.remove_entry(dir) }

  def write_registry(entries)
    File.write(path, { "schema_version" => 1, "payloads" => entries }.to_yaml)
  end

  def entry(name = "metanorma")
    YAML.load_file(path)["payloads"].find { |p| p["name"] == name }
  end

  # the multi-line shape a tag publish leaves behind: the older line, the
  # just-published default-line row, and its ruby-suffixed sibling
  let(:rows) do
    [
      { "version" => "1.17.0", "platforms" => "universal" },
      { "version" => "1.18.6", "platforms" => "universal" },
      { "version" => "1.18.6-ruby3.3", "platforms" => "universal" },
    ]
  end

  it "moves an existing default to the just-published version (issue #144)" do
    write_registry([{ "name" => "metanorma", "kind" => "app",
                      "versions" => rows, "default" => "1.17.0" }])
    expect(described_class.run(path, "metanorma", "1.18.6")).to be(true)
    expect(entry["default"]).to eq("1.18.6")
  end

  it "never touches versions: — the multi-line accumulation is the CLI upsert's territory" do
    write_registry([{ "name" => "metanorma", "kind" => "app",
                      "versions" => rows, "default" => "1.17.0" }])
    described_class.run(path, "metanorma", "1.18.6")
    expect(entry["versions"].map { |v| v["version"] })
      .to eq(["1.17.0", "1.18.6", "1.18.6-ruby3.3"])
  end

  it "is an idempotent no-op when the default already names the version (a re-run of the same tag)" do
    write_registry([{ "name" => "metanorma", "kind" => "app",
                      "versions" => rows, "default" => "1.18.6" }])
    before = File.read(path)
    expect(described_class.run(path, "metanorma", "1.18.6")).to be(false)
    expect(File.read(path)).to eq(before)
  end

  it "sets an absent default (the floor case: an entry carried without one)" do
    write_registry([{ "name" => "metanorma", "kind" => "app", "versions" => rows }])
    expect(described_class.run(path, "metanorma", "1.18.6")).to be(true)
    expect(entry["default"]).to eq("1.18.6")
  end

  it "fails named when the payload entry is unknown — the publish loop must have upserted it" do
    write_registry([{ "name" => "other", "kind" => "app", "versions" => rows }])
    expect { described_class.run(path, "metanorma", "1.18.6") }
      .to raise_error(SetRegistryDefault::Error, /no payloads entry named metanorma/)
  end

  it "fails named when the version is not a carried row — default never names an absent row" do
    write_registry([{ "name" => "metanorma", "kind" => "app",
                      "versions" => rows, "default" => "1.17.0" }])
    expect { described_class.run(path, "metanorma", "9.9.9") }
      .to raise_error(SetRegistryDefault::Error, /carries no 9\.9\.9 row/)
    expect(entry["default"]).to eq("1.17.0")
  end

  it "leaves the mirrored sibling entries (spawned runtimes, requires-closure payloads) alone" do
    write_registry([
      { "name" => "metanorma", "kind" => "app",
        "versions" => rows, "default" => "1.17.0" },
      { "name" => "inkscape", "kind" => "app",
        "versions" => [{ "version" => "1.4.3" }], "default" => "1.4.3" },
    ])
    described_class.run(path, "metanorma", "1.18.6")
    expect(entry("inkscape")["default"]).to eq("1.4.3")
  end
end
