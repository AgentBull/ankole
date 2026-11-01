defmodule Ankole.Files.Jobs.DeleteObject do
  @moduledoc "Deletes an unreferenced immutable object after its metadata transaction commits."
  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 20

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"storage_key" => key}}), do: Ankole.ObjectStore.delete(key)
end
