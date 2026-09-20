defmodule AnkoleWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix channels that need the database.

  The SQL sandbox runs in shared mode because the Worker Channel, the inbound
  dispatcher, and per-actor controllers touch the database from their own
  processes.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import AnkoleWeb.ChannelCase

      alias Ankole.Repo

      @endpoint AnkoleWeb.Endpoint
    end
  end

  setup tags do
    Ankole.DataCase.setup_sandbox(tags)
    :ok
  end
end
