defmodule Ankole.AIGateway.RequestContextTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.RequestContext

  test "forwards the official OpenRouter session header" do
    context =
      RequestContext.from_headers(
        [{"X-Session-ID", "openrouter-session"}, {"authorization", "secret"}],
        "http"
      )

    assert context["headers"] == %{"x-session-id" => "openrouter-session"}
  end

  test "forwards W3C traceparent without forwarding authorization" do
    traceparent = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"

    context =
      RequestContext.from_headers(
        [{"traceparent", traceparent}, {"authorization", "secret"}],
        "http"
      )

    assert context["headers"] == %{"traceparent" => traceparent}
  end

  test "decodes valid observability user carriers into the trusted request context" do
    traceparent = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"

    Enum.each(
      [
        {carrier("principal:human-1"), "principal:human-1"},
        {carrier("channel:钉钉:群聊一"), "channel:钉钉:群聊一"},
        {"none", nil}
      ],
      fn {header_value, expected} ->
        context =
          RequestContext.from_headers(
            [
              {"X-Ankole-Observability-User-ID", header_value},
              {"traceparent", traceparent}
            ],
            "http"
          )

        assert Map.fetch!(context, "observability_user_id") == expected
        assert RequestContext.observability_user_id(context) == {:ok, expected}
        assert context["headers"] == %{"traceparent" => traceparent}
      end
    )
  end

  test "rejects malformed observability user carriers and accepts 200 Unicode codepoints" do
    malformed_carriers = [
      "",
      "principal:human-1",
      carrier("principal:"),
      carrier("channel:"),
      carrier("agent-1"),
      carrier(" principal:human-1"),
      carrier("principal:human-1\nchannel:forged"),
      carrier("principal:" <> String.duplicate("a", 191)),
      Base.url_encode64(<<255>>, padding: false)
    ]

    Enum.each(malformed_carriers, fn value ->
      context =
        RequestContext.from_headers(
          [{"x-ankole-observability-user-id", value}],
          "http"
        )

      refute Map.has_key?(context, "observability_user_id")
      assert RequestContext.observability_user_id(context) == :missing
    end)

    accepted = "principal:" <> String.duplicate("界", 190)
    assert length(String.codepoints(accepted)) == 200
    assert byte_size(accepted) > 200

    assert RequestContext.from_headers(
             [{"x-ankole-observability-user-id", carrier(accepted)}],
             "http"
           )["observability_user_id"] == accepted

    rejected = accepted <> "a"

    refute Map.has_key?(
             RequestContext.from_headers(
               [{"x-ankole-observability-user-id", carrier(rejected)}],
               "http"
             ),
             "observability_user_id"
           )
  end

  test "all stable cache identifiers also become credential affinity keys" do
    cases = [
      {%{}, %{"prompt_cache_key" => "prompt-cache"}, "prompt-cache"},
      {%{}, %{"session_id" => "body-session"}, "body-session"},
      {%{"headers" => %{"x-session-id" => "official-session"}}, %{}, "official-session"},
      {%{"headers" => %{"session_id" => "session-underscore"}}, %{}, "session-underscore"},
      {%{"headers" => %{"session-id" => "session-hyphen"}}, %{}, "session-hyphen"},
      {%{"headers" => %{"thread-id" => "thread-header"}}, %{}, "thread-header"},
      {%{}, %{"metadata" => %{"conversation_id" => "conversation-metadata"}},
       "conversation-metadata"},
      {%{}, %{"metadata" => %{"thread_id" => "thread-metadata"}}, "thread-metadata"},
      {%{}, %{"metadata" => %{"session_id" => "session-metadata"}}, "session-metadata"}
    ]

    Enum.each(cases, fn {context, request, expected} ->
      prepared = RequestContext.prepare(context, request)
      assert prepared["cache_key"] == expected
      assert prepared["affinity_key"] == expected
    end)
  end

  test "stateless HTTP requests do not get affinity and WebSocket requests do" do
    http = RequestContext.prepare(%{"downstream_transport" => "http"}, %{})
    assert is_binary(http["cache_key"])
    refute Map.has_key?(http, "affinity_key")

    websocket = RequestContext.prepare(%{"downstream_transport" => "websocket"}, %{})
    assert websocket["affinity_key"] == websocket["cache_key"]
  end

  test "prompt cache routing stays separate from the trace session" do
    request = %{
      "prompt_cache_key" => "shared-prefix",
      "session_id" => "conversation-1"
    }

    prepared = RequestContext.prepare(%{}, request)

    assert prepared["cache_key"] == "shared-prefix"
    assert prepared["affinity_key"] == "shared-prefix"
    assert RequestContext.session_key(%{}, request) == "conversation-1"
    assert RequestContext.session_key(%{}, %{"prompt_cache_key" => "shared-prefix"}) == nil
  end

  defp carrier(user_id), do: Base.url_encode64(user_id, padding: false)
end
