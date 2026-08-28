defmodule Ankole.Brain.SchemaPacksTest do
  use Ankole.DataCase, async: true

  alias Ankole.Brain.Schemas.SchemaLinkType
  alias Ankole.Brain.Schemas.SchemaPack
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.SchemaPacks

  @vocabulary_path Path.expand("../../../../library/schema-pack/vocabulary.yml", __DIR__)

  describe "seed loading" do
    test "loads every pack seed" do
      for name <- [SchemaPacks.base_pack() | SchemaPacks.industry_packs()] do
        assert {:ok, %{manifest: manifest, content_hash: hash}} = SchemaPacks.load_seed(name)
        assert manifest["name"] == name
        assert is_binary(hash)
      end
    end

    test "rejects unknown pack names" do
      assert {:error, {:unknown_pack, "made-up"}} = SchemaPacks.load_seed("made-up")
    end
  end

  describe "merge validation" do
    test "every pairwise industry combination merges with general" do
      industry = SchemaPacks.industry_packs()

      for a <- industry, b <- industry, a < b do
        assert {:ok, _merged} = SchemaPacks.validate_selection([a, b]),
               "packs #{a} and #{b} must merge"
      end
    end

    test "the full selection merges" do
      assert {:ok, merged} = SchemaPacks.validate_selection(SchemaPacks.industry_packs())

      # product is declared by consumer and software: subtype union.
      product = merged.types["product"]
      assert Enum.sort(product["subtypes"]) == ~w(api app model product_line service sku)

      # thesis is declared identically by pevc and public_markets.
      assert merged.types["thesis"]["slug_prefix"] == "theses/"

      # market_call is declared identically by pevc and public_markets.
      assert merged.calibration_domains["market_call"]["aggregator"] == "scalar_brier"

      # subtype extensions land on general types.
      assert "fund" in merged.types["company"]["subtypes"]
      assert "earnings" in merged.types["event"]["subtypes"]
      assert "release" in merged.types["event"]["subtypes"]
    end
  end

  describe "vocabulary admission" do
    test "no vocabulary term collides with a pack type or subtype name" do
      {:ok, vocabulary} = YamlElixir.read_from_file(@vocabulary_path)

      terms =
        vocabulary
        |> Map.fetch!("sections")
        |> Enum.flat_map(fn section -> Enum.map(section["entries"], & &1["term"]) end)

      assert {:ok, merged} = SchemaPacks.validate_selection(SchemaPacks.industry_packs())

      declared =
        merged.types
        |> Map.values()
        |> Enum.flat_map(fn type -> [type["name"] | type["subtypes"]] end)
        |> MapSet.new()

      collisions = Enum.filter(terms, &MapSet.member?(declared, &1))

      assert collisions == [],
             "vocabulary terms shadowed by pack declarations: #{inspect(collisions)}"
    end
  end

  describe "installation" do
    test "installs general with a selection and materializes rows" do
      assert {:ok, result} = SchemaPacks.install_packs(["pevc"])
      assert result.installed == ["general", "pevc"]

      pack_names = Repo.all(SchemaPack) |> Enum.map(& &1.name) |> Enum.sort()
      assert pack_names == ["general", "pevc"]

      types = Repo.all(SchemaType) |> Map.new(&{&1.name, &1})
      assert types["person"].expert_routing
      assert types["deal"].pack_name == "pevc"
      assert types["note"].primitive == "concept"

      assert %SchemaType{
               primitive: "concept",
               slug_prefix: "lazyload-agent-skills/",
               subtypes: [],
               extractable: false,
               expert_routing: false,
               pack_name: "general"
             } = types["agent-skills"]

      assert Repo.get_by!(SchemaPack, name: "general").version == "1.1.0"
      assert "fund" in types["company"].subtypes

      links = Repo.all(SchemaLinkType) |> Map.new(&{&1.name, &1})
      assert links["part_of"].inverse == "has_part"
      assert links["invested_in"].pack_name == "pevc"
    end

    test "add-on installation validates against installed packs and widens subtypes" do
      assert {:ok, _result} = SchemaPacks.install_packs(["consumer"])
      assert {:ok, result} = SchemaPacks.install_packs(["software"])
      assert result.installed == ["software"]

      types = Repo.all(SchemaType) |> Map.new(&{&1.name, &1})
      assert Enum.sort(types["product"].subtypes) == ~w(api app model product_line service sku)
      # First declaring installed pack keeps ownership.
      assert types["product"].pack_name == "consumer"
    end

    test "repeated installation of the same selection converges" do
      assert {:ok, _result} = SchemaPacks.install_packs([])
      assert {:ok, %{status: :already_installed}} = SchemaPacks.install_packs([])
    end
  end
end
