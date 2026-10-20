defmodule Ankole.Conversations.Delivery.Reference do
  @moduledoc false

  import Ecto.Query

  alias Ankole.Conversations.External
  alias Ankole.Conversations.ExternalMessageRef
  alias Ankole.Conversations.InboundBatches
  alias Ankole.Conversations.Delivery

  @spec enrich(module(), map()) :: map()
  def enrich(repo, fact) when is_map(fact) do
    case Ankole.Attrs.optional_text(Map.get(fact, :reply_to_provider_message_id)) do
      nil ->
        fact

      provider_message_id ->
        reply_to = resolve(repo, fact, provider_message_id)

        fact
        |> Map.put(:reply_to_provider_message_id, provider_message_id)
        |> Map.put(:reply_to, reply_to)
        |> maybe_mark_explicit(reply_to)
        |> maybe_mark_durable_agent_reply_explicit(repo, reply_to)
        |> maybe_mark_agent_thread_explicit(repo)
    end
  end

  defp resolve(repo, fact, provider_message_id) do
    case mirror_snapshot(repo, fact, provider_message_id) do
      %{"resolution" => "resolved"} = snapshot ->
        # Provider file handles remain scoped to the observing binding. The
        # canonical message supplies identity and current text; another Agent
        # must not borrow this binding's unmaterialized attachment handles.
        case binding_snapshot(repo, fact, provider_message_id) do
          %{} = entry -> Map.put(snapshot, "attachments", entry["attachments"] || [])
          nil -> snapshot
        end

      unresolved ->
        case binding_snapshot(repo, fact, provider_message_id) do
          %{} = entry ->
            resolved_snapshot(provider_message_id, entry, entry["attachments"] || [])

          nil ->
            unresolved
        end
    end
  end

  defp binding_snapshot(repo, fact, provider_message_id) do
    with agent_uid when is_binary(agent_uid) <- Map.get(fact, :agent_uid),
         binding_name when is_binary(binding_name) <- Map.get(fact, :binding_name),
         conversation_id when is_binary(conversation_id) <- Map.get(fact, :conversation_id) do
      InboundBatches.entry_snapshot(
        repo,
        agent_uid,
        binding_name,
        conversation_id,
        provider_message_id
      )
    else
      _missing_scope -> nil
    end
  end

  defp mirror_snapshot(_repo, %{conversation_id: nil}, provider_message_id),
    do: %{"provider_message_id" => provider_message_id, "resolution" => "unresolved"}

  defp mirror_snapshot(repo, fact, provider_message_id) do
    case External.get_message(repo, Map.get(fact, :conversation_id), provider_message_id) do
      %{message: message, external_ref: ref} ->
        author = ref.author || %{}

        attachments =
          if own_agent_author?(author, Map.get(fact, :agent_uid)) do
            message.attachments || []
          else
            []
          end

        resolved_snapshot(
          provider_message_id,
          %{
            "message_id" => message.id,
            "text" => message.text,
            "attachments" => attachments,
            "links" => message.links || [],
            "author" => author,
            "provider_time" => provider_time_value(ref.provider_time)
          },
          attachments
        )

      nil ->
        %{
          "provider_message_id" => provider_message_id,
          "resolution" => "unresolved"
        }
    end
  end

  defp resolved_snapshot(provider_message_id, entry, attachments) do
    author = entry["author"] || %{}

    %{
      "message_id" => entry["message_id"],
      "provider_message_id" => provider_message_id,
      "resolution" => "resolved",
      "role" => author_role(author),
      "author" => author,
      "text" => entry["text"],
      "attachments" => attachments,
      "links" => entry["links"] || [],
      "provider_time" => provider_time_value(entry["provider_time"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_mark_explicit(fact, %{"author" => author}) when is_map(author) do
    explicit? =
      Map.get(fact, :explicit?) == true or
        own_agent_author?(author, Map.get(fact, :agent_uid))

    Map.put(fact, :explicit?, explicit?)
  end

  defp maybe_mark_explicit(fact, _reply_to), do: fact

  defp maybe_mark_durable_agent_reply_explicit(
         %{explicit?: false} = fact,
         repo,
         %{"resolution" => "unresolved", "provider_message_id" => provider_message_id}
       ) do
    with :im_group <- Map.get(fact, :channel_kind),
         agent_uid when is_binary(agent_uid) <-
           Ankole.Attrs.optional_text(Map.get(fact, :agent_uid)),
         binding_name when is_binary(binding_name) <-
           Ankole.Attrs.optional_text(Map.get(fact, :binding_name)),
         conversation_id when is_binary(conversation_id) <-
           Ankole.Attrs.optional_text(Map.get(fact, :conversation_id)),
         {:ok, _signal_id} <-
           Delivery.resolve_durable_reply_signal_in_tx(
             repo,
             agent_uid,
             binding_name,
             conversation_id,
             provider_message_id
           ) do
      Map.put(fact, :explicit?, true)
    else
      _not_a_durable_agent_reply -> fact
    end
  end

  defp maybe_mark_durable_agent_reply_explicit(fact, _repo, _reply_to), do: fact

  defp maybe_mark_agent_thread_explicit(%{explicit?: true} = fact, _repo), do: fact

  defp maybe_mark_agent_thread_explicit(fact, repo) do
    with :im_group <- Map.get(fact, :channel_kind),
         provider_thread_id when is_binary(provider_thread_id) <-
           Ankole.Attrs.optional_text(Map.get(fact, :provider_thread_id)),
         conversation_id when is_binary(conversation_id) <-
           Ankole.Attrs.optional_text(Map.get(fact, :conversation_id)),
         agent_uid when is_binary(agent_uid) <-
           Ankole.Attrs.optional_text(Map.get(fact, :agent_uid)),
         false <- own_agent_author?(Map.get(fact, :author), agent_uid),
         true <-
           agent_participated_in_thread?(repo, conversation_id, provider_thread_id, agent_uid) do
      Map.put(fact, :explicit?, true)
    else
      _not_an_agent_thread_reply -> fact
    end
  end

  defp agent_participated_in_thread?(repo, conversation_id, provider_thread_id, agent_uid) do
    ExternalMessageRef
    |> where([entry], entry.conversation_id == ^conversation_id)
    |> where([entry], entry.provider_thread_id == ^provider_thread_id)
    |> where(
      [entry],
      fragment("lower(?->>'agent_uid') = ?", entry.author, ^String.downcase(agent_uid))
    )
    |> repo.exists?()
  end

  defp author_role(author) do
    case Ankole.Attrs.optional_text(author["agent_uid"]) do
      nil -> if(is_binary(author["principal_uid"]), do: "human", else: "unknown")
      _agent_uid -> "agent"
    end
  end

  defp own_agent_author?(author, agent_uid) when is_map(author) and is_binary(agent_uid) do
    case Ankole.Attrs.optional_text(author["agent_uid"]) do
      nil -> false
      author_agent_uid -> String.downcase(author_agent_uid) == String.downcase(agent_uid)
    end
  end

  defp own_agent_author?(_author, _agent_uid), do: false

  defp provider_time_value(%DateTime{} = provider_time), do: DateTime.to_iso8601(provider_time)
  defp provider_time_value(provider_time) when is_binary(provider_time), do: provider_time
  defp provider_time_value(_provider_time), do: nil
end
