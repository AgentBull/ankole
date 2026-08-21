defmodule Ankole.Plugins.Registry do
  @moduledoc """
  GenServer holding the boot-time snapshot of discovered and active plugins.

  `Ankole.Plugins.Cohort` resolves the whole plugin set once with
  `prepare_snapshot/1` and starts this process with that snapshot, so a restart
  serves the same set. A direct start without a snapshot, as in tests, resolves
  the set in `init/1`. Snapshot preparation validates the compiled module list
  and selects the runtime plugin set; `init/1` registers the active plugins'
  AppConfigure keys on each start. First-run setup activates every discovered
  plugin so every bundled configuration path remains available across setup
  restarts. After setup, the global enable list selects the runtime set. State
  is immutable for the lifetime of the process. If snapshot preparation or
  config registration fails, startup stops before anything can use a partly
  registered plugin set.
  """

  use GenServer

  alias Ankole.AppConfigure
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Spec
  alias Ankole.Setup.Config, as: SetupConfig

  @plugin_modules Application.compile_env!(:ankole, :control_plane_plugin_modules)
  @call_timeout 5_000

  @type state :: %{
          discovered: %{String.t() => Spec.t()},
          active: %{String.t() => Spec.t()},
          enabled_ids: MapSet.t(String.t())
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
  Returns whether a plugin id is currently active (discovered and enabled).
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
  Lists enabled plugin ids read at registry startup.
  """
  @spec enabled_ids(GenServer.server()) :: [String.t()]
  def enabled_ids(server \\ __MODULE__) do
    GenServer.call(server, :enabled_ids, @call_timeout)
  end

  @doc false
  @spec app_config_declarations(GenServer.server()) ::
          {[Ankole.AppConfigure.Definition.t()], [Ankole.AppConfigure.PatternDefinition.t()]}
  def app_config_declarations(server \\ __MODULE__) do
    GenServer.call(server, :app_config_declarations, @call_timeout)
  end

  @doc false
  @spec prepare_snapshot(keyword()) :: {:ok, state()} | {:error, term()}
  def prepare_snapshot(opts \\ []) do
    modules = Keyword.get(opts, :modules, @plugin_modules)

    with {:ok, specs} <- specs_from_modules(modules),
         :ok <- ensure_unique_ids(specs),
         {:ok, enabled_ids} <- Config.enabled_ids(),
         {:ok, setup_completed?} <- SetupConfig.completed?(),
         active_specs <- active_specs(specs, enabled_ids, setup_completed?),
         :ok <- ensure_unique_adapter_declarations(active_specs),
         :ok <- ensure_valid_adapter_contract_declarations(active_specs) do
      {:ok, build_state(specs, active_specs, enabled_ids)}
    end
  end

  @impl true
  def init(opts) do
    with {:ok, state} <- snapshot(opts),
         active_specs <- sorted_active_specs(state),
         :ok <- register_plugin_config(active_specs) do
      maybe_refresh_ai_gateway_provider_cache(opts, active_specs)
      {:ok, state}
    else
      {:error, reason} ->
        maybe_log_startup_failure(reason)
        {:stop, reason}
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
  def handle_call(:enabled_ids, _from, state) do
    {:reply, state.enabled_ids |> MapSet.to_list() |> Enum.sort(), state}
  end

  @impl true
  def handle_call(:app_config_declarations, _from, state) do
    {:reply, declarations(sorted_active_specs(state)), state}
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
    Enum.filter(specs, &MapSet.member?(enabled, &1.id))
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
    contract_id = adapter_contract_id(declaration)

    result =
      case contract_id do
        "signals_gateway.adapter" ->
          Ankole.SignalsGateway.Adapters.validate_declaration(declaration)

        "signals_gateway.webhook_handler" ->
          Ankole.SignalsGateway.WebhookHandlers.validate_declaration(declaration)

        "principals.identity_provider" ->
          Ankole.IdentityProviders.validate_adapter_declaration(declaration)

        "ai_gateway.provider" ->
          Ankole.AIGateway.Providers.validate_adapter_declaration(declaration)

        _other_contract ->
          :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         {:invalid_adapter_contract_declaration, contract_id, adapter_id(declaration), spec.id,
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

  defp maybe_refresh_ai_gateway_provider_cache(opts, active_specs) do
    case Keyword.get(opts, :name, __MODULE__) do
      __MODULE__ ->
        active_specs
        |> Enum.flat_map(& &1.adapter_declarations)
        |> Ankole.AIGateway.Providers.refresh_from_adapter_declarations()

        :ok

      _other_registry ->
        :ok
    end
  end

  defp build_state(specs, active_specs, enabled_ids) do
    %{
      discovered: Map.new(specs, &{&1.id, &1}),
      active: Map.new(active_specs, &{&1.id, &1}),
      enabled_ids: MapSet.new(enabled_ids)
    }
  end

  defp adapter_contract?(%{contract_id: contract_id}, contract_id), do: true
  defp adapter_contract?(_declaration, _contract_id), do: false

  defp adapter_contract_id(%{contract_id: contract_id}), do: contract_id
  defp adapter_contract_id(_declaration), do: nil

  defp adapter_id(%{id: id}), do: id
  defp adapter_id(_declaration), do: nil

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
