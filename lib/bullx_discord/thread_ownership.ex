defmodule BullXDiscord.ThreadOwnership do
  @moduledoc """
  Resolves BullX-owned Discord threads without BullX-local persistence.
  """

  alias BullXDiscord.{Cache, Config, Error}

  @thread_types [10, 11, 12]
  @guild_text_types [0, 5]

  @spec owned?(term(), Config.t(), Cache.t()) ::
          {:ok, boolean(), Cache.t()} | {:error, map(), Cache.t()}
  def owned?(thread_channel_id, %Config{} = config, %Cache{} = cache) do
    thread_channel_id = id_string(thread_channel_id)

    case Cache.fetch_thread_ownership(cache, config.channel_id, thread_channel_id) do
      {:ok, owned?} ->
        {:ok, owned?, cache}

      :error ->
        resolve_owned(thread_channel_id, config, cache)
    end
  end

  @spec guild_text_channel?(term(), Config.t()) :: {:ok, boolean()} | {:error, map()}
  def guild_text_channel?(channel_id, %Config{} = config) do
    with {:ok, channel} <- fetch_channel(channel_id, config) do
      {:ok, channel_type(channel) in @guild_text_types}
    end
  end

  @spec thread_channel?(term(), Config.t()) :: {:ok, boolean()} | {:error, map()}
  def thread_channel?(channel_id, %Config{} = config) do
    with {:ok, channel} <- fetch_channel(channel_id, config) do
      {:ok, channel_type(channel) in @thread_types}
    end
  end

  @spec mark_owned(Cache.t(), Config.t(), term()) :: Cache.t()
  def mark_owned(%Cache{} = cache, %Config{} = config, thread_channel_id) do
    Cache.put_thread_ownership(
      cache,
      config.channel_id,
      id_string(thread_channel_id),
      true,
      config.thread_ownership_cache_ttl_ms
    )
  end

  @spec fetch_channel(term(), Config.t()) :: {:ok, term()} | {:error, map()}
  def fetch_channel(channel_id, %Config{} = config) do
    Config.with_bot(config, fn ->
      config.channel_api.get(snowflake(channel_id))
    end)
    |> case do
      {:ok, channel} -> {:ok, channel}
      {:error, error} -> {:error, Error.map(error)}
      error -> {:error, Error.map(error)}
    end
  end

  defp resolve_owned(thread_channel_id, config, cache) do
    case fetch_channel(thread_channel_id, config) do
      {:ok, channel} ->
        owned? =
          channel_type(channel) in @thread_types and owner_id(channel) == bot_user_id(config)

        cache =
          Cache.put_thread_ownership(
            cache,
            config.channel_id,
            thread_channel_id,
            owned?,
            config.thread_ownership_cache_ttl_ms
          )

        {:ok, owned?, cache}

      {:error, error} ->
        {:error, error, cache}
    end
  end

  defp channel_type(%{type: type}), do: type
  defp channel_type(%{"type" => type}), do: type
  defp channel_type(_channel), do: nil

  defp owner_id(%{owner_id: owner_id}), do: id_string(owner_id)
  defp owner_id(%{"owner_id" => owner_id}), do: id_string(owner_id)
  defp owner_id(_channel), do: nil

  defp bot_user_id(%Config{bot_user_id: bot_user_id}), do: id_string(bot_user_id)

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
