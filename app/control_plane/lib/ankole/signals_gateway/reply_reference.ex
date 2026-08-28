defmodule Ankole.SignalsGateway.ReplyReference do
  @moduledoc false

  import Ecto.Query

  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.InboundBatches
  alias Ankole.SignalsGateway.Outbox

  @spec enrich(module(), map()) :: map()
  def enrich(repo, fact) when is_map(fact) do
    case normalized_target_id(Map.get(fact, :reply_to_source_entry_id)) do
      nil ->
        fact

      source_entry_id ->
        reply_to = resolve(repo, fact, source_entry_id)

        fact
        |> Map.put(:reply_to_source_entry_id, source_entry_id)
        |> Map.put(:reply_to, reply_to)
        |> maybe_mark_explicit(reply_to)
        |> maybe_mark_durable_agent_reply_explicit(repo, reply_to)
        |> maybe_mark_agent_thread_explicit(repo)
    end
  end

  defp resolve(repo, fact, source_entry_id) do
    case binding_snapshot(repo, fact, source_entry_id) do
      %{} = entry ->
        resolved_snapshot(source_entry_id, entry, entry["attachments"] || [])

      nil ->
        mirror_snapshot(repo, fact, source_entry_id)
    end
  end

  defp binding_snapshot(repo, fact, source_entry_id) do
    with agent_uid when is_binary(agent_uid) <- Map.get(fact, :agent_uid),
         binding_name when is_binary(binding_name) <- Map.get(fact, :binding_name),
         signal_channel_id when is_binary(signal_channel_id) <- Map.get(fact, :signal_channel_id) do
      InboundBatches.entry_snapshot(
        repo,
        agent_uid,
        binding_name,
        signal_channel_id,
        source_entry_id
      )
    else
      _missing_scope -> nil
    end
  end

  defp mirror_snapshot(repo, fact, source_entry_id) do
    case repo.get_by(Entry,
           signal_channel_id: Map.get(fact, :signal_channel_id),
           source_entry_id: source_entry_id
         ) do
      %Entry{} = entry ->
        author = entry.author || %{}

        attachments =
          if own_agent_author?(author, Map.get(fact, :agent_uid)) do
            entry.attachments || []
          else
            []
          end

        resolved_snapshot(
          source_entry_id,
          %{
            "text" => entry.text,
            "attachments" => attachments,
            "links" => entry.links || [],
            "author" => author,
            "provider_time" => provider_time_value(entry.provider_time)
          },
          attachments
        )

      nil ->
        %{
          "source_entry_id" => source_entry_id,
          "resolution" => "unresolved"
        }
    end
  end

  defp resolved_snapshot(source_entry_id, entry, attachments) do
    author = entry["author"] || %{}

    %{
      "source_entry_id" => source_entry_id,
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
         %{"resolution" => "unresolved", "source_entry_id" => source_entry_id}
       ) do
    with :im_group <- Map.get(fact, :channel_kind),
         agent_uid when is_binary(agent_uid) <- normalized_target_id(Map.get(fact, :agent_uid)),
         binding_name when is_binary(binding_name) <-
           normalized_target_id(Map.get(fact, :binding_name)),
         signal_channel_id when is_binary(signal_channel_id) <-
           normalized_target_id(Map.get(fact, :signal_channel_id)),
         {:ok, _actor_event_id} <-
           Outbox.resolve_durable_reply_actor_event_in_tx(
             repo,
             agent_uid,
             binding_name,
             signal_channel_id,
             source_entry_id
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
           normalized_target_id(Map.get(fact, :provider_thread_id)),
         signal_channel_id when is_binary(signal_channel_id) <-
           normalized_target_id(Map.get(fact, :signal_channel_id)),
         agent_uid when is_binary(agent_uid) <- normalized_target_id(Map.get(fact, :agent_uid)),
         false <- own_agent_author?(Map.get(fact, :author), agent_uid),
         true <-
           agent_participated_in_thread?(repo, signal_channel_id, provider_thread_id, agent_uid) do
      Map.put(fact, :explicit?, true)
    else
      _not_an_agent_thread_reply -> fact
    end
  end

  defp agent_participated_in_thread?(repo, signal_channel_id, provider_thread_id, agent_uid) do
    Entry
    |> where([entry], entry.signal_channel_id == ^signal_channel_id)
    |> where([entry], entry.provider_thread_id == ^provider_thread_id)
    |> where(
      [entry],
      fragment("lower(?->>'agent_uid') = ?", entry.author, ^String.downcase(agent_uid))
    )
    |> repo.exists?()
  end

  defp author_role(author) do
    case normalized_target_id(author["agent_uid"]) do
      nil -> "human"
      _agent_uid -> "agent"
    end
  end

  defp own_agent_author?(author, agent_uid) when is_map(author) and is_binary(agent_uid) do
    case normalized_target_id(author["agent_uid"]) do
      nil -> false
      author_agent_uid -> String.downcase(author_agent_uid) == String.downcase(agent_uid)
    end
  end

  defp own_agent_author?(_author, _agent_uid), do: false

  defp provider_time_value(%DateTime{} = provider_time), do: DateTime.to_iso8601(provider_time)
  defp provider_time_value(provider_time) when is_binary(provider_time), do: provider_time
  defp provider_time_value(_provider_time), do: nil

  defp normalized_target_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_target_id(_value), do: nil
end
