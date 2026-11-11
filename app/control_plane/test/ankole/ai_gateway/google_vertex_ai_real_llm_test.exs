defmodule Ankole.AIGateway.GoogleVertexAIRealLLMTest do
  @moduledoc """
  Real-provider verification of the `google_vertex_ai` provider kind.

  Run with `ANKOLE_REAL_LLM_E2E=1 mix test --only real_llm` and
  `ANKOLE_VERTEX_SERVICE_ACCOUNT_FILE` pointing at a service-account JSON key
  whose account can call Vertex AI. `ANKOLE_VERTEX_MODEL` selects the model and
  `ANKOLE_VERTEX_LOCATION` the location; they default to `gemini-2.5-flash`
  and `global`.

  The first case sends a plain request with the safety threshold `OFF` and a
  `low` reasoning effort, which exercises the token exchange, the endpoint
  URL, the `google/` model prefix, and the Google-only `google` member.
  The second case streams a function call and replays every item of that round
  with the tool output, which fails when a Gemini thought signature is lost.
  """

  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.GoogleServiceAccount

  @moduletag :real_llm
  @moduletag timeout: 300_000

  setup do
    :ok = GoogleServiceAccount.clear_for_test()
    %{principal: agent} = agent_fixture()

    key_file =
      System.get_env("ANKOLE_VERTEX_SERVICE_ACCOUNT_FILE") ||
        raise "ANKOLE_VERTEX_SERVICE_ACCOUNT_FILE is required for the Vertex AI smoke"

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "vertex-real",
        provider_kind: "google_vertex_ai",
        connection_options: %{
          "vertex_location" => System.get_env("ANKOLE_VERTEX_LOCATION", "global"),
          "safety_threshold" => "OFF"
        },
        credential_pool: %{
          "entries" => [%{"label" => "Default", "service_account_key" => File.read!(key_file)}]
        }
      })

    {:ok, _profile} =
      ModelProfiles.put_model_profile(agent.uid, "primary", %{
        provider_id: "vertex-real",
        model: System.get_env("ANKOLE_VERTEX_MODEL", "gemini-2.5-flash"),
        provider_options: %{"reasoningEffort" => "low"}
      })

    %{agent: agent}
  end

  test "a plain request answers with safety settings and a reasoning effort", %{agent: agent} do
    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Reply with the single word PONG."
             })

    assert message_text(body["output"]) =~ "PONG"
  end

  test "a streamed function call round trip keeps the model's reasoning state", %{agent: agent} do
    user_message = %{
      "type" => "message",
      "role" => "user",
      "content" => [
        %{
          "type" => "input_text",
          "text" => "Call the get_weather tool for Paris, then tell me the temperature."
        }
      ]
    }

    tools = [
      %{
        "type" => "function",
        "name" => "get_weather",
        "description" => "Returns the current temperature of a city.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]
        }
      }
    ]

    {_events, outcome} =
      stream!(agent, %{
        "model" => "primary",
        "input" => [user_message],
        "tools" => tools,
        "stream" => true
      })

    assert outcome.terminal_error == nil
    call = Enum.find(outcome.public_items, &(&1["type"] == "function_call"))

    assert is_map(call),
           "round one produced no function_call: " <>
             inspect(Enum.map(outcome.public_items, & &1["type"]))

    {_events, final} =
      stream!(agent, %{
        "model" => "primary",
        "input" =>
          [user_message] ++
            outcome.public_items ++
            [
              %{
                "type" => "function_call_output",
                "call_id" => call["call_id"],
                "output" => "17 degrees Celsius"
              }
            ],
        "tools" => tools,
        "stream" => true
      })

    assert final.terminal_error == nil
    assert message_text(final.public_items) =~ "17"
  end

  defp stream!(agent, request) do
    {:ok, stream, _meta} = AIGateway.open_sse_stream(agent.uid, request)
    collect_events(stream, [])
  end

  # The stream may push its terminal batch and stop without waiting for more
  # demand, so a failed read drains the mailbox before giving up.
  defp collect_events(stream, events) do
    case AIGateway.read_response_stream(stream, 1) do
      :ok -> await_batch(stream, events, 180_000)
      {:error, _reason} -> await_batch(stream, events, 1_000)
    end
  end

  defp await_batch(stream, events, timeout) do
    receive do
      {:ai_gateway_response_stream, _ref, :events, batch, :continue} ->
        collect_events(stream, events ++ batch)

      {:ai_gateway_response_stream, _ref, :events, batch, {:terminal, outcome}} ->
        {events ++ batch, outcome}
    after
      timeout -> raise "real LLM stream ended without a terminal event"
    end
  end

  defp message_text(items) do
    items
    |> Enum.filter(&(&1["type"] == "message"))
    |> Enum.flat_map(&(&1["content"] || []))
    |> Enum.map_join(" ", &(&1["text"] || ""))
  end
end
