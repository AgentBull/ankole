defmodule FakeFeishu.Gateway do
  @moduledoc """
  Front plug of the standalone server: `/sim/*` goes to the admin API, every
  other path goes to the fake Feishu platform surface.
  """

  @behaviour Plug

  alias FakeFeishu.AdminRouter
  alias FakeFeishu.Router

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["sim" | _rest]} = conn, opts) do
    AdminRouter.call(conn, AdminRouter.init(opts))
  end

  def call(conn, opts) do
    Router.call(conn, Router.init(opts))
  end
end
