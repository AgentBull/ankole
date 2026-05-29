defmodule BullX.MailBox.Config do
  @moduledoc false

  @mail_box_key :mail_box

  @spec stream_retention_seconds() :: pos_integer()
  def stream_retention_seconds do
    get_positive_integer(:stream_retention_seconds, 900)
  end

  @spec max_stream_chunk_bytes() :: pos_integer()
  def max_stream_chunk_bytes do
    get_positive_integer(:max_stream_chunk_bytes, 65_536)
  end

  defp get_positive_integer(key, default) do
    config = Application.get_env(:bullx, @mail_box_key, [])

    case Keyword.fetch(config, key) do
      {:ok, value} when is_integer(value) and value > 0 -> value
      {:ok, value} -> raise_invalid_config!(key, value, "must be a positive integer")
      :error -> default
    end
  end

  defp raise_invalid_config!(key, value, message) do
    raise ArgumentError,
          "invalid :bullx, :mail_box #{inspect(key)} config: #{message}, got: #{inspect(value)}"
  end
end
