defmodule BullX.AIAgent.MessageContextBuilder do
  @moduledoc """
  Builds per-message request-time context blocks.

  Time awareness, ambient background, and actor context are placed as message
  prefixes so prompt rendering does not concatenate these fragments ad hoc.
  """

  alias BullX.AIAgent.{ConversationKey, Message, Profile, Time}

  @spec metadata_for_user_message(Profile.t(), map(), [Message.t()], DateTime.t()) :: map()
  def metadata_for_user_message(%Profile{} = profile, event_data, branch, accepted_at) do
    send_at = send_at(event_data, accepted_at)
    granularity = profile.context.time_awareness_granularity
    injected? = inject_time?(granularity, send_at, branch)

    %{
      "time_awareness" => %{
        "send_at" => DateTime.to_iso8601(send_at),
        "granularity" => Atom.to_string(granularity),
        "injected" => injected?
      },
      "actor" => safe_actor_context(event_data),
      "scene" => ConversationKey.scene_identity(event_data)
    }
  end

  @spec build(Message.t(), keyword()) :: map()
  def build(%Message{} = message, opts \\ []) when is_list(opts) do
    profile = Keyword.fetch!(opts, :profile)
    ambient_context = Keyword.get(opts, :ambient_context, [])

    %{
      message_prefix: time_prefix(message, profile) ++ ambient_prefix(ambient_context),
      system_prompt_section: []
    }
  end

  @spec ambient_recall(String.t(), map(), Message.t() | nil) :: [map()]
  def ambient_recall(agent_principal_id, scene, current_message)
      when is_binary(agent_principal_id) and is_map(scene) do
    import Ecto.Query

    scene_key = scene_key(scene)
    previous_assistant = previous_assistant_boundary(current_message)

    recent =
      agent_principal_id
      |> ambient_query(scene_key)
      |> maybe_before(current_message)
      |> maybe_after(previous_assistant)
      |> order_by([m], desc: m.inserted_at)
      |> limit(10)
      |> BullX.Repo.all()
      |> Enum.reverse()

    recent
    |> expand_one_hour_window(agent_principal_id, scene_key, current_message)
    |> Enum.map(&ambient_snippet/1)
  end

  defp ambient_query(agent_principal_id, scene_key) do
    import Ecto.Query

    BullX.AIAgent.Message
    |> join(:inner, [m], c in BullX.AIAgent.Conversation, on: c.id == m.conversation_id)
    |> where([m, c], c.agent_principal_id == ^agent_principal_id)
    |> where([m], m.role == :im_ambient and m.kind == :normal)
    |> where([m], fragment("?->'scene'->>'scene_key' = ?", m.metadata, ^scene_key))
  end

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, %Message{inserted_at: inserted_at}) do
    import Ecto.Query
    where(query, [m], m.inserted_at < ^inserted_at)
  end

  defp maybe_after(query, nil), do: query

  defp maybe_after(query, %Message{inserted_at: inserted_at}) do
    import Ecto.Query
    where(query, [m], m.inserted_at > ^inserted_at)
  end

  defp expand_one_hour_window([], _agent_principal_id, _scene_key, _current_message),
    do: []

  defp expand_one_hour_window(recent, agent_principal_id, scene_key, current_message) do
    import Ecto.Query

    earliest = List.first(recent)
    window_start = DateTime.add(earliest.inserted_at, -3_600, :second)
    ids = MapSet.new(Enum.map(recent, & &1.id))

    expanded =
      agent_principal_id
      |> ambient_query(scene_key)
      |> maybe_before(current_message)
      |> where([m], m.inserted_at >= ^window_start)
      |> order_by([m], asc: m.inserted_at)
      |> BullX.Repo.all()

    expanded
    |> Enum.reject(&MapSet.member?(ids, &1.id))
    |> Kernel.++(recent)
    |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
  end

  defp previous_assistant_boundary(nil), do: nil

  defp previous_assistant_boundary(%Message{} = current_message) do
    import Ecto.Query

    BullX.AIAgent.Message
    |> where([m], m.conversation_id == ^current_message.conversation_id)
    |> where([m], m.role == :assistant and m.kind == :normal and m.status == :complete)
    |> where([m], m.inserted_at < ^current_message.inserted_at)
    |> order_by([m], desc: m.inserted_at)
    |> limit(1)
    |> BullX.Repo.one()
  end

  defp time_prefix(%Message{role: :user, kind: :normal, metadata: metadata}, profile) do
    case get_in(metadata, ["time_awareness", "injected"]) do
      true ->
        send_at = get_in(metadata, ["time_awareness", "send_at"])
        granularity = profile.context.time_awareness_granularity

        [
          %{
            type: :message_prefix,
            text: "<meta>send_at: #{format_send_at(send_at, granularity)}</meta>"
          }
        ]

      _other ->
        []
    end
  end

  defp time_prefix(
         %Message{role: :im_ambient, kind: :introspection, metadata: metadata},
         _profile
       ) do
    case get_in(metadata, ["ambient", "trigger_reason_summary"]) do
      reason when is_binary(reason) and reason != "" ->
        [%{type: :message_prefix, text: "<meta>ambient_intervention_reason: #{reason}</meta>"}]

      _other ->
        []
    end
  end

  defp time_prefix(_message, _profile), do: []

  defp ambient_prefix([]), do: []

  defp ambient_prefix(snippets) do
    lines =
      snippets
      |> Enum.map(fn snippet ->
        sender = snippet.sender_display_name || "unknown"
        sent_at = snippet.sent_at || "unknown time"
        "- #{sent_at} #{sender}: #{snippet.text}"
      end)
      |> Enum.join("\n")

    [
      %{
        type: :message_prefix,
        text: "<ambient_reference_context>\n#{lines}\n</ambient_reference_context>"
      }
    ]
  end

  defp inject_time?(:off, _send_at, _branch), do: false

  defp inject_time?(granularity, send_at, branch) do
    case previous_injected_send_at(branch) do
      nil -> true
      previous -> DateTime.diff(send_at, previous, boundary_unit(granularity)) >= 1
    end
  end

  defp previous_injected_send_at(branch) do
    branch
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{
        role: :user,
        kind: :normal,
        metadata: %{"time_awareness" => %{"injected" => true, "send_at" => send_at}}
      } ->
        case DateTime.from_iso8601(send_at) do
          {:ok, datetime, _offset} -> datetime
          _error -> nil
        end

      _message ->
        nil
    end)
  end

  defp boundary_unit(:minute), do: :minute
  defp boundary_unit(:hour), do: :hour
  defp boundary_unit(:day), do: :day

  defp send_at(event_data, fallback) do
    event_data
    |> get_in(["time", "send_at"])
    |> parse_datetime(fallback)
  end

  defp parse_datetime(value, fallback) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _error -> DateTime.truncate(fallback, :second)
    end
  end

  defp parse_datetime(_value, fallback), do: DateTime.truncate(fallback, :second)

  defp format_send_at(nil, _granularity), do: "unknown"

  defp format_send_at(send_at, granularity) do
    case DateTime.from_iso8601(send_at) do
      {:ok, datetime, _offset} -> format_datetime(datetime, granularity)
      _error -> "unknown"
    end
  end

  defp format_datetime(datetime, :day), do: Time.format(datetime, "%Y-%m-%d", nil)
  defp format_datetime(datetime, _granularity), do: Time.format(datetime, "%Y-%m-%d %H:%M", nil)

  defp safe_actor_context(event_data) do
    actor =
      event_data
      |> Map.get("actor", %{})
      |> case do
        %{} = actor -> actor
        _other -> %{}
      end

    %{
      "external_account_id_present" => is_binary(actor["external_account_id"]),
      "display_name" => safe_string(actor["display_name"])
    }
  end

  defp safe_string(value) when is_binary(value), do: String.slice(value, 0, 120)
  defp safe_string(_value), do: nil

  @spec scene_key(map()) :: String.t()
  def scene_key(%{"scene_key" => key}) when is_binary(key), do: key
  def scene_key(%{scene_key: key}) when is_binary(key), do: key

  def scene_key(scene) when is_map(scene) do
    [
      scene["channel_adapter"] || "",
      scene["channel_id"] || "",
      scene["channel_kind"] || "",
      scene["scope_id"] || "",
      scene["thread_id"] || ""
    ]
    |> Enum.join("|")
  end

  defp ambient_snippet(%Message{} = message) do
    %{
      source_message_id: message.id,
      sender_display_name: get_in(message.metadata, ["actor", "display_name"]),
      sent_at:
        get_in(message.metadata, ["time_awareness", "send_at"]) ||
          DateTime.to_iso8601(message.inserted_at),
      text: nonempty_brief(message) || text_content(message)
    }
  end

  defp nonempty_brief(%Message{metadata: %{"brief" => brief}})
       when is_binary(brief) and brief != "",
       do: brief

  defp nonempty_brief(_message), do: nil

  defp text_content(%Message{content: content}) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
    |> String.slice(0, 2_000)
  end
end
