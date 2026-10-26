Code.require_file("../../credo/persistence_boundary.ex", __DIR__)

defmodule Ankole.PersistenceBoundaryTest do
  @moduledoc """
  Checks the persistence boundary with the compiled resources.

  An Ecto query of an Ash resource (`ecto_resource`) and an Ash call on the
  resource of another domain (`cross_domain_ash`) need the compiled modules,
  so only this test counts them. The Credo checks count the other kinds with
  the same scanner and the same data file.
  """
  # The scan loads every application module, so it runs alone.
  use ExUnit.Case, async: false

  alias Ankole.Credo.PersistenceBoundary

  @exception_modules PersistenceBoundary.data().exceptions
  @usage [:persistence, :ecto_write, :ecto_lock, :ecto_source, :repo_transact, :raw_sql_tenant]

  setup_all do
    resources =
      for module <- Ankole.TestModules.all(),
          Code.ensure_loaded?(module),
          Spark.Dsl.is?(module, Ash.Resource),
          into: MapSet.new(),
          do: module

    %{resources: resources}
  end

  test "only the registered exceptions cross the persistence boundary", %{
    resources: resources
  } do
    actual = occurrences() |> Enum.flat_map(&crossings(&1, resources)) |> Enum.frequencies()

    assert actual == %{},
           "Move each crossing to its owner or register its module in " <>
             "test/ankole/persistence_boundary.exs ({kind:path, count}): " <>
             inspect(Enum.sort(actual), limit: :infinity)
  end

  test "each registered exception still uses the database directly" do
    occurrences = occurrences() |> Map.values() |> List.flatten()

    stale =
      for {entry, pattern} <- @exception_modules,
          not Enum.any?(occurrences, &(&1.kind in @usage and covers?(entry, &1))),
          do: {entry, pattern}

    assert stale == [], "Remove the stale exceptions: #{inspect(stale)}"
  end

  test "tenant-schema raw SQL requires its declaration and the context-derived helper" do
    for {declaration, table, expected} <- [
          {"", "BaseRepo.table(id)", 1},
          {"@raw_sql_scope :tenant_schema", ~s("other_tenant.records"), 1},
          {"@raw_sql_scope :tenant_schema", "BaseRepo.table(id)", 0}
        ] do
      source = """
      defmodule Ankole.Pod.Probe do
        alias Ankole.Pod.BaseRepo
        #{declaration}
        def read(id), do: BaseRepo.query!("SELECT * FROM \#{#{table}}", [])
      end
      """

      found =
        source
        |> Code.string_to_quoted!()
        |> PersistenceBoundary.occurrences("lib/ankole/pod/probe.ex")

      assert Enum.count(found, &(&1.kind == :raw_sql_tenant)) == expected
    end
  end

  test "one scoped statement cannot exempt other SQL in the module" do
    source = ~S'''
    defmodule Ankole.Pod.Probe do
      alias Ankole.Pod.BaseRepo
      alias Ankole.Pod.Query
      @raw_sql_scope :tenant_schema
      def read(id) do
        table = BaseRepo.table(id)
        BaseRepo.query!("SELECT * FROM #{table}", [])
        BaseRepo.query!("SELECT * FROM other_tenant.records", [])
        Ankole.Repo.query!("SELECT * FROM base_records", [])
        Query.execute(%{}, "SELECT * FROM base_records", [])
      end
      def other, do: BaseRepo.query!("SELECT * FROM other_tenant.records", [])
    end
    '''

    found =
      source
      |> Code.string_to_quoted!()
      |> PersistenceBoundary.occurrences("lib/ankole/pod/probe.ex")

    assert Enum.count(found, &(&1.kind == :raw_sql_tenant)) == 4
  end

  test "the scanner classifies crossings by owner and by compiled resource", %{
    resources: resources
  } do
    source = """
    defmodule Ankole.Signals.Probe do
      alias Ankole.Repo
      alias Ankole.Signals.Signal
      alias Ankole.Tenants.Tenant

      def run(repo) do
        Repo.transact(fn -> :ok end)
        Repo.transact_top_level(fn -> {:ok, :done} end)
        repo.update_all(from(s in Signal, where: s.id == ^1), set: [status: :queued])
        Tenant |> Ash.Query.filter(id == ^1) |> Ankole.Ash.read()
        Signal |> Ash.Query.filter(id == ^1) |> Ankole.Ash.read()
        Ash.read!(Signal)
        Repo.one(from(s in Signal, lock: "FOR UPDATE"))
        Ankole.Tenants.get_tenant!(1, query: [lock: "FOR KEY SHARE"])
        Repo.query!("SELECT * FROM signals")
        Repo.query!("SELECT clock_timestamp()")
        case result do
          %Ash.BulkResult{} -> Ash.Error.to_error_class(:x)
        end
      end
    end
    """

    for path <- ["lib/ankole/signals/probe.ex", Path.expand("lib/ankole/signals/probe.ex")] do
      found = source |> Code.string_to_quoted!() |> PersistenceBoundary.occurrences(path)

      assert crossings({path, found}, resources) |> Enum.frequencies() == %{
               "repo_transact:#{path}" => 1,
               "ecto_write:#{path}" => 1,
               "ecto_lock:#{path}" => 1,
               "raw_sql_tenant:#{path}" => 1,
               "bulk_result:#{path}" => 1,
               "error_class:#{path}" => 1,
               "ash_direct:#{path}" => 1,
               "ecto_resource:#{path}" => 2,
               "cross_domain_ash:#{path}" => 1
             }
    end

    for path <-
          [
            "lib/ankole_web/controllers/probe_controller.ex",
            "../../plugins/probe/lib/probe.ex",
            "../../internals/plugins/probe/lib/probe.ex",
            "lib/mix/tasks/probe.ex"
          ] ++
            Enum.map(
              ~w(application credential_upgrade migrations release upgrade_202610),
              &"lib/ankole/#{&1}.ex"
            ),
        consumer <- [path, Path.expand(path)] do
      found = source |> Code.string_to_quoted!() |> PersistenceBoundary.occurrences(consumer)
      kinds = crossings({consumer, found}, resources) |> Enum.frequencies()
      assert kinds["consumer_ash:#{consumer}"] == 6
      assert kinds["repo_transact:#{consumer}"] == 2
      refute Map.has_key?(kinds, "cross_domain_ash:#{consumer}")
    end
  end

  test "framework owners keep their error and action implementations" do
    source = """
    defmodule Ankole.Probe do
      def run do
        %Ash.BulkResult{}
        Ash.Error.to_error_class(:invalid)
        Ash.read!(Ankole.Tenants.Tenant)
        Ash.Changeset.before_transaction(changeset, callback)
      end
    end
    """

    for path <- [
          "lib/ankole/ash.ex",
          "lib/ankole/ash/probe.ex",
          "lib/ankole/errors.ex",
          "lib/ankole/errors/probe.ex",
          "lib/ankole_web/console_errors.ex"
        ],
        path <- [path, Path.expand(path)] do
      found = source |> Code.string_to_quoted!() |> PersistenceBoundary.occurrences(path)
      assert Enum.filter(found, &(&1.kind in PersistenceBoundary.enforced_kinds())) == []
    end
  end

  defp occurrences do
    Map.new(source_files(), fn path ->
      {path,
       path |> File.read!() |> Code.string_to_quoted!() |> PersistenceBoundary.occurrences(path)}
    end)
  end

  defp crossings({path, occurrences}, resources) do
    occurrences
    |> Enum.reject(&PersistenceBoundary.exempt?(&1, @exception_modules))
    |> Enum.flat_map(fn occurrence ->
      case kind(occurrence, path, resources) do
        nil -> []
        kind -> [PersistenceBoundary.key(kind, path)]
      end
    end)
  end

  defp kind(%{kind: :ecto_source, target: target}, _path, resources),
    do: if(MapSet.member?(resources, target), do: :ecto_resource)

  defp kind(%{kind: :ash_call, target: target}, path, resources) do
    if MapSet.member?(resources, target) and resource_owner(target) != owner(path),
      do: :cross_domain_ash
  end

  defp kind(%{kind: kind}, _path, _resources) do
    if kind in PersistenceBoundary.enforced_kinds(), do: kind
  end

  defp covers?(module, %{module: module}) when is_atom(module), do: true

  defp covers?({module, functions}, %{module: module, function: function}),
    do: function in functions

  defp covers?(_entry, _occurrence), do: false

  defp resource_owner(resource) do
    resource
    |> Ash.Resource.Info.domain()
    |> then(& &1.module_info(:compile)[:source])
    |> to_string()
    |> owner()
  end

  # The owner of a file is the domain directory or root module under lib/ankole.
  defp owner(path) do
    case Regex.run(~r{/lib/ankole/([^/.]+)}, Path.expand(path)) do
      [_match, owner] -> owner
      nil -> nil
    end
  end

  defp source_files do
    edition =
      if Application.get_env(:ankole, :edition) == :saas,
        do: ["../../internals/control_plane/lib/**/*.ex", "../../internals/plugins/*/lib/**/*.ex"],
        else: []

    ([
       "lib/**/*.ex",
       "../../plugins/*/lib/**/*.ex",
       "../../libs/im_transport/lib/**/*.ex",
       "../../libs/feishu_protocol/lib/**/*.ex"
     ] ++ edition)
    |> Enum.flat_map(&Path.wildcard/1)
  end
end
