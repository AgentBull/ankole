defmodule BullXWeb.PageController do
  @moduledoc """
  Root redirect controller for the web shell.

  The first page routes users to console, setup, or login based on Principal
  session state and whether root initialization is still required.
  """

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
