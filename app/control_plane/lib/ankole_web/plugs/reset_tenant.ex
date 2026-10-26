defmodule AnkoleWeb.Plugs.ResetTenant do
  @moduledoc "Starts each HTTP request without a tenant inherited from an earlier request."
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Ankole.Repo.put_tenant_id(nil)
    conn
  end
end
