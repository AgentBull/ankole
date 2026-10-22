defmodule Ankole.Conversations.Delivery.Queries do
  @moduledoc false
  require Ash.Query

  alias Ankole.Conversations.Delivery.Intent

  # Give a transient provider failure a short recovery window before retry.
  @stopped_delivery_limit 100
  # Give a live preview time to checkpoint before durable delivery takes over.
  @durable_reply_create_operations [:post, :reply, :card, :divider]

  @doc false
  @spec resolve_durable_reply_signal_in_tx(
          module(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, Ecto.UUID.t()} | {:error, :unresolved_reply_target}
  def resolve_durable_reply_signal_in_tx(
        _repo,
        agent_uid,
        binding_name,
        conversation_id,
        provider_message_id
      )
      when is_binary(agent_uid) and is_binary(binding_name) and
             is_binary(conversation_id) and is_binary(provider_message_id) do
    owners =
      agent_uid
      |> durable_reply_surface_query(binding_name, conversation_id)
      |> Ash.Query.filter(
        (operation in ^@durable_reply_create_operations and
           created_provider_message_id == ^provider_message_id) or
          (operation == :edit and target_provider_message_id == ^provider_message_id)
      )
      |> Ash.Query.select([:source_signal_id])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.source_signal_id)
      |> Enum.uniq()

    case owners do
      [signal_id] -> {:ok, signal_id}
      _unresolved -> {:error, :unresolved_reply_target}
    end
  end

  @doc false
  @spec durable_reply_surface_exists_in_tx?(
          module(),
          String.t(),
          String.t(),
          String.t(),
          Ecto.UUID.t()
        ) :: boolean()
  def durable_reply_surface_exists_in_tx?(
        _repo,
        agent_uid,
        binding_name,
        conversation_id,
        signal_id
      )
      when is_binary(agent_uid) and is_binary(binding_name) and
             is_binary(conversation_id) and is_binary(signal_id) do
    agent_uid
    |> durable_reply_surface_query(binding_name, conversation_id)
    |> Ash.Query.filter(source_signal_id == ^signal_id)
    |> Ash.Query.limit(1)
    |> Ankole.Ash.read!() != []
  end

  @doc """
  Lists the latest stopped durable replies, optionally for one Agent.

  This projection is bounded for the Console. PostgreSQL keeps every row.
  """
  @spec list_stopped_deliveries(String.t() | nil) :: {:ok, [Intent.t()]}
  def list_stopped_deliveries(agent_uid \\ nil) when is_binary(agent_uid) or is_nil(agent_uid) do
    deliveries =
      Intent
      |> maybe_where_agent(agent_uid)
      # A failed or unknown reply stops when recovery requires explicit action.
      |> Ash.Query.filter(
        delivery_class == :durable_ai_reply and
          (status == :expired or
             (status in [:failed, :unknown] and is_nil(next_attempt_at) and
                (not is_nil(recovery_status) or possible_duplicate == true)))
      )
      |> Ash.Query.sort(updated_at: :desc, binding_name: :desc, outbound_key: :desc)
      |> Ash.Query.limit(@stopped_delivery_limit)
      |> Ankole.Ash.read!()

    {:ok, deliveries}
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid) do
    agent_uid = Ankole.PrincipalKey.canonicalize(agent_uid)
    Ash.Query.filter(query, agent_uid == ^agent_uid)
  end

  defp durable_reply_surface_query(agent_uid, binding_name, conversation_id) do
    agent_uid = Ankole.PrincipalKey.canonicalize(agent_uid)

    Ash.Query.filter(
      Intent,
      agent_uid == ^agent_uid and binding_name == ^binding_name and
        conversation_id == ^conversation_id and status == :sent and
        delivery_class == :durable_ai_reply and not is_nil(source_signal_id) and
        ((operation in ^@durable_reply_create_operations and
            not is_nil(created_provider_message_id)) or
           (operation == :edit and not is_nil(target_provider_message_id)))
    )
  end

  def fetch_delivery_for_update(_repo, agent_uid, binding_name, outbound_key) do
    agent_uid
    |> delivery_query(binding_name, outbound_key)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  def fetch_delivery_for_update(repo, %Intent{} = intent) do
    fetch_delivery_for_update(repo, intent.agent_uid, intent.binding_name, intent.outbound_key)
  end

  def fetch_delivery(agent_uid, binding_name, outbound_key) do
    agent_uid
    |> delivery_query(binding_name, outbound_key)
    |> Ankole.Ash.read_one!()
  end

  defp delivery_query(agent_uid, binding_name, outbound_key) do
    agent_uid = Ankole.PrincipalKey.canonicalize(agent_uid)

    Ash.Query.filter(
      Intent,
      agent_uid == ^agent_uid and binding_name == ^binding_name and
        outbound_key == ^outbound_key
    )
  end
end
