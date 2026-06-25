defmodule Ankole.Plugins.Registry do
  @moduledoc """
  GenServer holding the boot-time snapshot of discovered and active plugins.

  The whole plugin set is resolved once in `init/1`: discover specs, reject the
  globally disabled ids to get the active set, then register the active plugins'
  AppConfigure keys. State is immutable for the lifetime of the process, so
  enabling or disabling a plugin requires an Ankole restart — there is no live
  reload. If discovery, a uniqueness invariant, or config registration fails,
  `init/1` returns `:stop`, which fails application boot rather than starting up
  with a half-registered plugin set.
  """

  use GenServer

  alias Ankole.AppConfigure
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Discovery
  alias Ankole.Plugins.Spec

  @call_timeout 5_000

  @type state :: %{
          discovered: %{String.t() => Spec.t()},
          active: %{String.t() => Spec.t()},
          disabled_ids: MapSet.t(String.t())
        }

  @doc """
  Starts the plugin registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Lists all discovered plugin specs.
  """
  @spec list_discovered(GenServer.server()) :: [Spec.t()]
  def list_discovered(server \\ __MODULE__) do
    GenServer.call(server, :list_discovered, @call_timeout)
  end

  @doc """
  Lists plugin specs active in the current process.
  """
  @spec list_active(GenServer.server()) :: [Spec.t()]
  def list_active(server \\ __MODULE__) do
    GenServer.call(server, :list_active, @call_timeout)
  end

  @doc """
  Fetches an active plugin by id.
  """
  @spec get(String.t(), GenServer.server()) :: {:ok, Spec.t()} | :error
  def get(id, server \\ __MODULE__) when is_binary(id) do
    GenServer.call(server, {:get, id}, @call_timeout)
  end

  @doc """
  Returns whether a plugin id is currently active (discovered and not disabled).
  """
  @spec active?(String.t(), GenServer.server()) :: boolean()
  def active?(id, server \\ __MODULE__) when is_binary(id) do
    GenServer.call(server, {:active?, id}, @call_timeout)
  end

  @doc """
  Returns adapter declarations from active plugins for one contract id.

  Subsystems (SignalsGateway, Principals identity, ...) call this with their own
  contract id to find which plugins plug into them, e.g. "signals_gateway.adapter".
  """
  @spec adapter_declarations(String.t(), GenServer.server()) :: [map()]
  def adapter_declarations(contract_id, server \\ __MODULE__) when is_binary(contract_id) do
    GenServer.call(server, {:adapter_declarations, contract_id}, @call_timeout)
  end

  @doc """
  Lists supervised children contributed by active plugins.
  """
  @spec supervised_children(GenServer.server()) :: [Supervisor.child_spec()]
  def supervised_children(server \\ __MODULE__) do
    GenServer.call(server, :supervised_children, @call_timeout)
  end

  @doc """
  Lists disabled plugin ids read at registry startup.
  """
  @spec disabled_ids(GenServer.server()) :: [String.t()]
  def disabled_ids(server \\ __MODULE__) do
    GenServer.call(server, :disabled_ids, @call_timeout)
  end

  @impl true
  def init(opts) do
    discovery_opts = Keyword.get(opts, :discovery, [])

    # Resolve everything up front. Note the disable list is read from durable
    # AppConfigure exactly once here, which is why a disable/enable change only
    # lands on the next boot. Adapter-uniqueness and config registration run over
    # the *active* set only, so a disabled plugin can never collide or register.
    with {:ok, specs} <- Discovery.discover(discovery_opts),
         :ok <- ensure_unique_ids(specs),
         :ok <- Config.ensure_registered(),
         {:ok, disabled_ids} <- Config.disabled_ids(),
         active_specs <- active_specs(specs, disabled_ids),
         :ok <- ensure_unique_adapter_declarations(active_specs),
         :ok <- register_plugin_config(active_specs) do
      {:ok, build_state(specs, active_specs, disabled_ids)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list_discovered, _from, state) do
    {:reply, state.discovered |> Map.values() |> Enum.sort_by(& &1.id), state}
  end

  @impl true
  def handle_call(:list_active, _from, state) do
    {:reply, state.active |> Map.values() |> Enum.sort_by(& &1.id), state}
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    {:reply, Map.fetch(state.active, id), state}
  end

  @impl true
  def handle_call({:active?, id}, _from, state) do
    {:reply, Map.has_key?(state.active, id), state}
  end

  @impl true
  def handle_call({:adapter_declarations, contract_id}, _from, state) do
    declarations =
      state.active
      |> Map.values()
      |> Enum.flat_map(& &1.adapter_declarations)
      |> Enum.filter(&adapter_contract?(&1, contract_id))

    {:reply, declarations, state}
  end

  @impl true
  def handle_call(:supervised_children, _from, state) do
    children =
      state.active
      |> Map.values()
      |> Enum.flat_map(& &1.children)

    {:reply, children, state}
  end

  @impl true
  def handle_call(:disabled_ids, _from, state) do
    {:reply, state.disabled_ids |> MapSet.to_list() |> Enum.sort(), state}
  end

  defp ensure_unique_ids(specs) do
    specs
    |> Enum.group_by(& &1.id)
    |> Enum.find(fn {_id, specs} -> match?([_, _ | _], specs) end)
    |> case do
      nil ->
        :ok

      {id, duplicate_specs} ->
        {:error, {:duplicate_plugin_id, id, Enum.map(duplicate_specs, & &1.module)}}
    end
  end

  defp active_specs(specs, disabled_ids) do
    disabled = MapSet.new(disabled_ids)
    Enum.reject(specs, &MapSet.member?(disabled, &1.id))
  end

  # Two active plugins must not claim the same `{contract_id, adapter_id}` slot,
  # or a subsystem lookup would be ambiguous about which adapter to use.
  # Declarations missing either key are skipped here; `Spec` already rejected
  # truly malformed ones, and partial maps simply cannot collide.
  defp ensure_unique_adapter_declarations(specs) do
    specs
    |> Enum.flat_map(fn spec ->
      Enum.map(spec.adapter_declarations, fn declaration ->
        {adapter_contract_id(declaration), adapter_id(declaration), spec.module}
      end)
    end)
    |> Enum.reject(fn {contract_id, id, _module} -> is_nil(contract_id) or is_nil(id) end)
    |> Enum.group_by(fn {contract_id, id, _module} -> {contract_id, id} end)
    |> Enum.find(fn {_key, declarations} -> match?([_, _ | _], declarations) end)
    |> case do
      nil ->
        :ok

      {{contract_id, id}, duplicate_declarations} ->
        modules = Enum.map(duplicate_declarations, fn {_contract_id, _id, module} -> module end)
        {:error, {:duplicate_adapter_declaration, contract_id, id, modules}}
    end
  end

  defp register_plugin_config(specs) do
    with :ok <- register_definitions(specs),
         :ok <- register_patterns(specs) do
      :ok
    end
  end

  defp register_definitions(specs) do
    specs
    |> Enum.flat_map(& &1.app_config_definitions)
    |> AppConfigure.register_definitions()
  end

  defp register_patterns(specs) do
    specs
    |> Enum.flat_map(& &1.app_config_patterns)
    |> AppConfigure.register_patterns()
  end

  defp build_state(specs, active_specs, disabled_ids) do
    %{
      discovered: Map.new(specs, &{&1.id, &1}),
      active: Map.new(active_specs, &{&1.id, &1}),
      disabled_ids: MapSet.new(disabled_ids)
    }
  end

  # Adapter declarations are plain maps authored by plugins, so a key may arrive
  # as either an atom or a string. These helpers accept both forms.
  defp adapter_contract?(%{contract_id: contract_id}, contract_id), do: true
  defp adapter_contract?(%{"contract_id" => contract_id}, contract_id), do: true
  defp adapter_contract?(_declaration, _contract_id), do: false

  defp adapter_contract_id(%{contract_id: contract_id}), do: contract_id
  defp adapter_contract_id(%{"contract_id" => contract_id}), do: contract_id
  defp adapter_contract_id(_declaration), do: nil

  defp adapter_id(%{id: id}), do: id
  defp adapter_id(%{"id" => id}), do: id
  defp adapter_id(_declaration), do: nil
end
