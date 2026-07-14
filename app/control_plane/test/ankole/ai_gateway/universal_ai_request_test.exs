defmodule Ankole.AIGateway.UniversalAIRequestTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.UniversalAIRequest

  test "non-stream model specs include a high-thinking timeout cap" do
    assert {:ok, spec} =
             request(stream?: false)
             |> UniversalAIRequest.to_spec()

    assert spec.upstream.timeout == %{
             connect_ms: 60_000,
             first_byte_ms: 1_800_000,
             idle_ms: 1_800_000,
             total_ms: 1_800_000
           }
  end

  test "stream model specs use the model no-activity budget without a total timeout" do
    assert {:ok, spec} =
             request(stream?: true)
             |> UniversalAIRequest.to_spec()

    assert spec.upstream.timeout == %{
             connect_ms: 60_000,
             first_byte_ms: 1_800_000,
             idle_ms: 1_800_000,
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

  test "credential header helpers omit missing optional settings" do
    request = request(stream?: false)

    bearer_request =
      Task.async(fn -> UniversalAIRequest.bearer_auth(request) end)
      |> Task.await(100)

    api_key_request =
      Task.async(fn -> UniversalAIRequest.api_key_header(request, "x-api-key") end)
      |> Task.await(100)

    assert bearer_request.headers == []
    assert api_key_request.headers == []
  end

  test "credential header helpers preserve configured settings" do
    request = request(stream?: false, api_key: "secret")

    assert UniversalAIRequest.bearer_auth(request).headers == [
             {"authorization", "Bearer secret"}
           ]

    assert UniversalAIRequest.api_key_header(request, "x-api-key").headers == [
             {"x-api-key", "secret"}
           ]
  end

  defp request(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms)

    capability =
      %{upstream: :sse}
      |> maybe_put(:timeout_ms, timeout_ms)

    ctx = %{
      capability: capability,
      settings:
        %{base_url: "https://api.example.test/v1"}
        |> maybe_put(:api_key, Keyword.get(opts, :api_key)),
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
