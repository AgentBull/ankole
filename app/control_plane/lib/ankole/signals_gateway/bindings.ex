defmodule Ankole.SignalsGateway.Bindings do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.Repo
  alias Ankole.AppConfigure
  alias Ankole.Plugins.ConfigSecrets
  alias Ankole.Principals
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.Adapters.Definition
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.GroupMessageModes
  alias Ankole.SignalsGateway.UnmatchedSenderPolicies
  alias Ankole.SignalsGateway.Utils

  @spec upsert_binding(map()) :: {:ok, Binding.t()} | {:error, term()}
  def upsert_binding(attrs) when is_map(attrs) do
    upsert_binding(Repo, attrs)
  end

  defp upsert_binding(repo, attrs) do
    %Binding{}
    |> Binding.changeset(attrs)
    |> repo.insert(
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
    with {:ok, binding_name} <- normalize_binding_name(binding_name),
         {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         {:ok, definition} <- Adapters.fetch(adapter_id),
         {:ok, config} <- binding_config(attrs),
         {:ok, normalized_config} <- validate_binding_config(definition, config),
         {:ok, mode} <- group_message_mode(attrs, GroupMessageModes.default_mode()),
         :ok <- validate_supported_group_message_mode(definition, mode),
         {:ok, policy} <- GroupMessageModes.policy(mode),
         {:ok, unmatched_sender_policy} <-
           unmatched_sender_policy(attrs, UnmatchedSenderPolicies.default_value()),
         {:ok, config_key} <- binding_config_key(definition, principal.uid, binding_name),
         {:ok, binding} <-
           persist_binding_assignment(
             definition,
             principal.uid,
             binding_name,
             normalized_config,
             config_key,
             policy,
             unmatched_sender_policy
           ),
         :ok <- maybe_handle_binding_saved(definition, binding, normalized_config),
         :ok <- Outbox.wake_blocked_for_binding(principal.uid, binding_name),
         :ok <- Actors.wake_blocked_reply_previews(principal.uid, binding_name) do
      {:ok, %{binding: binding, config_key: config_key}}
    else
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  def put_binding(_agent_uid, _adapter_id, _binding_name, _attrs),
    do: {:error, :invalid_signal_binding}

  @spec update_binding(String.t(), String.t(), String.t(), map()) ::
          {:ok, %{binding: Binding.t(), config_key: String.t()}} | {:error, term()}
  def update_binding(source_agent_uid, target_agent_uid, binding_name, attrs)
      when is_binary(source_agent_uid) and is_binary(target_agent_uid) and
             is_binary(binding_name) and is_map(attrs) do
    with {:ok, binding_name} <- normalize_binding_name(binding_name),
         {:ok, %{principal: source_principal}} <- Principals.get_agent(source_agent_uid),
         {:ok, %{principal: target_principal}} <- Principals.get_agent(target_agent_uid),
         %Binding{} = source_binding <-
           Repo.get_by(Binding, agent_uid: source_principal.uid, name: binding_name),
         {:ok, definition} <- Adapters.fetch(source_binding.adapter),
         {:ok, config_patch} <- binding_config(attrs),
         {:ok, mode} <- group_message_mode(attrs, nil),
         :ok <- validate_supported_group_message_mode(definition, mode),
         {:ok, policy} <- group_message_policy(mode),
         {:ok, unmatched_sender_policy} <- unmatched_sender_policy(attrs, nil),
         {:ok, config_key} <-
           binding_config_key(definition, target_principal.uid, binding_name),
         {:ok, {binding, normalized_config}} <-
           persist_binding_update(
             definition,
             source_principal.uid,
             target_principal.uid,
             binding_name,
             config_patch,
             config_key,
             policy,
             unmatched_sender_policy
           ),
         :ok <- maybe_handle_binding_saved(definition, binding, normalized_config),
         :ok <- Outbox.wake_blocked_for_binding(target_principal.uid, binding_name),
         :ok <- Actors.wake_blocked_reply_previews(target_principal.uid, binding_name) do
      {:ok, %{binding: binding, config_key: config_key}}
    else
      nil -> {:error, :binding_not_found}
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  def update_binding(_source_agent_uid, _target_agent_uid, _binding_name, _attrs),
    do: {:error, :invalid_signal_binding}

  @spec get_binding_configuration(String.t(), String.t()) ::
          {:ok, %{binding: Binding.t(), config: map(), stored_secret_paths: [String.t()]}}
          | {:error, term()}
  def get_binding_configuration(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         %Binding{} = binding <-
           Repo.get_by(Binding, agent_uid: principal.uid, name: binding_name),
         {:ok, definition} <- Adapters.fetch(binding.adapter),
         {:ok, config} <- stored_binding_config(binding) do
      {config, stored_secret_paths} = ConfigSecrets.redact(definition.fields, config)

      {:ok,
       %{
         binding: binding,
         config: config,
         stored_secret_paths: stored_secret_paths
       }}
    else
      nil -> {:error, :binding_not_found}
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  def get_binding_configuration(_agent_uid, _binding_name),
    do: {:error, :binding_not_found}

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

  @doc """
  Lists bindings across the deployment instance for the Console, including disabled
  bindings. An agent filter narrows the list without an existence check: an
  unknown agent reads as an empty list, not an error.
  """
  @spec list_bindings(String.t() | nil) :: {:ok, [Binding.t()]}
  def list_bindings(agent_uid \\ nil) do
    bindings =
      Binding
      |> maybe_where_agent(agent_uid)
      |> order_by([binding], asc: binding.agent_uid, asc: binding.adapter, asc: binding.name)
      |> Repo.all()

    {:ok, bindings}
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid) when is_binary(agent_uid),
    do: where(query, [binding], binding.agent_uid == ^String.downcase(agent_uid))

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
      adapter_category: definition.adapter_category,
      plugin_id: definition.plugin_id,
      display_name: definition.display_name,
      fields: definition.fields,
      group_message_mode_field: GroupMessageModes.field(definition.supported_group_message_modes),
      unmatched_sender_policy_field: UnmatchedSenderPolicies.field()
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

  defp group_message_mode(attrs, default) do
    case Map.get(attrs, :group_message_mode, Map.get(attrs, "group_message_mode")) do
      mode when is_binary(mode) and mode != "" -> {:ok, mode}
      nil when is_nil(default) -> {:ok, nil}
      nil -> {:ok, default}
      mode -> {:error, {:invalid_group_message_mode, mode}}
    end
  end

  defp group_message_policy(nil), do: {:ok, nil}
  defp group_message_policy(mode), do: GroupMessageModes.policy(mode)

  defp unmatched_sender_policy(attrs, default) do
    case Map.get(attrs, :unmatched_sender_policy, Map.get(attrs, "unmatched_sender_policy")) do
      value when is_binary(value) and value != "" -> UnmatchedSenderPolicies.policy(value)
      nil when is_nil(default) -> {:ok, nil}
      nil -> UnmatchedSenderPolicies.policy(default)
      value -> {:error, {:unknown_unmatched_sender_policy, value}}
    end
  end

  defp validate_supported_group_message_mode(%Definition{}, nil), do: :ok

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

  defp validate_binding_assignment(
         %Definition{} = definition,
         repo,
         agent_uid,
         binding_name,
         config
       ) do
    case definition.config_module do
      module when is_atom(module) and not is_nil(module) ->
        if function_exported?(module, :validate_binding_assignment, 4) do
          module.validate_binding_assignment(repo, agent_uid, binding_name, config)
        else
          :ok
        end

      nil ->
        :ok
    end
  end

  defp persist_binding_assignment(
         %Definition{} = definition,
         agent_uid,
         binding_name,
         normalized_config,
         config_key,
         policy,
         unmatched_sender_policy
       ) do
    case Repo.transact(fn repo ->
           with :ok <- lock_adapter_assignments(repo, definition.id),
                :ok <-
                  validate_binding_assignment(
                    definition,
                    repo,
                    agent_uid,
                    binding_name,
                    normalized_config
                  ),
                {:ok, binding} <-
                  upsert_binding(repo, %{
                    agent_uid: agent_uid,
                    name: binding_name,
                    adapter: definition.id,
                    config_ref: "app-config://#{config_key}",
                    filters: %{},
                    unaddressed_group_message_policy: policy,
                    unmatched_sender_policy: unmatched_sender_policy,
                    enabled: true
                  }),
                {:ok, committed_config} <-
                  AppConfigure.put_global_by_key_in_tx(repo, config_key, normalized_config) do
             {:ok, {binding, committed_config}}
           end
         end) do
      {:ok, {binding, committed_config}} ->
        AppConfigure.cache_committed_write(committed_config)
        {:ok, binding}

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_binding_update(
         %Definition{} = definition,
         source_agent_uid,
         target_agent_uid,
         binding_name,
         config_patch,
         config_key,
         policy,
         unmatched_sender_policy
       ) do
    case Repo.transact(fn repo ->
           with :ok <- lock_adapter_assignments(repo, definition.id),
                %Binding{} = source_binding <-
                  lock_binding(repo, source_agent_uid, binding_name),
                :ok <- ensure_binding_adapter(source_binding, definition.id),
                {:ok, current_config} <- binding_config_in_tx(repo, source_binding),
                {:ok, normalized_config} <-
                  validate_binding_config(
                    definition,
                    merge_binding_config(
                      current_config,
                      ConfigSecrets.preserve(definition.fields, config_patch, current_config)
                    )
                  ),
                :ok <-
                  ensure_target_binding_available(
                    repo,
                    source_binding,
                    target_agent_uid,
                    binding_name
                  ),
                {:ok, _source_binding} <-
                  maybe_disable_source_binding(repo, source_binding, target_agent_uid),
                :ok <-
                  validate_binding_assignment(
                    definition,
                    repo,
                    target_agent_uid,
                    binding_name,
                    normalized_config
                  ),
                {:ok, binding} <-
                  upsert_binding(repo, %{
                    agent_uid: target_agent_uid,
                    name: binding_name,
                    adapter: definition.id,
                    config_ref: "app-config://#{config_key}",
                    filters: source_binding.filters,
                    unaddressed_group_message_policy:
                      policy || source_binding.unaddressed_group_message_policy,
                    unmatched_sender_policy:
                      unmatched_sender_policy || source_binding.unmatched_sender_policy,
                    enabled: true,
                    unavailable_reason: nil
                  }),
                {:ok, committed_config} <-
                  AppConfigure.put_global_by_key_in_tx(repo, config_key, normalized_config) do
             {:ok, {binding, committed_config, normalized_config}}
           else
             nil -> {:error, :binding_not_found}
             {:error, _reason} = error -> error
           end
         end) do
      {:ok, {binding, committed_config, normalized_config}} ->
        AppConfigure.cache_committed_write(committed_config)
        {:ok, {binding, normalized_config}}

      {:error, _reason} = error ->
        error
    end
  end

  defp binding_config_in_tx(repo, %Binding{config_ref: "app-config://" <> key}) do
    case AppConfigure.get_global_by_key_in_tx(repo, key) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _config} -> {:error, :binding_config_unavailable}
      :error -> {:error, :binding_config_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp binding_config_in_tx(_repo, %Binding{}), do: {:error, :binding_config_unavailable}

  @doc false
  @spec stored_binding_config(Binding.t()) :: {:ok, map()} | {:error, term()}
  def stored_binding_config(%Binding{config_ref: "app-config://" <> key}) do
    case AppConfigure.get_by_key(key) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _config} -> {:error, :binding_config_unavailable}
      :error -> {:error, :binding_config_unavailable}
      {:error, _reason} = error -> error
    end
  end

  def stored_binding_config(%Binding{}), do: {:error, :binding_config_unavailable}

  defp merge_binding_config(current, patch) when is_map(current) and is_map(patch) do
    Map.merge(current, patch, fn _key, current_value, patch_value ->
      if is_map(current_value) and is_map(patch_value) do
        merge_binding_config(current_value, patch_value)
      else
        patch_value
      end
    end)
  end

  defp ensure_binding_adapter(%Binding{adapter: adapter}, adapter), do: :ok
  defp ensure_binding_adapter(%Binding{}, _adapter), do: {:error, :binding_conflict}

  defp ensure_target_binding_available(
         _repo,
         %Binding{agent_uid: agent_uid},
         agent_uid,
         _binding_name
       ),
       do: :ok

  defp ensure_target_binding_available(repo, %Binding{}, target_agent_uid, binding_name) do
    case lock_binding(repo, target_agent_uid, binding_name) do
      nil -> :ok
      %Binding{enabled: false} -> :ok
      %Binding{enabled: true} -> {:error, :binding_target_conflict}
    end
  end

  defp maybe_disable_source_binding(
         _repo,
         %Binding{agent_uid: agent_uid} = source_binding,
         agent_uid
       ),
       do: {:ok, source_binding}

  defp maybe_disable_source_binding(repo, %Binding{} = source_binding, _target_agent_uid) do
    source_binding
    |> Binding.changeset(%{enabled: false, unavailable_reason: nil})
    |> repo.update()
  end

  defp lock_adapter_assignments(repo, adapter_id) do
    lock_key = "signals_gateway:binding_assignment:#{adapter_id}"

    case SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [lock_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp binding_config_key(%Definition{} = definition, agent_uid, binding_name) do
    case definition.config_module do
      module when is_atom(module) and not is_nil(module) ->
        if function_exported?(module, :binding_config_key, 2) do
          case module.binding_config_key(agent_uid, binding_name) do
            key when is_binary(key) and key != "" -> {:ok, key}
            key -> {:error, {:invalid_adapter_config_key, definition.id, key}}
          end
        else
          binding_config_key_from_pattern(definition, agent_uid, binding_name)
        end

      nil ->
        binding_config_key_from_pattern(definition, agent_uid, binding_name)
    end
  end

  defp binding_config_key_from_pattern(definition, agent_uid, binding_name) do
    case definition.config_key_pattern do
      pattern when is_binary(pattern) ->
        key =
          pattern
          |> String.replace("<agent_uid>", agent_uid)
          |> String.replace("<id>", binding_name)

        {:ok, key}

      _pattern ->
        {:error, {:missing_adapter_config_key_pattern, definition.id}}
    end
  end

  defp normalize_binding_name(binding_name) do
    case String.trim(binding_name) do
      "" -> {:error, :invalid_signal_binding}
      normalized -> {:ok, normalized}
    end
  end

  defp lock_binding(repo, agent_uid, binding_name) do
    Binding
    |> where([binding], binding.agent_uid == ^agent_uid and binding.name == ^binding_name)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp available_bindings_query do
    Binding
    |> where([binding], binding.enabled == true)
    |> where([binding], is_nil(binding.unavailable_reason))
  end

  @spec list_enabled_bindings(String.t(), keyword()) :: [Binding.t()]
  def list_enabled_bindings(adapter, opts \\ []) when is_binary(adapter) do
    repo = Keyword.get(opts, :repo, Repo)

    available_bindings_query()
    |> where([binding], binding.adapter == ^adapter)
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
