defmodule BullXWeb.Plugs.FetchCurrentUser do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts), do: conn
end
