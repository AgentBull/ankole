defmodule MicrosoftOpenAPI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [MicrosoftOpenAPI.Cache],
      strategy: :one_for_one,
      name: MicrosoftOpenAPI.Supervisor
    )
  end
end
