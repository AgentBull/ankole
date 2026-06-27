defmodule Ankole.AIAgent.MessageContext do
  @moduledoc """
  Builds the frozen `<message_context>` metadata stored on inbound transcript rows.

  The renderer in Agent Computer must be able to replay the exact context prefix a
  message had when it was written. For that reason this module stores both the
  raw scene facts and each sparse-injection decision in message metadata instead
  of recomputing them from whatever the transcript looks like later.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Schemas.Message

  @metadata_key "message_context"
  # "Sparse injection": scene facts (time, room, actor) are rendered into the
  # prompt only when they have changed since the model last saw them, to avoid
  # repeating a timestamp/room banner on every message. Time re-injects only
  # after a 1h gap; below that the previous time line is still considered fresh.
  @time_context_gap_ms 60 * 60 * 1_000
  # Hard cap on any single injected context line (speaker, room, think). Bounds
  # how much untrusted chat metadata can bloat the frozen prompt prefix.
  @max_context_line_text 800

  @type history_item :: %{metadata: map()}
  @type input :: %{
          optional(:actor) => map() | nil,
          optional(:room) => map() | nil,
          optional(:sent_at) => DateTime.t() | String.t() | nil,
          optional(:speaker) => String.t() | nil,
          optional(:speaker_role) => String.t() | nil,
          optional(:speaker_trigger) => String.t() | nil,
          optional(:think) => String.t() | nil,
          optional(:timezone) => String.t() | nil
        }

  @doc """
  Loads prior inbound context metadata for sparse-injection comparisons.

  Only user and ambient rows that can carry real inbound scene facts are included.
  Rows marked with `transcript_effect` are omitted so recalls/deletions do not
  skew later "what did the model last see?" decisions.
  """
  @spec load_history(module(), Ecto.UUID.t()) :: [history_item()]
  def load_history(repo, conversation_id) do
    Message
    |> where([message], message.conversation_id == ^conversation_id)
    |> where([message], message.role in ["user", "im_ambient"])
    |> where([message], message.kind in ["normal", "introspection"])
    |> where([message], message.status == "complete")
    |> where([message], fragment("?->'transcript_effect' is null", message.metadata))
    |> order_by([message], asc: message.inserted_at, asc: message.id)
    |> select([message], %{metadata: message.metadata})
    |> repo.all()
  end

  @doc """
  Computes frozen message-context metadata for one incoming message.

  Time, room, and inferred actor are sparse and compare against `history`.
  Runtime-supplied speaker and think fields are always injected because they are
  explicit control-plane facts, not facts inferred from the surrounding chat.
  """
  @spec build(input(), [history_item()]) :: map()
  def build(input, history) when is_map(input) and is_list(history) do
    sent_at = normalize_sent_at(value(input, :sent_at)) || DateTime.utc_now(:microsecond)
    timezone = text(value(input, :timezone)) || "UTC"
    actor = actor_context(value(input, :actor))
    room = room_context(value(input, :room), actor.display_name)

    %{
      "time" => %{
        "sent_at" => DateTime.to_iso8601(sent_at),
        "injected" => should_inject_time?(sent_at, history),
        "gap_ms" => @time_context_gap_ms,
        "timezone" => timezone
      }
    }
    |> put_optional("room", room_metadata(room, history))
    |> put_optional("actor", actor_metadata(actor, room, history))
    |> put_optional("speaker", speaker_metadata(input))
    |> put_optional("think", think_metadata(input))
  end

  @doc """
  Stores a computed context under the reserved metadata key.
  """
  @spec merge(map() | nil, map()) :: map()
  def merge(metadata, context) when is_map(context) do
    (metadata || %{})
    |> Map.put(@metadata_key, context)
  end

  @doc """
  Appends just-written metadata to an in-memory history list for batch writes.
  """
  @spec append_history([history_item()], map()) :: [history_item()]
  def append_history(history, metadata) when is_list(history) and is_map(metadata),
    do: history ++ [%{metadata: metadata}]

  defp room_metadata(nil, _history), do: nil

  defp room_metadata(room, history) do
    %{
      "id" => room.id,
      "is_dm" => room.is_dm,
      "name" => room.name,
      "label" => room.label,
      "injected" => should_inject_room?(room, history)
    }
    |> reject_nil()
  end

  defp actor_metadata(actor, room, history) do
    case actor.display_name || actor.key do
      nil ->
        nil

      _value ->
        %{
          "actor_key" => actor.key,
          "display_name" => actor.display_name,
          # Only worth telling the model "who is speaking" in a group chat, and
          # only when the speaker changed. In a DM the counterpart is implicit,
          # so the actor banner is never injected.
          "injected" => not is_nil(room) and !room.is_dm and should_inject_actor?(actor, history)
        }
        |> reject_nil()
    end
  end

  defp speaker_metadata(input) do
    speaker = normalize_context_line(value(input, :speaker))
    role = normalize_context_line(value(input, :speaker_role))
    trigger = normalize_context_line(value(input, :speaker_trigger))

    case speaker || role || trigger do
      nil ->
        nil

      _value ->
        %{
          "display_name" => speaker,
          "role" => role,
          "trigger" => trigger,
          "injected" => true
        }
        |> reject_nil()
    end
  end

  defp think_metadata(input) do
    case normalize_context_line(value(input, :think)) do
      nil -> nil
      think -> %{"text" => think, "injected" => true}
    end
  end

  defp should_inject_time?(sent_at, history) do
    case find_last_context(history, fn context ->
           context
           |> map_value("time")
           |> map_value("sent_at")
           |> normalize_sent_at()
         end) do
      %DateTime{} = previous ->
        DateTime.diff(sent_at, previous, :millisecond) >= @time_context_gap_ms

      nil ->
        false
    end
  end

  defp should_inject_room?(room, history) do
    previous =
      find_last_context(history, fn context ->
        value = context |> map_value("room") |> ensure_map()

        case value["injected"] == true do
          true -> %{id: text(value["id"]), label: text(value["label"])}
          false -> nil
        end
      end)

    is_nil(previous) || previous.id != room.id || previous.label != room.label
  end

  defp should_inject_actor?(actor, history) do
    current = actor.key || actor.display_name
    previous_context = last_message_context(history)
    previous_actor = previous_context |> map_value("actor") |> ensure_map()
    previous = text(previous_actor["actor_key"]) || text(previous_actor["display_name"])

    current && previous != current
  end

  defp find_last_context(history, fun) do
    history
    |> Enum.reverse()
    |> Enum.reduce_while(nil, fn item, _acc ->
      case item
           |> Map.get(:metadata, %{})
           |> map_value(@metadata_key)
           |> ensure_map()
           |> fun.() do
        nil -> {:cont, nil}
        value -> {:halt, value}
      end
    end)
  end

  defp last_message_context([]), do: %{}

  defp last_message_context(history) do
    history
    |> List.last()
    |> Map.get(:metadata, %{})
    |> map_value(@metadata_key)
    |> ensure_map()
  end

  defp actor_context(actor) do
    source = ensure_map(actor)

    key =
      text(source["userId"]) ||
        text(source["user_id"]) ||
        text(source["external_account_id"]) ||
        text(source["id"]) ||
        text(source["open_id"])

    display_name =
      text(source["fullName"]) ||
        text(source["full_name"]) ||
        text(source["userName"]) ||
        text(source["user_name"]) ||
        text(source["display_name"]) ||
        text(source["name"]) ||
        key

    %{
      key: slice(key, 160),
      display_name: slice(display_name, 160)
    }
  end

  defp room_context(room, actor_display_name) do
    source = ensure_map(room)
    id = text(source["id"])
    name = text(source["name"]) || text(source["title"])
    kind = text(source["kind"])
    is_dm = source["isDM"] == true || source["is_dm"] == true || kind == "im_dm"

    case id || name || actor_display_name do
      nil ->
        nil

      _value ->
        label =
          case is_dm do
            true -> "direct message with #{actor_display_name || name || id || "unknown user"}"
            false when is_binary(name) -> "group chat \"#{name}\""
            false -> "group chat #{id || "unknown"}"
          end

        %{id: id, is_dm: is_dm, label: label, name: name}
    end
  end

  defp normalize_sent_at(%DateTime{} = sent_at), do: sent_at

  defp normalize_sent_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, sent_at, _offset} -> sent_at
      _error -> nil
    end
  end

  defp normalize_sent_at(_value), do: nil

  defp normalize_context_line(value) do
    value
    |> text()
    |> case do
      nil -> nil
      value -> value |> String.replace(~r/\s+/, " ") |> slice(@max_context_line_text)
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp map_value(_value, _key), do: nil

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp text(_value), do: nil

  defp slice(nil, _length), do: nil
  defp slice(value, length), do: String.slice(value, 0, length)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp reject_nil(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
