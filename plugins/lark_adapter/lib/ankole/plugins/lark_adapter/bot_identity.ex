defmodule Ankole.Plugins.LarkAdapter.BotIdentity do
  @moduledoc """
  Resolves and caches the bot `open_id` of one Lark app.

  Group mention events carry the mentioned bot's `open_id`, so a chat consumer
  must know its own. The Console never asks for it: the connection owner reads
  it from `bot/v3/info` with the app credentials when it starts. This module
  owns the per `{domain, appID}` cache in a public ETS table, so the periodic
  reconcile pass and owner restarts do not call the provider again.

  A resolved `open_id` is kept for 24 hours. A failure is kept until its retry
  time: the provider's `Retry-After` or `x-ogw-ratelimit-reset` delay when the
  response named one, else an exponential backoff of 1, 2, 4, 8, 16, and then
  30 minutes between attempts. Both are limited to 30 minutes. While a failure
  is cached, `resolve/1` returns it without a provider call. A saved binding
  configuration removes the entry through `forget/1`.
  """

  use GenServer

  alias Ankole.Logging
  alias Ankole.Plugins.LarkAdapter.Config

  @table :ankole_lark_bot_identity
  @success_ttl_ms :timer.hours(24)
  @max_backoff_ms :timer.minutes(30)

  @typedoc "A cached failure: why the last attempt failed and when the next one may run."
  @type failure :: %{reason: term(), attempt: pos_integer(), retry_at: DateTime.t()}

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts) do
    IMTransport.TokenCache.ensure_table(@table)
    {:ok, %{}}
  end

  @spec table() :: atom()
  def table, do: @table

  @doc """
  Returns the bot `open_id` of the app in `config`, from the cache when the
  cached entry is still valid, else from `bot/v3/info`.
  """
  @spec resolve(Config.chat_config()) :: {:ok, String.t()} | {:error, failure()}
  def resolve(config) when is_map(config) do
    key = Config.connection_key(config)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, {:ok, open_id}, expires_at}] when now < expires_at -> {:ok, open_id}
      [{^key, {:error, failure}, expires_at}] when now < expires_at -> {:error, failure}
      [{^key, {:error, failure}, _expired}] -> fetch(config, key, failure.attempt)
      _missing_or_expired -> fetch(config, key, 0)
    end
  end

  @doc "Removes the cached entry of the app in `config`."
  @spec forget(Config.chat_config()) :: :ok
  def forget(config) when is_map(config) do
    :ets.delete(@table, Config.connection_key(config))
    :ok
  end

  @doc """
  Formats a cached failure for operators. The text is stable across attempts
  of one failure kind; the retry time stays in `failure.retry_at`.
  """
  @spec describe(failure()) :: String.t()
  def describe(%{reason: reason}), do: "Lark bot identity unavailable: #{reason_text(reason)}"

  defp fetch(config, key, previous_attempts) do
    case fetch_bot_open_id(config) do
      {:ok, open_id} ->
        :ets.insert(@table, {key, {:ok, open_id}, monotonic_ms() + @success_ttl_ms})
        {:ok, open_id}

      {:error, reason} ->
        attempt = previous_attempts + 1
        delay_ms = min(retry_after_ms(reason) || backoff_ms(attempt), @max_backoff_ms)

        failure = %{
          reason: reason,
          attempt: attempt,
          retry_at:
            DateTime.utc_now()
            |> DateTime.add(delay_ms, :millisecond)
            |> DateTime.truncate(:second)
        }

        :ets.insert(@table, {key, {:error, failure}, monotonic_ms() + delay_ms})

        Logging.warning(
          "lark_adapter.bot_identity.resolve_failed",
          "lark adapter could not resolve the bot open_id",
          %{
            app_id: Map.get(config, "appID"),
            domain: Map.get(config, "domain"),
            reason: inspect(reason),
            attempt: attempt,
            retry_at: DateTime.to_iso8601(failure.retry_at)
          }
        )

        {:error, failure}
    end
  end

  defp fetch_bot_open_id(config) do
    case FeishuOpenAPI.get(Config.client(config), "bot/v3/info") do
      {:ok, %{"bot" => %{"open_id" => open_id}}} when is_binary(open_id) ->
        case String.trim(open_id) do
          "" -> {:error, :missing_bot_open_id}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _body} ->
        {:error, :missing_bot_open_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_after_ms(%FeishuOpenAPI.Error{retry_after_ms: ms}) when is_integer(ms) and ms > 0,
    do: ms

  defp retry_after_ms(_reason), do: nil

  defp backoff_ms(attempt),
    do: min(:timer.minutes(Integer.pow(2, attempt - 1)), @max_backoff_ms)

  # The provider log id changes per response and stays out of the text.
  defp reason_text(%FeishuOpenAPI.Error{code: code, msg: msg}) when is_binary(msg),
    do: "#{msg} (code #{inspect(code)})"

  defp reason_text(%FeishuOpenAPI.Error{code: code}), do: "code #{inspect(code)}"
  defp reason_text(reason), do: inspect(reason)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
