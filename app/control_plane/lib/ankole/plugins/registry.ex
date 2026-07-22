defmodule Ankole.Plugins.Registry do
  @moduledoc """
  GenServer holding the boot-time snapshot of discovered and active plugins.

  The whole plugin set is resolved once in `init/1`. The Registry validates the
  compiled module list, selects the globally enabled ids, and registers the
  active plugins' AppConfigure keys. State is immutable for the lifetime of the
  process, so enabling or disabling a plugin requires an Ankole restart. If
  module validation, a uniqueness invariant, or config registration fails,
  `init/1` returns `:stop`. This result stops application startup before it can
  use a partly registered plugin set.
  """

  use GenServer

  alias Ankole.AppConfigure
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Spec

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

  @impl true
  def init(opts) do
    modules = Keyword.get(opts, :modules, @plugin_modules)

    # Resolve everything up front. Note the enable list is read from durable
    # AppConfigure exactly once here, which is why an enablement change only
    # lands on the next boot. Adapter-uniqueness and config registration run over
    # the *active* set only, so an inactive plugin can never collide or register.
    with {:ok, specs} <- specs_from_modules(modules),
         :ok <- ensure_unique_ids(specs),
         :ok <- Config.ensure_registered(),
         {:ok, enabled_ids} <- Config.enabled_ids(),
         active_specs <- active_specs(specs, enabled_ids),
         :ok <- ensure_unique_adapter_declarations(active_specs),
         :ok <- ensure_valid_adapter_contract_declarations(active_specs),
         :ok <- register_plugin_config(active_specs) do
      maybe_refresh_ai_gateway_provider_cache(opts, active_specs)
      {:ok, build_state(specs, active_specs, enabled_ids)}
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

  defp active_specs(specs, enabled_ids) do
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
