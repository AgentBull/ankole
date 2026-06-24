defmodule Ankole.ActorRuntime.WorkerRegistry do
  @moduledoc """
  Durable worker projection API.
  """

  alias Ankole.ActorRuntime.WorkerAdmission

  defdelegate record_worker_ready(attrs, route \\ nil), to: WorkerAdmission
end
