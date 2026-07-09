defmodule Ankole.AIGateway.CompactionRenderTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.CompactionRender

  test "caps very large function call outputs" do
    rendered =
      CompactionRender.render_items([
        %{
          "type" => "function_call_output",
          "call_id" => "call_large",
          "output" => String.duplicate("x", 300_000)
        }
      ])

    assert rendered =~ "tokens elided"
    assert CompactionRender.approx_tokens(rendered) <= 2_100
  end

  test "global budget elides oldest eligible items while preserving users and latest items" do
    items =
      for index <- 1..20 do
        if index == 3 do
          %{"type" => "message", "role" => "user", "content" => "user item survives"}
        else
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => "assistant item #{index} " <> String.duplicate("wide ", 30)
          }
        end
      end

    rendered = CompactionRender.render_items(items, budget_tokens: 180)

    assert rendered =~ "older items elided"
    assert rendered =~ "user item survives"
    assert rendered =~ "assistant item 20"
    assert rendered =~ "assistant item 19"
  end

  test "non-text content parts are placeholders instead of raw payloads" do
    rendered =
      CompactionRender.render_items([
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_image",
              "image_url" => "data:image/png;base64,SECRET_DATA_URL"
            }
          ]
        },
        %{
          "provider_file_id" => "SECRET_FILE_ID"
        },
        %{
          "type" => "input_file",
          "file_data" => "SECRET_FILE_DATA"
        }
      ])

    assert rendered =~ "[input_image omitted]"
    assert rendered =~ "[item omitted]"
    assert rendered =~ "[input_file omitted]"
    refute rendered =~ "SECRET_DATA_URL"
    refute rendered =~ "SECRET_FILE_ID"
    refute rendered =~ "SECRET_FILE_DATA"
  end
end
