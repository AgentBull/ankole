defmodule Ankole.AIGateway.CodexVisionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ankole.AIGateway.CodexVision

  test "passes images directly only when the frozen main model supports them" do
    request = request_with_images(["text", "image"], nil)

    assert {:ok, adapted} =
             CodexVision.adapt("agent-1", request,
               request_fallback: fn _subject_uid, _request ->
                 flunk("fallback must not run for a vision-capable main model")
               end
             )

    refute Map.has_key?(adapted, "__ankole_codex_vision")
    assert image_parts(adapted) |> length() == 2
  end

  test "replaces images with one untrusted summary from the frozen fallback" do
    fallback = %{
      "selector" => "openrouter-vision/google/gemini-3-flash-preview",
      "provider_options" => %{"serviceTier" => "priority"},
      "input_modalities" => ["text", "image"]
    }

    request = request_with_images(["text"], fallback)

    assert {:ok, adapted} =
             CodexVision.adapt("agent-1", request,
               request_fallback: fn subject_uid, fallback_request ->
                 assert subject_uid == "agent-1"
                 assert fallback_request["model"] == fallback["selector"]
                 assert fallback_request["provider_options"] == fallback["provider_options"]
                 assert length(image_parts(fallback_request)) == 2
                 assert fallback_request["instructions"] =~ "untrusted data"

                 {:ok,
                  %{
                    body: %{
                      "output" => [
                        %{
                          "type" => "message",
                          "content" => [
                            %{"type" => "output_text", "text" => "A chart and its legend."}
                          ]
                        }
                      ]
                    }
                  }}
               end
             )

    assert image_parts(adapted) == []
    refute Map.has_key?(adapted, "__ankole_codex_vision")

    text = all_text(adapted)
    assert text =~ "untrusted image content"
    assert text =~ "A chart and its legend."
    assert text =~ "additional image covered"
  end

  test "keeps the turn context on the nested fallback request" do
    {:module, Ankole.AIGateway} = Code.ensure_loaded(Ankole.AIGateway)

    assert 1 =
             :erlang.trace_pattern(
               {Ankole.AIGateway, :create_response, 3},
               true,
               []
             )

    request_context = %{
      "headers" => %{"traceparent" => "test-parent"},
      "observability_user_id" => "principal:user-1"
    }

    pid =
      spawn(fn ->
        receive do
          :adapt ->
            CodexVision.adapt(
              "agent-1",
              request_with_images(["text"], fallback_binding()),
              request_context: request_context,
              subject_type: "agent",
              caller: "outer_caller",
              unrelated: "not_forwarded"
            )
        end
      end)

    assert 1 = :erlang.trace(pid, true, [:call])

    try do
      send(pid, :adapt)

      assert_receive {:trace, ^pid, :call,
                      {Ankole.AIGateway, :create_response,
                       ["agent-1", _fallback_request, fallback_opts]}}

      assert length(fallback_opts) == 3

      assert Map.new(fallback_opts) == %{
               caller: "codex_vision",
               request_context: request_context,
               subject_type: "agent"
             }
    after
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :erlang.trace_pattern({Ankole.AIGateway, :create_response, 3}, false, [])
    end
  end

  test "never leaks images to a text model when fallback is absent or fails" do
    for fallback <- [nil, fallback_binding()] do
      request = request_with_images(["text"], fallback)

      assert {:ok, adapted} =
               CodexVision.adapt("agent-1", request,
                 request_fallback: fn _subject_uid, _request ->
                   {:error, :upstream_unavailable}
                 end
               )

      assert image_parts(adapted) == []
      assert all_text(adapted) =~ "no vision fallback succeeded"
    end
  end

  test "only rewrites image parts inside the Responses input contract" do
    metadata_image = %{"type" => "image", "url" => "https://example.test/metadata.png"}

    request =
      request_with_images(["text"], nil)
      |> Map.put("metadata", %{"opaque" => metadata_image})

    assert {:ok, adapted} = CodexVision.adapt("agent-1", request)

    assert adapted["metadata"]["opaque"] == metadata_image
    assert image_parts(adapted["input"]) == []
  end

  test "logs unexpected fallback crashes before safely removing images" do
    log =
      capture_log([level: :error, metadata: [:event, :model_selector, :reason]], fn ->
        assert {:ok, adapted} =
                 CodexVision.adapt(
                   "agent-1",
                   request_with_images(["text"], fallback_binding()),
                   request_fallback: fn _subject_uid, _request ->
                     raise "vision adapter exploded"
                   end
                 )

        assert image_parts(adapted["input"]) == []
      end)

    assert log =~ "Codex vision fallback crashed"
    assert log =~ "vision adapter exploded"
  end

  defp request_with_images(input_modalities, fallback) do
    %{
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{"type" => "input_text", "text" => "What is shown?"},
            %{"type" => "input_image", "image_url" => "data:image/png;base64,AA=="},
            %{"type" => "image_url", "image_url" => %{"url" => "https://example.test/b.png"}}
          ]
        }
      ],
      "__ankole_codex_vision" => %{
        "input_modalities" => input_modalities,
        "vision_fallback" => fallback
      }
    }
  end

  defp fallback_binding do
    %{
      "selector" => "openrouter-vision/google/gemini-3-flash-preview",
      "provider_options" => %{},
      "input_modalities" => ["text", "image"]
    }
  end

  defp image_parts(value), do: collect(value, &(&1["type"] in ~w(input_image image_url image)))

  defp all_text(value) do
    value
    |> collect(&(&1["type"] in ~w(input_text output_text text)))
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

  defp collect(%{} = value, predicate) do
    own = if predicate.(value), do: [value], else: []
    own ++ Enum.flat_map(Map.values(value), &collect(&1, predicate))
  end

  defp collect(value, predicate) when is_list(value),
    do: Enum.flat_map(value, &collect(&1, predicate))

  defp collect(_value, _predicate), do: []
end
