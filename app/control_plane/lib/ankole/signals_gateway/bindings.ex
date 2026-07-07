defmodule Ankole.SignalsGateway.Bindings do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Repo
  alias Ankole.AppConfigure
  alias Ankole.Plugins
  alias Ankole.Principals
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.GroupMessageModes
  alias Ankole.SignalsGateway.Utils

  @adapter_contract_id "signals_gateway.adapter"

  @spec upsert_binding(map()) :: {:ok, Binding.t()} | {:error, term()}
  def upsert_binding(attrs) when is_map(attrs) do
    %Binding{}
    |> Binding.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:inserted_at]},
      conflict_target: [:agent_uid, :name],
      returning: true
    )
  end

  @spec list_adapters() :: [map()]
  def list_adapters do
    adapter_declarations()
    |> Enum.map(&adapter_catalog/1)
    |> Enum.sort_by(& &1.adapter_id)
  end

  @doc false
  @spec validate_adapter_declaration(map()) :: :ok | {:error, term()}
  def validate_adapter_declaration(declaration) when is_map(declaration) do
    with :ok <- validate_inbound_adapter(declaration),
         :ok <- validate_outbound_adapter(declaration),
         :ok <-
           validate_optional_adapter_module(
             declaration,
             :connection_supervisor,
             :ensure_started,
             3
           ),
         :ok <-
           validate_optional_adapter_module(
             declaration,
             :config_module,
             :validate_binding_config,
             1
           ) do
      :ok
    end
  end

  def validate_adapter_declaration(declaration),
    do: {:error, {:invalid_signal_adapter_declaration, declaration}}

  @spec put_binding(String.t(), String.t(), String.t(), map()) ::
          {:ok, %{binding: Binding.t(), config_key: String.t()}} | {:error, term()}
  def put_binding(agent_uid, adapter_id, binding_name, attrs)
      when is_binary(adapter_id) and is_binary(binding_name) and is_map(attrs) do
    with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         {:ok, declaration} <- fetch_adapter_declaration(adapter_id),
         {:ok, config} <- binding_config(attrs),
         {:ok, normalized_config} <- validate_binding_config(declaration, config),
         {:ok, mode} <- group_message_mode(attrs),
         :ok <- validate_supported_group_message_mode(declaration, mode),
         {:ok, policy} <- GroupMessageModes.policy(mode),
         {:ok, config_key} <- binding_config_key(declaration, binding_name),
         {:ok, _stored_config} <- AppConfigure.put_global_by_key(config_key, normalized_config),
         {:ok, binding} <-
           upsert_binding(%{
             agent_uid: principal.uid,
             name: binding_name,
             adapter: adapter_id,
             config_ref: "app-config://#{config_key}",
             filters: %{},
             unaddressed_group_message_policy: policy,
             enabled: true
           }) do
      {:ok, %{binding: binding, config_key: config_key}}
    else
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  def put_binding(_agent_uid, _adapter_id, _binding_name, _attrs),
    do: {:error, :invalid_signal_binding}

  @spec get_binding(String.t(), String.t()) :: {:ok, Binding.t()} | {:error, term()}
  def get_binding(agent_uid, binding_name) do
    case Repo.get_by(Binding, agent_uid: Utils.normalize_uid(agent_uid), name: binding_name) do
      %Binding{enabled: true, unavailable_reason: reason} when is_binary(reason) ->
        {:error, {:binding_unavailable, reason}}

      %Binding{enabled: true} = binding ->
        {:ok, binding}

      %Binding{enabled: false} ->
        {:error, :binding_disabled}

      nil ->
        {:error, :binding_not_found}
    end
  end

  @spec list_agent_bindings(String.t(), keyword()) ::
          {:ok, [Binding.t()]} | {:error, term()}
  def list_agent_bindings(agent_uid, opts \\ [])

  def list_agent_bindings(agent_uid, opts) when is_binary(agent_uid) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid) do
      bindings =
        Binding
        |> where([binding], binding.agent_uid == ^principal.uid)
        |> order_by([binding], asc: binding.adapter, asc: binding.name)
        |> repo.all()

      {:ok, bindings}
    else
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  def list_agent_bindings(_agent_uid, _opts), do: {:error, :agent_not_found}

  @spec disable_binding(String.t(), String.t()) :: {:ok, Binding.t()} | {:error, term()}
  def disable_binding(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    Repo.transact(fn repo ->
      with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
           %Binding{} = binding <- lock_binding(repo, principal.uid, binding_name) do
        binding
        |> Binding.changeset(%{enabled: false, unavailable_reason: nil})
        |> repo.update()
      else
        nil -> {:error, :binding_not_found}
        {:error, :not_found} -> {:error, :agent_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  def disable_binding(_agent_uid, _binding_name), do: {:error, :binding_not_found}

  defp adapter_catalog(declaration) do
    supported_modes = value(declaration, :supported_group_message_modes)
    adapter_id = value(declaration, :id)

    %{
      adapter_id: adapter_id,
      plugin_id: value(declaration, :plugin_id),
      display_name: value(declaration, :display_name) || default_text(adapter_id),
      fields: value(declaration, :fields) || [],
      group_message_mode_field: GroupMessageModes.field(supported_modes)
    }
  end

  defp fetch_adapter_declaration(adapter_id) do
    adapter_declarations()
    |> Enum.find(&(value(&1, :id) == adapter_id))
    |> case do
      nil -> {:error, {:unknown_signal_adapter, adapter_id}}
      declaration -> {:ok, declaration}
    end
  end

  defp adapter_declarations do
    Plugins.adapter_declarations(@adapter_contract_id)
  end

  defp validate_inbound_adapter(declaration) do
    capabilities = declaration_list(declaration, :inbound_capabilities)

    if capabilities == [] do
      :ok
    else
      with {:ok, module} <- declaration_module(declaration, :ingress_module),
           :ok <- validate_module_callback(module, :chat_consumer, 3) do
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
    do: validate_module_callback(module, :handle_message_receive, 3)

  defp validate_inbound_capability(module, "entry_removed"),
    do: validate_module_callback(module, :handle_message_removed, 3)

  defp validate_inbound_capability(module, "reaction_add"),
    do: validate_module_callback(module, :handle_reaction_created, 3)

  defp validate_inbound_capability(module, "reaction_remove"),
    do: validate_module_callback(module, :handle_reaction_deleted, 3)

  defp validate_inbound_capability(module, "action_event"),
    do: validate_module_callback(module, :handle_card_action, 3)

  defp validate_inbound_capability(_module, capability),
    do: {:error, {:unknown_inbound_capability, capability}}

  defp validate_outbound_adapter(declaration) do
    capabilities = declaration_list(declaration, :outbound_capabilities)

    if capabilities == [] do
      :ok
    else
      with {:ok, module} <- declaration_module(declaration, :outbox_module),
           :ok <- validate_module_callback(module, :send, 1) do
        case "outbound_reconciliation" in capabilities do
          true -> validate_module_callback(module, :reconcile, 1)
          false -> :ok
        end
      end
    end
  end

  defp validate_optional_adapter_module(declaration, key, callback, arity) do
    case declaration_module(declaration, key) do
      {:ok, module} -> validate_module_callback(module, callback, arity)
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

  defp validate_module_callback(module, function, arity) do
    case function_exported?(module, function, arity) do
      true -> :ok
      false -> {:error, {:missing_adapter_callback, module, function, arity}}
    end
  end

  defp declaration_list(declaration, key) do
    case value(declaration, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp binding_config(%{"config" => config}) when is_map(config), do: {:ok, config}
  defp binding_config(%{config: config}) when is_map(config), do: {:ok, config}
  defp binding_config(_attrs), do: {:error, :missing_config}

  defp group_message_mode(attrs) do
    case value(attrs, :group_message_mode) do
      mode when is_binary(mode) and mode != "" -> {:ok, mode}
      nil -> {:ok, GroupMessageModes.default_mode()}
      mode -> {:error, {:invalid_group_message_mode, mode}}
    end
  end

  defp validate_supported_group_message_mode(declaration, mode) do
    case value(declaration, :supported_group_message_modes) do
      modes when is_list(modes) ->
        case mode in modes do
          true -> :ok
          false -> {:error, {:unsupported_group_message_mode, value(declaration, :id), mode}}
        end

      _modes ->
        :ok
    end
  end

  defp validate_binding_config(declaration, config) do
    case value(declaration, :config_module) do
      nil ->
        {:ok, config}

      module when is_atom(module) ->
        case function_exported?(module, :validate_binding_config, 1) do
          true -> module.validate_binding_config(config)
          false -> {:ok, config}
        end

      module ->
        {:error, {:invalid_adapter_config_module, module}}
    end
  end

  defp binding_config_key(declaration, binding_name) do
    case value(declaration, :config_key_pattern) do
      pattern when is_binary(pattern) -> {:ok, String.replace(pattern, "<id>", binding_name)}
      _pattern -> {:error, {:missing_adapter_config_key_pattern, value(declaration, :id)}}
    end
  end

  defp lock_binding(repo, agent_uid, binding_name) do
    Binding
    |> where([binding], binding.agent_uid == ^agent_uid and binding.name == ^binding_name)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  @spec list_enabled_bindings(String.t(), keyword()) :: [Binding.t()]
  def list_enabled_bindings(adapter, opts \\ []) when is_binary(adapter) do
    repo = Keyword.get(opts, :repo, Repo)

    Binding
    |> where([binding], binding.adapter == ^adapter)
    |> where([binding], binding.enabled == true)
    |> where([binding], is_nil(binding.unavailable_reason))
    |> order_by([binding], asc: binding.agent_uid, asc: binding.name)
    |> repo.all()
  end

  @spec outbox_binding_config_ref(OutboxEntry.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def outbox_binding_config_ref(%OutboxEntry{} = outbox, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get_by(Binding,
           agent_uid: outbox.agent_uid,
           name: outbox.binding_name
         ) do
      %Binding{config_ref: config_ref} when is_binary(config_ref) ->
        {:ok, config_ref}

      %Binding{} ->
        {:error, :binding_config_ref_missing}

      nil ->
        {:error, :binding_not_found}
    end
  end

  defp value(map, key) when is_map(map) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      Map.has_key?(map, string_key) -> Map.fetch!(map, string_key)
      true -> nil
    end
  end

  defp default_text(value), do: %{"default" => value}
end
