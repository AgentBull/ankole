defmodule BullXTelegram.ConfigTest do
  use ExUnit.Case, async: true

  alias BullX.Config.GeneratedSecret
  alias BullXTelegram.{Config, Error}

  defmodule ApiStub do
    def request(token, method, params) do
      requests = Process.get(:telegram_api_requests, [])
      Process.put(:telegram_api_requests, requests ++ [{token, method, params}])

      case Process.get(:telegram_api_responses, []) do
        [response | rest] ->
          Process.put(:telegram_api_responses, rest)
          response

        [] ->
          {:ok, %{}}
      end
    end
  end

  test "normalizes polling config without requiring webhook secret" do
    assert {:ok, config} =
             Config.normalize({:telegram, "default"}, %{
               bot_token: " token ",
               bot_username: "@BullXBot",
               poll_timeout_s: "20",
               poll_limit: "50",
               attention: %{ignored_chat_ids: [123, "456"]}
             })

    assert config.channel == {:telegram, "default"}
    assert config.bot_token == "token"
    assert config.bot_username == "BullXBot"
    assert config.transport.mode == "polling"
    assert config.transport.secret_token == nil
    assert config.poll_timeout_s == 20
    assert config.poll_limit == 50
    assert config.attention.ignored_chat_ids == ["123", "456"]
  end

  test "webhook mode requires a valid generated secret" do
    assert {:error, %{"details" => %{"field" => "transport.secret_token"}}} =
             Config.normalize({:telegram, "default"}, %{
               bot_token: "token",
               transport: %{mode: "webhook"}
             })

    secret = GeneratedSecret.generate()

    assert {:ok, %Config{transport: %{mode: "webhook", secret_token: ^secret}}} =
             Config.normalize({:telegram, "default"}, %{
               bot_token: "token",
               transport: %{mode: "webhook", secret_token: secret}
             })
  end

  test "inspect output redacts Telegram secrets" do
    secret = GeneratedSecret.generate()

    {:ok, config} =
      Config.normalize({:telegram, "default"}, %{
        bot_token: "bot-secret",
        transport: %{mode: "webhook", secret_token: secret}
      })

    inspected = inspect(config)

    refute inspected =~ "bot-secret"
    refute inspected =~ secret
  end

  test "request retries bounded Telegram flood-control waits" do
    Process.put(:telegram_api_responses, [
      {:error, %{"kind" => "rate_limited", "details" => %{"retry_after_ms" => 1}}},
      {:ok, %{"message_id" => 1}}
    ])

    {:ok, config} =
      Config.normalize({:telegram, "default"}, %{
        bot_token: "bot",
        api_module: ApiStub,
        flood_wait_max_ms: 10
      })

    assert {:ok, %{"message_id" => 1}} = Config.request(config, "sendMessage", text: "hello")

    assert Process.get(:telegram_api_requests) == [
             {"bot", "sendMessage", [text: "hello"]},
             {"bot", "sendMessage", [text: "hello"]}
           ]
  end

  test "request returns long Telegram flood-control waits as retryable errors" do
    error = "Too Many Requests: retry after 1"
    Process.put(:telegram_api_responses, [{:error, error}])

    {:ok, config} =
      Config.normalize({:telegram, "default"}, %{
        bot_token: "bot",
        api_module: ApiStub,
        flood_wait_max_ms: 0
      })

    assert {:error, ^error} = Config.request(config, "sendMessage", text: "hello")

    assert %{"kind" => "rate_limited", "details" => %{"retry_after_ms" => 1_000}} =
             Error.map(error)

    assert Process.get(:telegram_api_requests) == [{"bot", "sendMessage", [text: "hello"]}]
  end
end
