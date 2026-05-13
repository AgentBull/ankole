defmodule BullX.Plugins.Registry do
  @moduledoc false

  use GenServer

  alias BullX.Plugins.Spec

  defstruct plugins: [], plugins_by_id: %{}, enabled_ids: MapSet.new(), extensions: []

  @type state :: %__MODULE__{
          plugins: [Spec.t()],
          plugins_by_id: %{String.t() => Spec.t()},
          enabled_ids: MapSet.t(String.t()),
          extensions: [BullX.Plugins.Extension.t()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    start_link_with_name(name, opts)
  end

  defp start_link_with_name(nil, opts), do: GenServer.start_link(__MODULE__, opts)
  defp start_link_with_name(name, opts), do: GenServer.start_link(__MODULE__, opts, name: name)

  @impl true
  def init(opts) do
    specs = Keyword.fetch!(opts, :plugins)
    enabled_ids = Keyword.get(opts, :enabled_plugins, [])

    case build(specs, enabled_ids) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @spec build([Spec.t()], [String.t()]) :: {:ok, state()} | {:error, term()}
  def build(specs, enabled_ids) do
    with :ok <- validate_enabled_ids(specs, enabled_ids),
         :ok <- validate_extension_uniqueness(specs) do
      {:ok,
       %__MODULE__{
         plugins: specs,
         plugins_by_id: Map.new(specs, &{&1.id, &1}),
         enabled_ids: MapSet.new(enabled_ids),
         extensions: Enum.flat_map(specs, & &1.extensions)
       }}
    end
  end

  @spec plugins(GenServer.server()) :: [Spec.t()]
  def plugins(server \\ __MODULE__), do: GenServer.call(server, :plugins)

  @spec enabled_plugins(GenServer.server()) :: [Spec.t()]
  def enabled_plugins(server \\ __MODULE__), do: GenServer.call(server, :enabled_plugins)

  @spec enabled?(String.t(), GenServer.server()) :: boolean()
  def enabled?(id, server \\ __MODULE__), do: GenServer.call(server, {:enabled?, id})

  @spec all_extensions(GenServer.server()) :: [BullX.Plugins.Extension.t()]
  def all_extensions(server \\ __MODULE__), do: GenServer.call(server, :extensions)

  @spec extensions_for(atom() | String.t(), GenServer.server()) :: [BullX.Plugins.Extension.t()]
  def extensions_for(point, server \\ __MODULE__),
    do: GenServer.call(server, {:extensions, point})

  @spec enabled_extensions_for(atom() | String.t(), GenServer.server()) :: [
          BullX.Plugins.Extension.t()
        ]
  def enabled_extensions_for(point, server \\ __MODULE__),
    do: GenServer.call(server, {:enabled_extensions, point})

  @impl true
  def handle_call(:plugins, _from, state), do: {:reply, state.plugins, state}

  def handle_call(:enabled_plugins, _from, state) do
    {:reply, Enum.filter(state.plugins, &MapSet.member?(state.enabled_ids, &1.id)), state}
  end

  def handle_call({:enabled?, id}, _from, state) do
    {:reply, MapSet.member?(state.enabled_ids, id), state}
  end

  def handle_call(:extensions, _from, state), do: {:reply, state.extensions, state}

  def handle_call({:extensions, point}, _from, state) do
    {:reply, Enum.filter(state.extensions, &(&1.point == point)), state}
  end

  def handle_call({:enabled_extensions, point}, _from, state) do
    extensions =
      Enum.filter(state.extensions, fn extension ->
        extension.point == point and MapSet.member?(state.enabled_ids, extension.plugin_id)
      end)

    {:reply, extensions, state}
  end

  defp validate_enabled_ids(specs, enabled_ids) do
    known_ids = specs |> Enum.map(& &1.id) |> MapSet.new()

    enabled_ids
    |> Enum.reject(&MapSet.member?(known_ids, &1))
    |> case do
      [] -> :ok
      unknown -> {:error, {:unknown_enabled_plugins, Enum.sort(unknown)}}
    end
  end

  defp validate_extension_uniqueness(specs) do
    specs
    |> Enum.flat_map(& &1.extensions)
    |> Enum.frequencies_by(&{&1.point, &1.id})
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> case do
      [] -> :ok
      duplicates -> {:error, {:duplicate_plugin_extensions, Enum.map(duplicates, &elem(&1, 0))}}
    end
  end
end
