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
end
