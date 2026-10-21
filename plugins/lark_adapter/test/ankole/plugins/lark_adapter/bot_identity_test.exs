defmodule Ankole.Plugins.LarkAdapter.BotIdentityTest do
  use ExUnit.Case, async: false

  alias Ankole.Plugins.LarkAdapter.BotIdentity
  alias Ankole.Plugins.LarkAdapter.Config
  alias FeishuOpenAPI.Client
  alias FeishuOpenAPI.TokenStore

  @config %{
    "appID" => "cli_bot_identity",
    "appSecret" => "secret",
    "domain" => "feishu",
    "identityProvider" => nil,
    "userName" => "Lark / Feishu"
  }

  setup do
    previous = Application.fetch_env(:ankole, Config)

    Application.put_env(:ankole, Config,
      client_opts: [req_options: [plug: {Req.Test, __MODULE__}, retry: false]]
    )

    token_key = {:tenant, Client.cache_namespace(Config.client(@config)), nil}
    :ets.insert(TokenStore.table(), {token_key, "t-token", :infinity})

    on_exit(fn ->
      :ets.delete(TokenStore.table(), token_key)

      case previous do
        {:ok, value} -> Application.put_env(:ankole, Config, value)
        :error -> Application.delete_env(:ankole, Config)
      end
    end)

    start_supervised!(BotIdentity)
    :ok
  end

  test "a resolved open_id is served from the cache without another provider call" do
    stub_bot_info(fn conn -> bot_info(conn, "ou_cached") end)

    assert {:ok, "ou_cached"} = BotIdentity.resolve(@config)
    assert {:ok, "ou_cached"} = BotIdentity.resolve(@config)
    assert_received :bot_info_requested
    refute_received :bot_info_requested
  end

  test "a rate-limited lookup is cached until the provider's retry time" do
    responses = :counters.new(1, [])

    stub_bot_info(fn conn ->
      :counters.add(responses, 1, 1)

      # The SDK retries one rate-limited response at once; the final response
      # names the delay that the cache must respect.
      header =
        if :counters.get(responses, 1) == 1,
          do: {"x-ogw-ratelimit-reset", "0"},
          else: {"retry-after", "120"}

      conn
      |> Plug.Conn.put_resp_header(elem(header, 0), elem(header, 1))
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"code" => 99_991_400, "msg" => "rate"})
    end)

    assert {:error, %{attempt: 1, retry_at: retry_at, reason: reason} = failure} =
             BotIdentity.resolve(@config)

    assert %FeishuOpenAPI.Error{code: :rate_limited, retry_after_ms: 120_000} = reason
    assert_in_delta DateTime.diff(retry_at, DateTime.utc_now()), 120, 3
    assert_received :bot_info_requested
    assert_received :bot_info_requested

    assert BotIdentity.describe(failure) ==
             "Lark bot identity unavailable: rate limited (HTTP 429, code 99991400) after retry (code :rate_limited)"

    assert {:error, ^failure} = BotIdentity.resolve(@config)
    refute_received :bot_info_requested
  end

  test "a provider delay longer than the backoff ceiling is limited to 30 minutes" do
    responses = :counters.new(1, [])

    stub_bot_info(fn conn ->
      :counters.add(responses, 1, 1)

      header =
        if :counters.get(responses, 1) == 1,
          do: {"x-ogw-ratelimit-reset", "0"},
          else: {"retry-after", "86400"}

      conn
      |> Plug.Conn.put_resp_header(elem(header, 0), elem(header, 1))
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"code" => 99_991_400, "msg" => "rate"})
    end)

    assert {:error, %{attempt: 1, retry_at: retry_at, reason: reason}} =
             BotIdentity.resolve(@config)

    assert %FeishuOpenAPI.Error{retry_after_ms: 86_400_000} = reason
    assert_in_delta DateTime.diff(retry_at, DateTime.utc_now()), 30 * 60, 3
  end

  test "a failure without a provider delay backs off from one minute and doubles per attempt" do
    stub_bot_info(fn conn -> Req.Test.json(conn, %{"code" => 1_000, "msg" => "boom"}) end)

    assert {:error, %{attempt: 1, retry_at: first}} = BotIdentity.resolve(@config)
    assert_in_delta DateTime.diff(first, DateTime.utc_now()), 60, 3
    assert_received :bot_info_requested

    expire_cached_entry()
    assert {:error, %{attempt: 2, retry_at: second}} = BotIdentity.resolve(@config)
    assert_in_delta DateTime.diff(second, DateTime.utc_now()), 120, 3
    assert_received :bot_info_requested

    expire_cached_entry()
    assert {:error, %{attempt: 3, retry_at: third}} = BotIdentity.resolve(@config)
    assert_in_delta DateTime.diff(third, DateTime.utc_now()), 240, 3

    :ok = BotIdentity.forget(@config)
    assert {:error, %{attempt: 1}} = BotIdentity.resolve(@config)
  end

  test "a response without a bot open_id is a cached failure" do
    stub_bot_info(fn conn -> Req.Test.json(conn, %{"code" => 0, "msg" => "ok", "bot" => %{}}) end)

    assert {:error, %{reason: :missing_bot_open_id, attempt: 1}} = BotIdentity.resolve(@config)
    assert {:error, %{reason: :missing_bot_open_id, attempt: 1}} = BotIdentity.resolve(@config)
    assert_received :bot_info_requested
    refute_received :bot_info_requested
  end

  defp stub_bot_info(respond) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn %{request_path: "/open-apis/bot/v3/info"} = conn ->
      send(test_pid, :bot_info_requested)
      respond.(conn)
    end)
  end

  defp bot_info(conn, open_id),
    do: Req.Test.json(conn, %{"code" => 0, "msg" => "ok", "bot" => %{"open_id" => open_id}})

  # Moves the cached entry's expiry into the past; the attempt count stays.
  defp expire_cached_entry do
    key = Config.connection_key(@config)
    [{^key, value, _expires_at}] = :ets.lookup(BotIdentity.table(), key)
    :ets.insert(BotIdentity.table(), {key, value, System.monotonic_time(:millisecond) - 1})
  end
end
