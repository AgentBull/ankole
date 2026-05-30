defmodule BullX.LLM.Providers.Anthropic.ResponseTest do
  use ExUnit.Case, async: true

  alias BullX.LLM.Providers.Anthropic.Response

  test "stateful thinking blocks preserve text and signature across deltas" do
    state = Response.init_stream_state()

    {chunks, state} =
      Response.decode_stream_event(
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{
              "type" => "thinking",
              "thinking" => "alpha ",
              "signature" => "sig-start"
            }
          }
        },
        nil,
        state
      )

    assert [%ReqLLM.StreamChunk{type: :thinking, text: "alpha "}] = chunks

    {chunks, state} =
      Response.decode_stream_event(
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "beta"}
          }
        },
        nil,
        state
      )

    assert [%ReqLLM.StreamChunk{type: :thinking, text: "beta"}] = chunks

    {chunks, state} =
      Response.decode_stream_event(
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => " gamma"}
          }
        },
        nil,
        state
      )

    assert [%ReqLLM.StreamChunk{type: :thinking, text: " gamma"}] = chunks

    {chunks, state} =
      Response.decode_stream_event(
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "signature_delta", "signature" => "sig-final"}
          }
        },
        nil,
        state
      )

    assert [] = chunks

    {chunks, state} =
      Response.decode_stream_event(
        %{data: %{"type" => "content_block_stop", "index" => 0}},
        nil,
        state
      )

    assert [
             %ReqLLM.StreamChunk{
               type: :meta,
               metadata: %{reasoning_details: [reasoning_detail]}
             }
           ] = chunks

    assert reasoning_detail.text == "alpha beta gamma"
    assert reasoning_detail.signature == "sig-final"
    assert reasoning_detail.encrypted?
    assert reasoning_detail.provider == :anthropic

    assert {[], _state} = Response.flush_stream_state(nil, state)
  end
end
