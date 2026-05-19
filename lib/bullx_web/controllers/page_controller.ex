defmodule BullXWeb.PageController do
  use BullXWeb, :controller

  def home(conn, _params) do
    case BullX.Principals.setup_required?() and
           BullX.Principals.bootstrap_activation_code_pending?() do
      true -> redirect(conn, to: ~p"/setup")
      false -> redirect(conn, to: ~p"/sessions/new")
    end
  end
end
