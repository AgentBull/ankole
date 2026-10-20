defmodule Ankole.Signals.Adapters do
  @moduledoc """
  Resolves raw plugin declarations into Signals adapter definitions.

  `Ankole.Plugins.Registry` owns the immutable boot-time declaration snapshot.
  This module owns every Signals-specific interpretation of that data:
  atom/string keys, callback validation, capability projection, and construction
  of the executable `Adapter` contract.
  """

  alias Ankole.Plugins.Registry
  alias Ankole.Conversations.Delivery.Adapter
  alias Ankole.Conversations.Delivery.PreviewAdapter

  @contract_id "signals.adapter"
  @adapter_categories ["enterprise_im", "consumer_im", "email"]

  defmodule Definition do
    @moduledoc """
    Normalized Signals adapter declaration consumed by gateway callers.
    """

    alias Ankole.Conversations.Delivery.Adapter
    alias Ankole.Conversations.Delivery.PreviewAdapter

    @enforce_keys [:id, :adapter_category, :display_name, :fields]
    defstruct [
      :id,
      :adapter_category,
      :plugin_id,
      :display_name,
      :config_key_pattern,
      :config_module,
      :application_bindings,
      :worker_env_module,
      :binding_saved_module,
      :author_hydrator,
      :supported_group_message_modes,
      :delivery_adapter,
      :preview_adapter,
      fields: []
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            adapter_category: String.t(),
            plugin_id: String.t() | nil,
            display_name: %{String.t() => String.t()},
            fields: [map()],
            config_key_pattern: String.t() | nil,
            config_module: module() | nil,
            application_bindings: :one | nil,
            worker_env_module: module() | nil,
            binding_saved_module: module() | nil,
            author_hydrator: module() | nil,
            supported_group_message_modes: [String.t()] | nil,
            delivery_adapter: Adapter.t() | nil,
            preview_adapter: PreviewAdapter.t() | nil
          }
  end

  @doc """
  Lists active signal adapters as normalized domain definitions.
  """
  @spec list(GenServer.server()) ::
          {:ok, [Definition.t()]} | {:error, :signal_adapter_registry_unavailable | term()}
  def list(server \\ Registry) do
    with {:ok, declarations} <- declarations(server) do
      declarations
      |> Enum.map(&resolve_declaration/1)
      |> Ankole.Attrs.collect_results()
    end
  end

  @doc """
  Fetches one active signal adapter by id.
  """
  @spec fetch(String.t(), GenServer.server()) ::
          {:ok, Definition.t()}
          | {:error,
             :signal_adapter_registry_unavailable | {:signal_adapter_not_found, term()} | term()}
  def fetch(adapter_id, server \\ Registry) do
    with {:ok, declarations} <- declarations(server),
         declaration when not is_nil(declaration) <-
           Enum.find(declarations, &(value(&1, :id) == adapter_id)) do
      resolve_declaration(declaration)
    else
      nil -> {:error, {:signal_adapter_not_found, adapter_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Fetches the executable outbound contract for one active signal adapter.
  """
  @spec fetch_delivery(String.t(), GenServer.server()) ::
          {:ok, Adapter.t()}
          | {:error,
             :signal_adapter_registry_unavailable
             | {:signal_adapter_not_found, term()}
             | {:signal_adapter_intent_unavailable, term()}
             | term()}
  def fetch_delivery(adapter_id, server \\ Registry) do
    with {:ok, %Definition{delivery_adapter: delivery_adapter}} <- fetch(adapter_id, server) do
      case delivery_adapter do
        %Adapter{} = adapter -> {:ok, adapter}
        nil -> {:error, {:signal_adapter_intent_unavailable, adapter_id}}
      end
    end
  end

  @doc """
  Fetches the optional mutable AI reply surface for one active adapter.
  """
  @spec fetch_preview(String.t(), GenServer.server()) ::
          {:ok, PreviewAdapter.t()}
          | {:error,
             :signal_adapter_registry_unavailable
             | {:signal_adapter_not_found, term()}
             | {:signal_adapter_preview_unavailable, term()}
             | term()}
  def fetch_preview(adapter_id, server \\ Registry) do
    with {:ok, %Definition{preview_adapter: preview_adapter}} <-
           fetch(adapter_id, server) do
      case preview_adapter do
        %PreviewAdapter{} = adapter -> {:ok, adapter}
        nil -> {:error, {:signal_adapter_preview_unavailable, adapter_id}}
      end
    end
  end

  @doc false
  @spec validate_declaration(map()) :: :ok | {:error, term()}
  def validate_declaration(declaration) when is_map(declaration) do
    case resolve_declaration(declaration) do
      {:ok, %Definition{}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def validate_declaration(declaration),
    do: {:error, {:invalid_signal_adapter_declaration, declaration}}

  defp declarations(server) do
    try do
      {:ok, Registry.adapter_declarations(@contract_id, server)}
    catch
      :exit, _reason -> {:error, :signal_adapter_registry_unavailable}
    end
  end

  defp resolve_declaration(declaration) do
    with adapter_id when is_binary(adapter_id) and adapter_id != "" <- value(declaration, :id),
         {:ok, adapter_category} <-
           validate_adapter_category(value(declaration, :adapter_category)),
         :ok <- validate_inbound_adapter(declaration),
         :ok <- validate_identity_provider_fields(declaration),
         {:ok, delivery_adapter} <- resolve_delivery_adapter(declaration),
         :ok <-
           validate_optional_adapter_module(
             declaration,
             :config_module,
             :validate_binding_config,
             1
           ),
         :ok <- validate_application_bindings(declaration),
         :ok <-
           validate_optional_adapter_module(
             declaration,
             :worker_env_module,
             :resolve_worker_env,
             1
           ),
         :ok <-
           validate_optional_adapter_module(
             declaration,
             :binding_saved_module,
             :handle_binding_saved,
             2
           ),
         :ok <-
           validate_optional_adapter_module(
             declaration,
             :author_hydrator,
             :hydrate_author,
             2
           ),
         {:ok, preview_adapter} <- resolve_preview_adapter(declaration) do
      {:ok,
       %Definition{
         id: adapter_id,
         adapter_category: adapter_category,
         plugin_id: value(declaration, :plugin_id),
         display_name: value(declaration, :display_name) || %{"default" => adapter_id},
         fields: list_value(declaration, :fields),
         config_key_pattern: value(declaration, :config_key_pattern),
         config_module: value(declaration, :config_module),
         application_bindings: value(declaration, :application_bindings),
         worker_env_module: value(declaration, :worker_env_module),
         binding_saved_module: value(declaration, :binding_saved_module),
         author_hydrator: value(declaration, :author_hydrator),
         supported_group_message_modes:
           optional_list_value(declaration, :supported_group_message_modes),
         delivery_adapter: attach_reply_preview(delivery_adapter, preview_adapter),
         preview_adapter: preview_adapter
       }}
    else
      {:error, _reason} = error -> error
      _adapter_id -> {:error, {:invalid_signal_adapter_declaration, declaration}}
    end
  end

  defp validate_adapter_category(category) when category in @adapter_categories,
    do: {:ok, category}

  defp validate_adapter_category(category), do: {:error, {:invalid_adapter_category, category}}

  defp validate_application_bindings(declaration) do
    case value(declaration, :application_bindings) do
      nil ->
        :ok

      :one ->
        with {:ok, _module} <- declaration_module(declaration, :config_module), do: :ok

      value ->
        {:error, {:invalid_application_bindings, value}}
    end
  end

  defp validate_inbound_adapter(declaration) do
    capabilities = list_value(declaration, :inbound_capabilities)

    if capabilities == [] do
      :ok
    else
      with {:ok, module} <- declaration_module(declaration, :observe_module),
           :ok <- Ankole.Attrs.validate_module_callback(module, :chat_consumer, 2) do
        Enum.reduce_while(capabilities, :ok, fn capability, :ok ->
          case validate_inbound_capability(module, capability) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    end
  end

  defp validate_inbound_capability(module, "entry_receive"),
    do: Ankole.Attrs.validate_module_callback(module, :handle_message_receive, 3)

  defp validate_inbound_capability(module, "entry_removed"),
    do: Ankole.Attrs.validate_module_callback(module, :handle_message_removed, 3)

  defp validate_inbound_capability(module, "reaction_add"),
    do: Ankole.Attrs.validate_module_callback(module, :handle_reaction_created, 3)

  defp validate_inbound_capability(module, "reaction_remove"),
    do: Ankole.Attrs.validate_module_callback(module, :handle_reaction_deleted, 3)

  defp validate_inbound_capability(module, "action_event"),
    do: Ankole.Attrs.validate_module_callback(module, :handle_card_action, 3)

  defp validate_inbound_capability(_module, capability),
    do: {:error, {:unknown_inbound_capability, capability}}

  defp resolve_delivery_adapter(declaration) do
    case list_value(declaration, :outbound_capabilities) do
      [] ->
        {:ok, nil}

      capabilities ->
        with {:ok, module} <- declaration_module(declaration, :deliver_module) do
          Adapter.from_module(module, capabilities)
        end
    end
  end

  defp resolve_preview_adapter(declaration) do
    case declaration_module(declaration, :preview_module) do
      {:ok, module} -> PreviewAdapter.from_module(module)
      {:error, {:missing_adapter_module, :preview_module}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach_reply_preview(%Adapter{} = delivery_adapter, preview_adapter),
    do: %{delivery_adapter | reply_preview: preview_adapter}

  defp attach_reply_preview(nil, _preview_adapter), do: nil

  defp validate_optional_adapter_module(declaration, key, callback, arity) do
    case declaration_module(declaration, key) do
      {:ok, module} -> Ankole.Attrs.validate_module_callback(module, callback, arity)
      {:error, {:missing_adapter_module, ^key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp declaration_module(declaration, key) do
    case value(declaration, key) do
      module when is_atom(module) and not is_nil(module) ->
        case Code.ensure_loaded(module) do
          {:module, ^module} -> {:ok, module}
          {:error, reason} -> {:error, {:adapter_module_not_loaded, key, module, reason}}
        end

      nil ->
        {:error, {:missing_adapter_module, key}}

      module ->
        {:error, {:invalid_adapter_module, key, module}}
    end
  end

  # An `identity_provider` field is resolved by the host against the named
  # identity-provider adapter, so the declaration must carry that id.
  defp validate_identity_provider_fields(declaration) do
    declaration
    |> list_value(:fields)
    |> Enum.filter(&(is_map(&1) and &1[:type] == "identity_provider"))
    |> Enum.reduce_while(:ok, fn field, :ok ->
      case field[:identity_provider_adapter] do
        adapter_id when is_binary(adapter_id) and adapter_id != "" -> {:cont, :ok}
        _missing -> {:halt, {:error, {:identity_provider_field_without_adapter, field[:path]}}}
      end
    end)
  end

  defp list_value(declaration, key) do
    case value(declaration, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp optional_list_value(declaration, key) do
    case value(declaration, key) do
      values when is_list(values) -> values
      _value -> nil
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key)
end
