defmodule Discord.SourceSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children =
      [
        {Registry, keys: :unique, name: Discord.Registry}
        | Enum.map(Discord.Source.enabled_sources!(), &Discord.SourceRuntime.child_spec/1)
      ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec runtime_status() :: {:ok, map()} | {:error, :not_running | term()}
  def runtime_status do
    with {:ok, sources} <- Discord.Source.enabled_sources(),
         {:ok, children} <- children() do
      ready_child_ids = source_child_ids(children)

      {:ok,
       %{
         ready?:
           Enum.all?(
             sources,
             &MapSet.member?(ready_child_ids, Discord.SourceRuntime.child_id(&1))
           ),
         sources:
           Enum.map(sources, fn source ->
             %{
               id: source.id,
               enabled: true,
               ready: MapSet.member?(ready_child_ids, Discord.SourceRuntime.child_id(source)),
               transport: if(source.start_transport?, do: "gateway", else: "disabled")
             }
           end)
       }}
    end
  end

  @spec reconcile_sources() :: {:ok, map()} | {:error, :not_running | term()}
  def reconcile_sources do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         {:ok, sources} <- Discord.Source.enabled_sources(),
         :ok <- stop_retired_children(pid, sources),
         :ok <- start_missing_children(pid, sources),
         {:ok, status} <- runtime_status() do
      {:ok, status}
    else
      nil -> {:error, :not_running}
      {:error, reason} -> {:error, reason}
    end
  end

  defp children do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> {:ok, Supervisor.which_children(pid)}
    end
  end

  defp source_child_ids(children) do
    children
    |> Enum.flat_map(fn
      {child_id, pid, _type, _modules} when is_pid(pid) ->
        case source_id_from_child_id(child_id) do
          nil -> []
          _id -> [child_id]
        end

      _child ->
        []
    end)
    |> MapSet.new()
  end

  defp stop_retired_children(pid, sources) do
    wanted_ids = MapSet.new(sources, & &1.id)
    wanted_child_ids = MapSet.new(sources, &Discord.SourceRuntime.child_id/1)

    pid
    |> Supervisor.which_children()
    |> Enum.reduce_while(:ok, fn
      {child_id, _child_pid, _type, _modules}, :ok ->
        case retired_child?(child_id, wanted_ids, wanted_child_ids) do
          true ->
            _ = Supervisor.terminate_child(pid, child_id)
            _ = Supervisor.delete_child(pid, child_id)
            {:cont, :ok}

          false ->
            {:cont, :ok}
        end
    end)
  end

  defp start_missing_children(pid, sources) do
    existing_child_ids =
      pid
      |> Supervisor.which_children()
      |> source_child_ids()

    Enum.reduce_while(sources, :ok, fn source, :ok ->
      case MapSet.member?(existing_child_ids, Discord.SourceRuntime.child_id(source)) do
        true ->
          {:cont, :ok}

        false ->
          case Supervisor.start_child(pid, Discord.SourceRuntime.child_spec(source)) do
            {:ok, _pid} -> {:cont, :ok}
            {:ok, _pid, _info} -> {:cont, :ok}
            {:error, {:already_started, _pid}} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp retired_child?(child_id, wanted_ids, wanted_child_ids) do
    case source_id_from_child_id(child_id) do
      nil ->
        false

      source_id ->
        not MapSet.member?(wanted_ids, source_id) or
          not MapSet.member?(wanted_child_ids, child_id)
    end
  end

  defp source_id_from_child_id({Discord.SourceRuntime, id, _fingerprint}), do: id
  defp source_id_from_child_id({Discord.SourceRuntime, id}), do: id
  defp source_id_from_child_id(_child_id), do: nil
end
