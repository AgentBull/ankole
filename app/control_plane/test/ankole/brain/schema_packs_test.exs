defmodule Ankole.Brain.SchemaPacksTest do
  use Ankole.DataCase, async: true

  alias Ankole.Brain.Schemas.SchemaLinkType
  alias Ankole.Brain.Schemas.SchemaPack
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.SchemaPacks

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

      assert Repo.get_by!(SchemaPack, name: "general").version == "1.1.1"
      assert types["agent"].subtypes == ["internal"]
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

    test "an installed pack cannot widen the reserved Agent type" do
      assert {:ok, _result} = SchemaPacks.install_packs([])
      pack = Repo.get_by!(SchemaPack, name: "general")

      manifest =
        Map.put(pack.manifest, "subtype_extensions", [
          %{"type" => "agent", "add" => ["external"]}
        ])

      Repo.update!(Ecto.Changeset.change(pack, manifest: manifest))
      assert {:error, {:reserved_object_type, "agent"}} = SchemaPacks.install_packs(["software"])
      refute Repo.get_by(SchemaPack, name: "software")
    end
  end
end
