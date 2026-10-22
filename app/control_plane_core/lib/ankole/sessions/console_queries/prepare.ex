defmodule Ankole.Sessions.ConsoleQueries.Prepare do
  @moduledoc """
  Applies the filters and the order of the operator console conversation list.

  This preparation implements the `console_list` read action of
  `Ankole.AIGateway.Schemas.Conversation`. `Ankole.Sessions.ConsoleQueries`
  normalizes the arguments before the read.
  """
  use Ash.Resource.Preparation
  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> filter_subject_uid(Ash.Query.get_argument(query, :subject_uid))
    |> filter_conversation_key(Ash.Query.get_argument(query, :conversation_key))
    |> filter_search(Ash.Query.get_argument(query, :search))
    |> filter_active(Ash.Query.get_argument(query, :active))
    |> filter_min_messages(Ash.Query.get_argument(query, :min_messages))
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
  end

  defp filter_subject_uid(query, nil), do: query

  defp filter_subject_uid(query, subject_uid),
    do: Ash.Query.filter(query, subject_uid == ^subject_uid)

  defp filter_conversation_key(query, nil), do: query

  defp filter_conversation_key(query, conversation_key) do
    pattern = like_pattern(conversation_key)
    Ash.Query.filter(query, ilike(conversation_key, ^pattern))
  end

  # One operator search box: an exact subject UID, a session-key fragment, or a
  # fragment of a name that the list shows. The name sources are the public
  # conversation for groups and the Principal display name for DM peers. The
  # filter matches them as a disjunction. It does not copy the display
  # precedence.
  defp filter_search(query, nil), do: query

  defp filter_search(query, search) do
    pattern = like_pattern(search)
    # Stored subject UIDs are canonical lowercase.
    subject = String.downcase(search)

    Ash.Query.filter(
      query,
      subject_uid == ^subject or ilike(conversation_key, ^pattern) or
        exists(
          public_conversation,
          ilike(title, ^pattern) or ilike(provider_conversation_id, ^pattern)
        ) or
        exists(peer, ilike(display_name, ^pattern))
    )
  end

  defp filter_active(query, nil), do: query
  defp filter_active(query, true), do: Ash.Query.filter(query, is_nil(ended_at))
  defp filter_active(query, false), do: Ash.Query.filter(query, not is_nil(ended_at))

  # Both predicates match the leading columns of the
  # `ai_gateway_messages_conversation_index` composite index. The inner LIMIT
  # bounds the count at the threshold, so a long conversation costs `min`
  # index reads instead of one read for each message.
  defp filter_min_messages(query, min) when is_integer(min) and min > 0 do
    Ash.Query.filter(
      query,
      fragment(
        "(SELECT COUNT(*) FROM (SELECT 1 FROM ai_gateway_messages m WHERE m.tenant_id = ? AND m.subject_uid = ? AND m.conversation_id = ? LIMIT ?) bounded) >= ?",
        tenant_id,
        subject_uid,
        id,
        ^min,
        ^min
      )
    )
  end

  defp filter_min_messages(query, _min), do: query

  defp like_pattern(text), do: "%" <> Ankole.Repo.escape_like(text) <> "%"
end
