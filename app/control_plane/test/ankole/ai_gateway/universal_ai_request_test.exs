defmodule Ankole.AIGateway.UniversalAIRequestTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.UniversalAIRequest

  test "non-stream model specs include a high-thinking timeout cap" do
    assert {:ok, spec} =
             request(stream?: false)
             |> UniversalAIRequest.to_spec()

    assert spec.upstream.timeout == %{
             connect_ms: 60_000,
             first_byte_ms: 300_000,
             idle_ms: 300_000,
             total_ms: 300_000
           }
  end

  test "stream model specs keep total timeout unset" do
    assert {:ok, spec} =
             request(stream?: true)
             |> UniversalAIRequest.to_spec()

    assert spec.upstream.timeout == %{
             connect_ms: 60_000,
             first_byte_ms: 60_000,
             idle_ms: 60_000,
             total_ms: nil
           }
  end

  test "capability timeout overrides the non-stream total cap" do
    assert {:ok, spec} =
             request(stream?: false, timeout_ms: 240_000)
             |> UniversalAIRequest.to_spec()

    assert spec.upstream.timeout == %{
             connect_ms: 240_000,
             first_byte_ms: 240_000,
             idle_ms: 240_000,
             total_ms: 240_000
           }
  end

  test "request-local provider options override context provider options" do
    assert {:ok, spec} =
             request(stream?: false)
             |> UniversalAIRequest.put_provider_options(%{"reasoningEffort" => "minimal"})
             |> UniversalAIRequest.to_spec()

    assert spec.response_context.provider_options == %{"reasoningEffort" => "minimal"}
  end

  defp request(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms)

    capability =
      %{upstream: :sse}
      |> maybe_put(:timeout_ms, timeout_ms)

    ctx = %{
      capability: capability,
      settings: %{base_url: "https://api.example.test/v1"},
      model: "test-model",
      request: %{"input" => "hello"},
      provider_options: %{},
      stream?: Keyword.fetch!(opts, :stream?)
    }

    UniversalAIRequest.new(ctx, "responses", :openai_responses)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
