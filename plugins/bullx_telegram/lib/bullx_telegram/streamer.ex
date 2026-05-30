defmodule BullxTelegram.Streamer do
  @moduledoc false

  @spec consume(BullxTelegram.Source.t() | map(), map(), String.t(), keyword()) ::
          :ok | {:error, map()}
  def consume(_source_config, _reply_address, _stream_id, _opts \\ []) do
    {:error,
     BullxTelegram.Error.payload(
       "Telegram streaming output is unsupported; final assistant output is delivered normally"
     )}
  end
end
