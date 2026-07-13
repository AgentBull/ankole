defmodule GoogleOpenAPI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [GoogleOpenAPI.Cache],
      strategy: :one_for_one,
      name: GoogleOpenAPI.Supervisor
    )
  end
end
