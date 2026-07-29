defmodule Ankole.AIGateway.RequestContextTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.RequestContext

  test "all stable cache identifiers also become credential affinity keys" do
    cases = [
      {%{}, %{"prompt_cache_key" => "prompt-cache"}, "prompt-cache"},
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
end
