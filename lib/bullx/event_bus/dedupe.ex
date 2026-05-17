defmodule BullX.EventBus.Dedupe do
  @moduledoc false

  @spec hash(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def hash(source, id) when is_binary(source) and is_binary(id) do
    source_size = source |> byte_size() |> Integer.to_string()
    id_size = id |> byte_size() |> Integer.to_string()

    case BullX.Ext.generic_hash(
           IO.iodata_to_binary(["cloudevents:", source_size, ":", source, ":", id_size, ":", id])
         ) do
      hash when is_binary(hash) -> {:ok, hash}
      {:error, reason} -> {:error, reason}
    end
  end
end
