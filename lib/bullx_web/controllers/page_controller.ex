defmodule BullXWeb.PageController do
  use BullXWeb, :controller

  def home(conn, _params) do
    cond do
      get_session(conn, :principal_id) ->
        redirect(conn, to: ~p"/console")

      BullX.Principals.setup_required?() and
          BullX.Principals.bootstrap_activation_code_pending?() ->
        redirect(conn, to: ~p"/setup")

      true ->
        redirect(conn, to: ~p"/sessions/new")
    end
  end
end
