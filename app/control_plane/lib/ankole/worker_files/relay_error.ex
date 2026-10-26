defmodule Ankole.WorkerFiles.RelayError do
  @moduledoc """
  Raised by a `Ankole.WorkerFiles.stream/3` body when the Worker or the
  relay fails after the stream has started.
  """

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}), do: "worker file relay failed: #{inspect(reason)}"
end
