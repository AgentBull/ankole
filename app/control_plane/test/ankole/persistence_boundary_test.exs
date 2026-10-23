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
        repo.update_all(from(s in Signal, where: s.id == ^1), set: [status: :queued])
        Tenant |> Ash.Query.filter(id == ^1) |> Ankole.Ash.read()
        Signal |> Ash.Query.filter(id == ^1) |> Ankole.Ash.read()
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

    path = "../control_plane_core/lib/ankole/signals/probe.ex"
    found = source |> Code.string_to_quoted!() |> PersistenceBoundary.occurrences(path)

    assert crossings({path, found}, resources) |> Enum.frequencies() == %{
             "repo_transact:#{path}" => 1,
             "ecto_write:#{path}" => 1,
             "ecto_lock:#{path}" => 1,
             "raw_sql_tenant:#{path}" => 1,
             "bulk_result:#{path}" => 1,
             "error_class:#{path}" => 1,
             "ecto_resource:#{path}" => 2,
             "cross_domain_ash:#{path}" => 1
           }

    consumer = "../control_plane_core/lib/ankole_web/controllers/probe_controller.ex"
    found = source |> Code.string_to_quoted!() |> PersistenceBoundary.occurrences(consumer)
    kinds = crossings({consumer, found}, resources) |> Enum.frequencies()
    assert kinds["consumer_ash:#{consumer}"] == 5
    refute Map.has_key?(kinds, "cross_domain_ash:#{consumer}")
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
    case Regex.run(~r{/lib/ankole/([^/.]+)}, path) do
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
       "../control_plane_core/lib/**/*.ex",
       "../../plugins/*/lib/**/*.ex",
       "../../libs/im_transport/lib/**/*.ex",
       "../../libs/feishu_protocol/lib/**/*.ex"
     ] ++ edition)
    |> Enum.flat_map(&Path.wildcard/1)
  end
end
