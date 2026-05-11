defmodule BullXGateway.DedupeKey do
  @moduledoc false

  @spec generate(String.t(), String.t()) :: String.t()
  def generate(source, external_id) when is_binary(source) and is_binary(external_id) do
    BullX.Ext.generic_hash("#{source}|#{external_id}")
  end
end
