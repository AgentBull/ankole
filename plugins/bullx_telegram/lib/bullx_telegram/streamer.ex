defmodule BullxTelegram.Streamer do
  @moduledoc false

  @spec consume(BullxTelegram.Source.t() | map(), map(), String.t(), keyword()) :: :ok | {:error, map()}
  def consume(source_config, reply_channel, stream_id, opts \\ []) do
    with {:ok, source} <- BullxTelegram.Source.normalize(source_config),
         {:ok, resume} <- BullX.EventBus.StreamingOutput.resume_stream(stream_id, Keyword.get(opts, :after_offset)),
         text when is_binary(text) and text != "" <- chunks_text(resume.chunks),
         {:ok, _result} <-
           BullxTelegram.Outbound.deliver(
             source,
             reply_channel,
             %{"op" => "send", "content" => [%{"kind" => "text", "body" => %{"text" => text}}]},
             opts
           ) do
      :ok
    else
      "" -> {:error, BullxTelegram.Error.payload("stream content is absent")}
      {:error, reason} when is_atom(reason) -> {:error, BullxTelegram.Error.map(%{"kind" => "provider_unavailable", "message" => Atom.to_string(reason)})}
      {:error, error} -> {:error, BullxTelegram.Error.map(error)}
    end
  end

  defp chunks_text(chunks) do
    chunks
    |> Enum.map(&Map.get(&1, :chunk))
    |> Enum.join("")
  end
end
