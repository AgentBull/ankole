defmodule Ankole.Plugins.Registry do
  @moduledoc """
  Owns the boot-time snapshot of discovered and active plugins.

  `Ankole.Plugins.Cohort` resolves the whole plugin set once with
  `prepare_snapshot/1` and starts this process with that snapshot, so a restart
  serves the same set. A direct start without a snapshot, as in tests, resolves
  the set in `init/1`. Snapshot preparation validates the compiled module list
  and selects the runtime plugin set; `init/1` registers the active plugins'
  AppConfigure keys on each start. First-run setup activates every discovered
  plugin so every bundled configuration path remains available across setup
  restarts. After setup, the global enable list selects optional plugins;
  plugins with `activation: :always` are active in every snapshot. State
  is immutable for the lifetime of the cohort. If snapshot preparation or
  config registration fails, startup stops before anything can use a partly
  registered plugin set.
  """

  use GenServer

  alias Ankole.AppConfigure
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Contracts
  alias Ankole.Plugins.Spec
  alias Ankole.Setup.Config, as: SetupConfig

  @type state :: %{
          discovered: %{String.t() => Spec.t()},
          active: %{String.t() => Spec.t()},
          adapters: %{{String.t(), String.t()} => map()},
          by_contract: %{String.t() => [map()]},
          hooks: %{atom() => [module()]}
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
    snapshot!(server).discovered |> Map.values() |> Enum.sort_by(& &1.id)
  end

  @doc """
  Lists plugin specs active in the current process.
  """
  @spec list_active(GenServer.server()) :: [Spec.t()]
  def list_active(server \\ __MODULE__) do
    sorted_active_specs(snapshot!(server))
  end

  @doc """
  Fetches an active plugin by id.
  """
  @spec get(String.t(), GenServer.server()) :: {:ok, Spec.t()} | :error
  def get(id, server \\ __MODULE__) when is_binary(id) do
    Map.fetch(snapshot!(server).active, id)
  end

  @doc """
  Returns whether a plugin id is currently active (discovered and enabled).
  """
  @spec active?(String.t(), GenServer.server()) :: boolean()
  def active?(id, server \\ __MODULE__) when is_binary(id) do
    Map.has_key?(snapshot!(server).active, id)
  end

  @doc """
  Returns adapter declarations from active plugins for one contract id.

  Subsystems (Signals, Principals identity, ...) call this with their own
  contract id to find which plugins plug into them, e.g. "signals.adapter".
  """
  @spec adapter_declarations(String.t(), GenServer.server()) :: [map()]
  def adapter_declarations(contract_id, server \\ __MODULE__) when is_binary(contract_id) do
    Map.get(snapshot!(server).by_contract, contract_id, [])
  end

  @doc """
  Lists supervised children contributed by active plugins.
  """
  @spec supervised_children(GenServer.server()) :: [Supervisor.child_spec()]
  def supervised_children(server \\ __MODULE__) do
    snapshot!(server).active |> Map.values() |> Enum.flat_map(& &1.children)
  end

  @doc false
  @spec app_config_declarations(GenServer.server()) ::
          {[Ankole.AppConfigure.Definition.t()], [Ankole.AppConfigure.PatternDefinition.t()]}
  def app_config_declarations(server \\ __MODULE__) do
    declarations(sorted_active_specs(snapshot!(server)))
  end

  @doc false
  @spec prepare_snapshot(keyword()) :: {:ok, state()} | {:error, term()}
  def prepare_snapshot(opts \\ []) do
    modules =
      Keyword.get_lazy(opts, :modules, fn ->
        Application.fetch_env!(:ankole, :control_plane_plugin_modules)
      end)

    with {:ok, specs} <- specs_from_modules(modules),
         :ok <- ensure_unique_ids(specs),
         {:ok, enabled_ids} <- Config.enabled_ids(),
         {:ok, setup_completed?} <- SetupConfig.completed?(),
         active_specs <- active_specs(specs, enabled_ids, setup_completed?),
         :ok <- ensure_unique_adapter_declarations(active_specs),
         :ok <- ensure_valid_adapter_contract_declarations(active_specs) do
      {:ok, build_state(specs, active_specs)}
    end
  end

  @impl true
  def init(opts) do
    with {:ok, state} <- snapshot(opts),
         active_specs <- sorted_active_specs(state),
         :ok <- register_plugin_config(active_specs) do
      maybe_refresh_contracts(opts, state, active_specs)
      name = Keyword.get(opts, :name, self())
      :persistent_term.put({__MODULE__, self()}, state)
      :persistent_term.put({__MODULE__, name}, state)
      {:ok, {name, state}}
    else
      {:error, reason} ->
        maybe_log_startup_failure(reason)
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, {name, _snapshot}) do
    :persistent_term.erase({__MODULE__, self()})
    :persistent_term.erase({__MODULE__, name})
    :ok
  end

  if Mix.env() == :test do
    @doc false
    def snapshot_for_test, do: snapshot!(__MODULE__)

    @doc false
    def update_for_test(updater), do: GenServer.call(__MODULE__, {:update_for_test, updater})

    @impl true
    def handle_call({:update_for_test, updater}, _from, {name, snapshot}) do
      updated = updater.(snapshot)

      updated = build_state(Map.values(updated.discovered), Map.values(updated.active))

      :persistent_term.put({__MODULE__, self()}, updated)
      :persistent_term.put({__MODULE__, name}, updated)
      {:reply, updated, {name, updated}}
    end
  end

  defp snapshot!(server) do
    case :persistent_term.get({__MODULE__, server}, :unavailable) do
      :unavailable -> exit({:noproc, {__MODULE__, server}})
      snapshot -> snapshot
    end
  end

  @doc "Resolves a driver from the site's immutable activation snapshot."
  def fetch_adapter(contract_id, adapter_id, server \\ __MODULE__) do
    case Map.fetch(snapshot!(server).adapters, {contract_id, adapter_id}) do
      :error -> {:error, {:adapter_not_found, contract_id, adapter_id}}
      {:ok, declaration} -> {:ok, declaration}
    end
  end

  @doc "Returns the active contributions for one domain transaction hook."
  def hooks(point), do: Map.get(snapshot!(__MODULE__).hooks, point, [])

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

  defp specs_from_modules(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, specs} ->
      case Spec.from_module(module) do
        {:ok, spec} -> {:cont, {:ok, [spec | specs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.sort_by(specs, & &1.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp specs_from_modules(modules), do: {:error, {:invalid_plugin_modules, modules}}

  defp active_specs(specs, _enabled_ids, false), do: specs

  defp active_specs(specs, enabled_ids, true) do
    enabled = MapSet.new(enabled_ids)
    Enum.filter(specs, &(&1.activation == :always or MapSet.member?(enabled, &1.id)))
  end

  # Two active plugins must not claim the same `{contract_id, adapter_id}` slot,
  # or a subsystem lookup would be ambiguous about which adapter to use.
  defp ensure_unique_adapter_declarations(specs) do
    specs
    |> Enum.flat_map(fn spec ->
      Enum.map(spec.adapter_declarations, fn declaration ->
        {declaration.contract_id, declaration.id, spec.module}
      end)
    end)
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

  defp ensure_valid_adapter_contract_declarations(specs) do
    Enum.reduce_while(specs, :ok, fn spec, :ok ->
      case validate_spec_adapter_contracts(spec) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_spec_adapter_contracts(spec) do
    Enum.reduce_while(spec.adapter_declarations, :ok, fn declaration, :ok ->
      case validate_adapter_contract_declaration(spec, declaration) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_adapter_contract_declaration(spec, declaration) do
    contract_id = declaration.contract_id

    case Contracts.validate(contract_id, declaration) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         {:invalid_adapter_contract_declaration, contract_id, declaration.id, spec.id,
          spec.module, reason}}
    end
  end

  defp register_plugin_config(specs) do
    {definitions, patterns} = declarations(specs)
    AppConfigure.replace_declarations(:plugins, definitions, patterns)
  end

  defp declarations(specs) do
    {
      Enum.flat_map(specs, & &1.app_config_definitions),
      Enum.flat_map(specs, & &1.app_config_patterns)
    }
  end

  defp sorted_active_specs(state) do
    state.active
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  defp snapshot(opts) do
    case Keyword.fetch(opts, :snapshot) do
      {:ok, snapshot} -> {:ok, snapshot}
      :error -> prepare_snapshot(opts)
    end
  end

  # Only the named application Registry publishes the subsystem views; a test
  # Registry with its own name keeps them unchanged.
  defp maybe_refresh_contracts(opts, state, active_specs) do
    if Keyword.get(opts, :name, __MODULE__) == __MODULE__,
      do: Contracts.refresh(Map.values(state.discovered), active_specs),
      else: :ok
  end

  defp build_state(specs, active_specs) do
    active_specs = Enum.sort_by(active_specs, & &1.id)
    declarations = Enum.flat_map(active_specs, & &1.adapter_declarations)

    %{
      discovered: Map.new(specs, &{&1.id, &1}),
      active: Map.new(active_specs, &{&1.id, &1}),
      adapters: Map.new(declarations, &{{&1.contract_id, &1.id}, &1}),
      by_contract: Enum.group_by(declarations, & &1.contract_id),
      hooks:
        active_specs
        |> Enum.flat_map(& &1.hooks)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    }
  end

  defp maybe_log_startup_failure(
         {:invalid_adapter_contract_declaration, _contract_id, _adapter_id, _plugin_id, _module,
          _reason} = reason
       ) do
    Ankole.Logging.error(
      "plugins.registry.startup_failed",
      "Plugin registry startup failed: #{inspect(reason)}",
      %{"reason" => inspect(reason)}
    )
  end

  defp maybe_log_startup_failure(_reason), do: :ok
end
