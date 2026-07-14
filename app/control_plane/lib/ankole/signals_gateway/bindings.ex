defmodule Ankole.SignalsGateway.Bindings do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Repo
  alias Ankole.AppConfigure
  alias Ankole.Principals
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.Adapters.Definition
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.GroupMessageModes
  alias Ankole.SignalsGateway.Utils

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

  @spec list_adapters() :: {:ok, [map()]} | {:error, term()}
  def list_adapters do
    with {:ok, definitions} <- Adapters.list() do
      {:ok,
       definitions
       |> Enum.map(&adapter_catalog/1)
       |> Enum.sort_by(& &1.adapter_id)}
    end
  end

  @spec put_binding(String.t(), String.t(), String.t(), map()) ::
          {:ok, %{binding: Binding.t(), config_key: String.t()}} | {:error, term()}
  def put_binding(agent_uid, adapter_id, binding_name, attrs)
      when is_binary(adapter_id) and is_binary(binding_name) and is_map(attrs) do
    with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         {:ok, definition} <- Adapters.fetch(adapter_id),
         {:ok, config} <- binding_config(attrs),
         {:ok, normalized_config} <- validate_binding_config(definition, config),
         {:ok, mode} <- group_message_mode(attrs),
         :ok <- validate_supported_group_message_mode(definition, mode),
         {:ok, policy} <- GroupMessageModes.policy(mode),
         {:ok, config_key} <- binding_config_key(definition, binding_name),
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
           }),
         :ok <- maybe_handle_binding_saved(definition, binding, normalized_config),
         :ok <- Outbox.wake_blocked_for_binding(principal.uid, binding_name) do
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

  defp adapter_catalog(%Definition{} = definition) do
    %{
      adapter_id: definition.id,
      plugin_id: definition.plugin_id,
      display_name: definition.display_name,
      fields: definition.fields,
      group_message_mode_field: GroupMessageModes.field(definition.supported_group_message_modes)
    }
  end

  defp maybe_handle_binding_saved(%Definition{} = definition, %Binding{} = binding, config)
       when is_map(config) do
    case definition.binding_saved_module do
      module when is_atom(module) and not is_nil(module) ->
        case module.handle_binding_saved(binding, config) do
          :ok -> :ok
          {:ok, _result} -> :ok
          {:error, _reason} = error -> error
          other -> {:error, {:invalid_binding_saved_result, other}}
        end

      nil ->
        :ok
    end
  end

  defp binding_config(%{"config" => config}) when is_map(config), do: {:ok, config}
  defp binding_config(%{config: config}) when is_map(config), do: {:ok, config}
  defp binding_config(_attrs), do: {:error, :missing_config}

  defp group_message_mode(attrs) do
    case Utils.fetch_value(attrs, :group_message_mode) do
      mode when is_binary(mode) and mode != "" -> {:ok, mode}
      nil -> {:ok, GroupMessageModes.default_mode()}
      mode -> {:error, {:invalid_group_message_mode, mode}}
    end
  end

  defp validate_supported_group_message_mode(%Definition{} = definition, mode) do
    case definition.supported_group_message_modes do
      modes when is_list(modes) ->
        case mode in modes do
          true -> :ok
          false -> {:error, {:unsupported_group_message_mode, definition.id, mode}}
        end

      _modes ->
        :ok
    end
  end

  defp validate_binding_config(%Definition{} = definition, config) do
    case definition.config_module do
      nil ->
        {:ok, config}

      module when is_atom(module) ->
        module.validate_binding_config(config)
    end
  end

  defp binding_config_key(%Definition{} = definition, binding_name) do
    case definition.config_key_pattern do
      pattern when is_binary(pattern) -> {:ok, String.replace(pattern, "<id>", binding_name)}
      _pattern -> {:error, {:missing_adapter_config_key_pattern, definition.id}}
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
end
