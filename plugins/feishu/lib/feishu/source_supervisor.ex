defmodule Feishu.SourceSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children =
      Feishu.Source.enabled_sources!()
      |> Enum.map(&Feishu.Channel.child_spec/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec runtime_status() :: {:ok, map()} | {:error, :not_running | term()}
  def runtime_status do
    with {:ok, sources} <- Feishu.Source.enabled_sources(),
         {:ok, children} <- children() do
      ready_ids = child_source_ids(children)

      {:ok,
       %{
         ready?: Enum.all?(sources, &MapSet.member?(ready_ids, &1.id)),
         sources:
           Enum.map(sources, fn source ->
             %{
               id: source.id,
               enabled: true,
               ready: MapSet.member?(ready_ids, source.id),
               transport: if(source.start_transport?, do: "websocket", else: "disabled")
             }
           end)
       }}
    end
  end

  @spec reconcile_sources() :: {:ok, map()} | {:error, :not_running | term()}
  def reconcile_sources do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         {:ok, sources} <- Feishu.Source.enabled_sources(),
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

  defp child_source_ids(children) do
    children
    |> Enum.flat_map(fn
      {{Feishu.Channel, id}, pid, _type, _modules} when is_pid(pid) -> [id]
      _child -> []
    end)
    |> MapSet.new()
  end

  defp stop_retired_children(pid, sources) do
    wanted_ids = MapSet.new(sources, & &1.id)

    pid
    |> Supervisor.which_children()
    |> Enum.reduce_while(:ok, fn
      {{Feishu.Channel, id} = child_id, _child_pid, _type, _modules}, :ok ->
        case MapSet.member?(wanted_ids, id) do
          true ->
            {:cont, :ok}

          false ->
            _ = Supervisor.terminate_child(pid, child_id)
            _ = Supervisor.delete_child(pid, child_id)
            {:cont, :ok}
        end

      _child, :ok ->
        {:cont, :ok}
    end)
  end

  defp start_missing_children(pid, sources) do
    existing_ids =
      pid
      |> Supervisor.which_children()
      |> child_source_ids()

    Enum.reduce_while(sources, :ok, fn source, :ok ->
      case MapSet.member?(existing_ids, source.id) do
        true ->
          {:cont, :ok}

        false ->
          case Supervisor.start_child(pid, Feishu.Channel.child_spec(source)) do
            {:ok, _pid} -> {:cont, :ok}
            {:ok, _pid, _info} -> {:cont, :ok}
            {:error, {:already_started, _pid}} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end
end
