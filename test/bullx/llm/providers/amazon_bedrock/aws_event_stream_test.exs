defmodule BullX.LLM.Providers.AmazonBedrock.AWSEventStreamTest do
  use ExUnit.Case, async: true

  alias BullX.LLM.Providers.AmazonBedrock.AWSEventStream

  test "create_stream parses a complete event from an empty buffer" do
    payload = %{"delta" => %{"text" => "hello"}}
    frame = event_stream_frame(payload, %{":event-type" => "contentBlockDelta"})

    send(self(), {make_ref(), {:data, frame}})
    send(self(), {make_ref(), :done})

    assert [%{"contentBlockDelta" => ^payload}] =
             AWSEventStream.create_stream(timeout: 10)
             |> Enum.to_list()
  end

  defp event_stream_frame(payload, headers) do
    headers = encode_headers(headers)
    body = Jason.encode!(payload)
    message_length = 12 + byte_size(headers) + byte_size(body) + 4
    prelude = <<message_length::big-32, byte_size(headers)::big-32>>
    prelude_crc = :erlang.crc32(prelude)

    message_without_crc = <<
      prelude::binary,
      prelude_crc::32,
      headers::binary,
      body::binary
    >>

    <<message_without_crc::binary, :erlang.crc32(message_without_crc)::32>>
  end

  defp encode_headers(headers) do
    headers
    |> Enum.map(fn {name, value} ->
      <<byte_size(name)::8, name::binary, 7::8, byte_size(value)::16-big, value::binary>>
    end)
    |> IO.iodata_to_binary()
  end
end
