defmodule BullXWeb.PageController do
  use BullXWeb, :controller

  def home(conn, _params) do
    cond do
      get_session(conn, :principal_uid) ->
        redirect(conn, to: ~p"/console")

      BullX.Principals.setup_required?() ->
        redirect(conn, to: ~p"/setup")

      true ->
        redirect(conn, to: ~p"/sessions/new")
    end
  end
end
