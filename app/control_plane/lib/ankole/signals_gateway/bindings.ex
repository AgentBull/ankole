defmodule Ankole.SignalsGateway.Bindings do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Repo
  alias Ankole.AppConfigure
  alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig
  alias Ankole.Principals
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalBinding
  alias Ankole.SignalsGateway.Utils

  @spec upsert_binding(map()) :: {:ok, SignalBinding.t()} | {:error, term()}
  def upsert_binding(attrs) when is_map(attrs) do
    %SignalBinding{}
    |> SignalBinding.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:inserted_at]},
      conflict_target: [:agent_uid, :name],
      returning: true
    )
  end

  @spec put_lark_binding(String.t(), String.t(), map()) ::
          {:ok, %{binding: SignalBinding.t(), config_key: String.t()}} | {:error, term()}
  def put_lark_binding(agent_uid, binding_name, config)
      when is_binary(binding_name) and is_map(config) do
    with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         {:ok, normalized_config} <- LarkConfig.validate_chat_config(config),
         :ok <- require_lark_bot_identity(normalized_config),
         {:ok, policy} <- policy_from_lark_group_mode(normalized_config["group_message_mode"]),
         config_key = LarkConfig.chat_config_key(binding_name),
         {:ok, _stored_config} <- AppConfigure.put_global_by_key(config_key, normalized_config),
         {:ok, binding} <-
           upsert_binding(%{
             agent_uid: principal.uid,
             name: binding_name,
             adapter: "lark",
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

  def put_lark_binding(_agent_uid, _binding_name, _config), do: {:error, :invalid_lark_binding}

  @spec get_binding(String.t(), String.t()) :: {:ok, SignalBinding.t()} | {:error, term()}
  def get_binding(agent_uid, binding_name) do
    case Repo.get_by(SignalBinding, agent_uid: Utils.normalize_uid(agent_uid), name: binding_name) do
      %SignalBinding{enabled: true, unavailable_reason: reason} when is_binary(reason) ->
        {:error, {:binding_unavailable, reason}}

      %SignalBinding{enabled: true} = binding ->
        {:ok, binding}

      %SignalBinding{enabled: false} ->
        {:error, :binding_disabled}

      nil ->
        {:error, :binding_not_found}
    end
  end

  @spec list_agent_bindings(String.t(), keyword()) ::
          {:ok, [SignalBinding.t()]} | {:error, term()}
  def list_agent_bindings(agent_uid, opts \\ [])

  def list_agent_bindings(agent_uid, opts) when is_binary(agent_uid) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid) do
      bindings =
        SignalBinding
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

  @spec disable_binding(String.t(), String.t()) :: {:ok, SignalBinding.t()} | {:error, term()}
  def disable_binding(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    Repo.transact(fn repo ->
      with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
           %SignalBinding{} = binding <- lock_binding(repo, principal.uid, binding_name) do
        binding
        |> SignalBinding.changeset(%{enabled: false, unavailable_reason: nil})
        |> repo.update()
      else
        nil -> {:error, :binding_not_found}
        {:error, :not_found} -> {:error, :agent_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  def disable_binding(_agent_uid, _binding_name), do: {:error, :binding_not_found}

  defp policy_from_lark_group_mode("addressed_only"), do: {:ok, :ignore}
  defp policy_from_lark_group_mode("observe_all"), do: {:ok, :record_only}
  defp policy_from_lark_group_mode("may_intervene"), do: {:ok, :may_intervene}
  defp policy_from_lark_group_mode(_mode), do: {:error, :invalid_group_message_mode}

  defp lock_binding(repo, agent_uid, binding_name) do
    SignalBinding
    |> where([binding], binding.agent_uid == ^agent_uid and binding.name == ^binding_name)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp require_lark_bot_identity(config) when is_map(config) do
    if present_text?(Map.get(config, "botOpenId")) or present_text?(Map.get(config, "botUserId")) do
      :ok
    else
      {:error, :missing_lark_bot_identity}
    end
  end

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  @spec list_enabled_bindings(String.t(), keyword()) :: [SignalBinding.t()]
  def list_enabled_bindings(adapter, opts \\ []) when is_binary(adapter) do
    repo = Keyword.get(opts, :repo, Repo)

    SignalBinding
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

    case repo.get_by(SignalBinding,
           agent_uid: outbox.agent_uid,
           name: outbox.binding_name
         ) do
      %SignalBinding{config_ref: config_ref} when is_binary(config_ref) ->
        {:ok, config_ref}

      %SignalBinding{} ->
        {:error, :binding_config_ref_missing}

      nil ->
        {:error, :binding_not_found}
    end
  end
end
