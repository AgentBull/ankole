defmodule Ankole.Brain.SchemaPacksTest do
  use Ankole.DataCase, async: true
  import Ecto.Query

  alias Ankole.Brain.Schemas.SchemaLinkType
  alias Ankole.Brain.Schemas.SchemaPack
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.SchemaPacks

  describe "seed loading" do
    test "loads every pack seed" do
      for name <- SchemaPacks.default_packs() ++ SchemaPacks.industry_packs() do
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
      assert result.installed == ["general", "data", "pevc"]

      pack_names = Repo.all(SchemaPack) |> Enum.map(& &1.name) |> Enum.sort()
      assert pack_names == ["data", "general", "pevc"]

      types = Repo.all(SchemaType) |> Map.new(&{&1.name, &1})
      assert types["person"].expert_routing
      assert types["deal"].pack_name == "pevc"
      assert types["note"].primitive == "concept"

      refute Map.has_key?(types, "agent-skills")

      assert Repo.get_by!(SchemaPack, name: "general").version == "1.1.2"
      assert types["agent"].subtypes == ["internal"]
      assert "fund" in types["company"].subtypes

      assert types["dataset"].slug_prefix == "datasets/"
      assert types["metric"].pack_name == "data"

      links = Repo.all(SchemaLinkType) |> Map.new(&{&1.name, &1})
      assert links["part_of"].inverse == "has_part"
      assert links["measures"].inverse == "measured_by"
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

    test "the default pack job installs a default pack that a workspace predates" do
      assert {:ok, _result} = SchemaPacks.install_packs(["legal"])

      for schema <- [SchemaType, SchemaLinkType, SchemaPack] do
        field = if schema == SchemaPack, do: :name, else: :pack_name
        Repo.delete_all(from(row in schema, where: field(row, ^field) == "data"))
      end

      assert :ok = perform_job(Ankole.Brain.Jobs.InstallDefaultPacks, %{})
      assert Repo.get_by!(SchemaType, name: "metric").pack_name == "data"
      assert Repo.get_by!(SchemaLinkType, name: "joins_to").inverse == "joins_to"
      assert :ok = perform_job(Ankole.Brain.Jobs.InstallDefaultPacks, %{})
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
