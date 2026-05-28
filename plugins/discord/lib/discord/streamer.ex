defmodule Discord.Streamer do
  @moduledoc false

  @spec consume(Discord.Source.t() | map(), map(), String.t(), keyword()) :: :ok | {:error, map()}
  def consume(source_config, reply_address, stream_id, opts \\ []) do
    with {:ok, source} <- Discord.Source.normalize(source_config),
         {:ok, resume} <- BullX.MailBox.StreamingOutput.resume_stream(stream_id, Keyword.get(opts, :after_offset)),
         text when is_binary(text) and text != "" <- chunks_text(resume.chunks),
         {:ok, _result} <-
           Discord.Outbound.deliver(
             source,
             reply_address,
             %{"op" => "send", "content" => [%{"kind" => "text", "body" => %{"text" => text}}]},
             opts
           ) do
      :ok
    else
      "" -> {:error, Discord.Error.payload("stream content is absent")}
      {:error, reason} when is_atom(reason) -> {:error, Discord.Error.map(%{"kind" => "provider_unavailable", "message" => Atom.to_string(reason)})}
      {:error, error} -> {:error, Discord.Error.map(error)}
    end
  end

  defp chunks_text(chunks) do
    chunks
    |> Enum.map(&Map.get(&1, :chunk))
    |> Enum.join("")
  end
end
