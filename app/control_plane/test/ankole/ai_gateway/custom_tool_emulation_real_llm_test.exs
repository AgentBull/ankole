defmodule Ankole.AIGateway.CustomToolEmulationRealLLMTest do
  @moduledoc """
  Real-provider verification of custom-tool emulation on the Responses wire.

  Set `ANKOLE_CUSTOM_TOOL_BASE_URL`, `ANKOLE_CUSTOM_TOOL_MODEL`, and
  `ANKOLE_CUSTOM_TOOL_API_KEY`, then opt in with `ANKOLE_REAL_LLM_E2E=1`.
  The configured upstream uses an `openai_compatible` Responses connection
  with `supports_openai_tools` at its default `false`, so AIGateway sends
  the declared custom tool as a function tool and restores the answer to the
  official custom shape. Round one must produce a `custom_tool_call`; round
  two replays that call with its output and must complete normally.
  """

  use Ankole.AIGatewayCase

  @moduletag :real_llm
  @moduletag timeout: 300_000

  test "emulated custom tool round trip on the configured upstream" do
    base_url = required_env!("ANKOLE_CUSTOM_TOOL_BASE_URL")
    model = required_env!("ANKOLE_CUSTOM_TOOL_MODEL")
    api_key = required_env!("ANKOLE_CUSTOM_TOOL_API_KEY")
    %{principal: agent} = agent_fixture()

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "custom-tool-emulation",
        provider_kind: "openai_compatible",
        base_url: base_url,
        connection_options: %{"endpoint_kind" => "responses"},
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => api_key}]}
      })

    {:ok, _profile} =
      ModelProfiles.put_model_profile(agent.uid, "primary", %{
        provider_id: "custom-tool-emulation",
        model: model
      })

    user_message = %{
      "type" => "message",
      "role" => "user",
      "content" => [
        %{
          "type" => "input_text",
          "text" =>
            "Call the run_note tool exactly once. Its input must be the plain text NOTE_OK. " <>
              "Do not answer in text before the tool call."
        }
      ]
    }

    tools = [
      %{
        "type" => "custom",
        "name" => "run_note",
        "description" => "Records one note. The input is the raw note text.",
        "format" => %{
          "type" => "grammar",
          "syntax" => "lark",
          "definition" => "start: /[\\s\\S]+/"
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

    call = Enum.find(outcome.public_items, &(&1["type"] == "custom_tool_call"))

    assert is_map(call),
           "round one produced no custom_tool_call: " <>
             inspect(Enum.map(outcome.public_items, & &1["type"]))

    assert call["name"] == "run_note"
    assert is_binary(call["input"]) and call["input"] != ""
    refute Map.has_key?(call, "arguments")

    {_events, final} =
      stream!(agent, %{
        "model" => "primary",
        "input" => [
          user_message,
          Map.take(call, ["type", "id", "call_id", "name", "input", "status"]),
          %{
            "type" => "custom_tool_call_output",
            "call_id" => call["call_id"],
            "output" => "Note recorded."
          },
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{
                "type" => "input_text",
                "text" => "Confirm in one short sentence that the note is recorded."
              }
            ]
          }
        ],
        "tools" => tools,
        "stream" => true
      })

    assert final.terminal_error == nil

    text =
      final.public_items
      |> Enum.filter(&(&1["type"] == "message"))
      |> Enum.flat_map(&(&1["content"] || []))
      |> Enum.map(&(&1["text"] || ""))
      |> Enum.join(" ")

    assert String.trim(text) != "", "round two returned no message text"
  end

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _missing -> raise "#{name} is required for the custom-tool emulation smoke"
    end
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
end
