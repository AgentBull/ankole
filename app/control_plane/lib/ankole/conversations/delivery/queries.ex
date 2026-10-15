defmodule Ankole.Conversations.Delivery.Queries do
  @moduledoc false
  import Ecto.Query, warn: false

  alias Ankole.Repo
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
        repo,
        agent_uid,
        binding_name,
        conversation_id,
        provider_provider_message_id
      )
      when is_binary(agent_uid) and is_binary(binding_name) and
             is_binary(conversation_id) and is_binary(provider_provider_message_id) do
    owners =
      agent_uid
      |> durable_reply_surface_query(binding_name, conversation_id)
      |> where(
        [entry],
        (entry.operation in ^@durable_reply_create_operations and
           entry.created_provider_message_id == ^provider_provider_message_id) or
          (entry.operation == :edit and
             entry.target_provider_message_id == ^provider_provider_message_id)
      )
      |> select([entry], entry.source_signal_id)
      |> distinct(true)
      |> limit(2)
      |> repo.all()

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
        repo,
        agent_uid,
        binding_name,
        conversation_id,
        signal_id
      )
      when is_binary(agent_uid) and is_binary(binding_name) and
             is_binary(conversation_id) and is_binary(signal_id) do
    agent_uid
    |> durable_reply_surface_query(binding_name, conversation_id)
    |> where([entry], entry.source_signal_id == ^signal_id)
    |> repo.exists?()
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
      |> where([entry], entry.delivery_class == :durable_ai_reply)
      # `:unsupported` is already terminal by itself: the route can never accept
      # this reply, so it carries no retry state to inspect. Retryable classes
      # only stop once their recovery state says they will not run again.
      |> where(
        [entry],
        entry.status == :expired or
          (entry.status in [:failed, :unknown] and is_nil(entry.next_attempt_at) and
             fragment(
               "?->>'state' IN ('blocked', 'permanent', 'exhausted')",
               entry.recovery_state
             ))
      )
      |> order_by(
        [entry],
        desc: entry.updated_at,
        desc: entry.binding_name,
        desc: entry.outbound_key
      )
      |> limit(@stopped_delivery_limit)
      |> Repo.all()

    {:ok, deliveries}
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid),
    do: where(query, [entry], entry.agent_uid == ^Ankole.PrincipalKey.canonicalize(agent_uid))

  defp durable_reply_surface_query(agent_uid, binding_name, conversation_id) do
    Intent
    |> where([entry], entry.agent_uid == ^Ankole.PrincipalKey.canonicalize(agent_uid))
    |> where([entry], entry.binding_name == ^binding_name)
    |> where([entry], entry.conversation_id == ^conversation_id)
    |> where([entry], entry.status == :sent)
    |> where([entry], entry.delivery_class == :durable_ai_reply)
    |> where([entry], not is_nil(entry.source_signal_id))
    |> where(
      [entry],
      (entry.operation in ^@durable_reply_create_operations and
         not is_nil(entry.created_provider_message_id)) or
        (entry.operation == :edit and not is_nil(entry.target_provider_message_id))
    )
  end

  def fetch_delivery_for_update(repo, agent_uid, binding_name, outbound_key) do
    Intent
    |> where([entry], entry.agent_uid == ^Ankole.PrincipalKey.canonicalize(agent_uid))
    |> where([entry], entry.binding_name == ^binding_name)
    |> where([entry], entry.outbound_key == ^outbound_key)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  def fetch_delivery_for_update(repo, %Intent{} = intent) do
    fetch_delivery_for_update(repo, intent.agent_uid, intent.binding_name, intent.outbound_key)
  end

  def fetch_delivery(agent_uid, binding_name, outbound_key) do
    Intent
    |> where([entry], entry.agent_uid == ^Ankole.PrincipalKey.canonicalize(agent_uid))
    |> where([entry], entry.binding_name == ^binding_name)
    |> where([entry], entry.outbound_key == ^outbound_key)
    |> Repo.one()
  end
end
