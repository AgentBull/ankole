defmodule BullXWeb.PageController do
  use BullXWeb, :controller

  def home(conn, _params), do: redirect(conn, to: ~p"/setup")
end
