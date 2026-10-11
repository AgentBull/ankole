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
      import Phoenix.ChannelTest, except: [connect: 2, connect: 3]
      import AnkoleWeb.ChannelCase

      alias Ankole.Repo

      @endpoint AnkoleWeb.Endpoint
    end
  end

  defmacro connect(handler, params, options \\ []) do
    endpoint = Module.get_attribute(__CALLER__.module, :endpoint)

    quote do
      Ankole.Repo.without_tenant(fn ->
        Phoenix.ChannelTest.__connect__(
          unquote(endpoint),
          unquote(handler),
          unquote(params),
          unquote(options)
        )
      end)
    end
  end

  setup tags do
    Ankole.DataCase.setup_sandbox(tags)
    tenant = Ankole.DataCase.create_tenant()
    Ankole.Repo.put_tenant_id(tenant.id)
    {:ok, tenant: tenant}
  end
end
