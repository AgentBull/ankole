defmodule Discord.ThreadOwnership do
  @moduledoc """
  Resolves whether a Discord thread is BullX-owned, used by attention policy
  and the auto-thread branch of the publish pipeline.

  Ownership is reconstructed from Discord channel metadata (`owner_id` ==
  bot user id) plus a bounded `BullX.Cache` accelerator. There is no BullX
  persistence for thread ownership; on restart the cache is empty and the
  next in-thread message re-resolves through Discord REST.

  Auto-thread creation for accepted guild text-channel mentions and `/ask`
  invocations happens here as well, before the input is published.
  """

  alias Discord.{Error, Source}

  @thread_types [10, 11, 12]
  @guild_text_types [0, 5]

  @spec owned?(String.t() | term(), Source.t()) :: {:ok, boolean()} | {:error, map()}
  def owned?(thread_channel_id, %Source{} = source) do
    thread_channel_id = id_string(thread_channel_id)

    if thread_channel_id in [nil, ""] do
      {:ok, false}
    else
      case BullX.Cache.get(cache_key(source, thread_channel_id)) do
        {:ok, value} when is_boolean(value) -> {:ok, value}
        {:error, :not_found} -> resolve_owned(thread_channel_id, source)
        {:error, _reason} -> resolve_owned(thread_channel_id, source)
      end
    end
  end

  @spec mark_owned(Source.t(), String.t()) :: :ok
  def mark_owned(%Source{} = source, thread_channel_id) do
    BullX.Cache.put(
      cache_key(source, id_string(thread_channel_id)),
      true,
      source.thread_ownership_cache_ttl_seconds
    )

    :ok
  end

  @doc """
  Runs the auto-thread branch for an accepted guild text-channel mention or
  `/ask` invocation. Returns `{:ok, mapped}` with `mapped.input.scope_id`
  rewritten to the new thread channel id when a thread is created, or the
  mapped value unchanged when auto-thread does not apply.

  Reports thread creation telemetry. Failures return `{:error, error}` so the
  caller can surface a localized error to the user without publishing.
  """
  @spec maybe_auto_thread(map(), Source.t()) :: {:ok, map()} | {:error, map()}
  def maybe_auto_thread(%{} = mapped, %Source{} = source) do
    cond do
      not auto_thread_enabled?(mapped, source) ->
        {:ok, mapped}

      true ->
        case guild_text_channel?(mapped.context[:discord_channel_id], source) do
          {:ok, true} -> create_thread(mapped, source)
          {:ok, false} -> {:ok, mapped}
          {:error, error} -> {:error, error}
        end
    end
  end

  @spec guild_text_channel?(String.t() | term(), Source.t()) ::
          {:ok, boolean()} | {:error, map()}
  def guild_text_channel?(channel_id, %Source{} = source) do
    channel_id = id_string(channel_id)

    if channel_id in [nil, ""] do
      {:ok, false}
    else
      case fetch_channel(channel_id, source) do
        {:ok, channel} -> {:ok, channel_type(channel) in @guild_text_types}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp create_thread(%{} = mapped, %Source{} = source) do
    parent_channel_id = mapped.context[:discord_channel_id]
    message_id = mapped.context[:message_id]
    name = thread_name(mapped)

    options = %{
      name: name,
      auto_archive_duration: source.auto_thread["auto_archive_duration_minutes"]
    }

    result =
      Source.with_bot(source, fn ->
        if is_binary(message_id) and message_id != "" do
          source.thread_api.create_with_message(
            snowflake(parent_channel_id),
            snowflake(message_id),
            options
          )
        else
          source.thread_api.create(snowflake(parent_channel_id), options)
        end
      end)

    case result do
      {:ok, thread} ->
        thread_id = id_string(field(thread, :id))
        :ok = mark_owned(source, thread_id)

        :telemetry.execute(
          [:bullx, :discord, :thread, :created],
          %{count: 1},
          %{channel_id: source.channel_id, thread_id: thread_id}
        )

        {:ok, rewrite_scope(mapped, thread_id)}

      {:error, error} ->
        {:error,
         Error.payload("Discord thread creation failed", %{
           "discord_error" => Map.get(Error.map(error), "message"),
           "parent_channel_id" => parent_channel_id
         })}
    end
  end

  defp rewrite_scope(mapped, new_scope_id) when is_binary(new_scope_id) do
    input = mapped.input
    reply_channel = Map.put(Map.get(input, "reply_channel", %{}), "scope_id", new_scope_id)

    refs =
      (Map.get(input, "refs") || []) ++
        [%{"kind" => "discord.thread", "id" => new_scope_id}]

    input =
      input
      |> Map.put("scope_id", new_scope_id)
      |> Map.put("reply_channel", reply_channel)
      |> Map.put("refs", refs)

    context =
      Map.merge(mapped.context, %{
        scope_id: new_scope_id,
        thread_channel_id: new_scope_id
      })

    %{mapped | input: input, context: context}
  end

  defp auto_thread_enabled?(%{auto_thread?: true}, %Source{auto_thread: %{"enabled" => true}}),
    do: true

  defp auto_thread_enabled?(_mapped, _source), do: false

  defp thread_name(%{} = mapped) do
    mapped.input
    |> Map.get("content", [])
    |> primary_text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> "BullX"
      value -> String.slice(value, 0, 80)
    end
  end

  defp primary_text([%{"kind" => "text", "body" => %{"text" => text}} | _]) when is_binary(text),
    do: text

  defp primary_text([_ | rest]), do: primary_text(rest)
  defp primary_text(_other), do: ""

  defp fetch_channel(channel_id, %Source{} = source) do
    Source.with_bot(source, fn -> source.channel_api.get(snowflake(channel_id)) end)
    |> case do
      {:ok, channel} -> {:ok, channel}
      {:error, error} -> {:error, Error.map(error)}
      other -> {:error, Error.map(other)}
    end
  end

  defp resolve_owned(thread_channel_id, %Source{} = source) do
    case fetch_channel(thread_channel_id, source) do
      {:ok, channel} ->
        owned? =
          channel_type(channel) in @thread_types and owner_id(channel) == source.bot_user_id

        BullX.Cache.put(
          cache_key(source, thread_channel_id),
          owned?,
          source.thread_ownership_cache_ttl_seconds
        )

        :telemetry.execute(
          [:bullx, :discord, :thread, :ownership_resolved],
          %{count: 1},
          %{channel_id: source.channel_id, owned?: owned?}
        )

        {:ok, owned?}

      {:error, error} ->
        {:error, error}
    end
  end

  defp cache_key(%Source{channel_id: channel_id}, thread_channel_id) do
    "discord:#{channel_id}:thread_ownership:#{thread_channel_id}"
  end

  defp channel_type(%{type: type}), do: type
  defp channel_type(%{"type" => type}), do: type
  defp channel_type(_channel), do: nil

  defp owner_id(channel) do
    case field(channel, :owner_id) do
      nil -> nil
      value -> id_string(value)
    end
  end

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

  defp snowflake(value) when is_integer(value), do: value

  defp snowflake(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> value
    end
  end

  defp snowflake(value), do: value

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)
end
