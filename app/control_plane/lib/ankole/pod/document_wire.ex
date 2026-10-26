defmodule Ankole.Pod.DocumentWire do
  @moduledoc "Limits for Pod document channel messages and retained change batches."

  def max_bytes, do: 32 * 1024 * 1024
end
