defmodule AnkoleWeb.SpaController do
  @moduledoc """
  Serves the Phoenix-owned HTML shell for each client-side application.

  Phoenix keeps routing, CSRF, session checks, and static asset lookup here. The
  React applications own the page content after the shell has loaded.
  """

  use AnkoleWeb, :controller

  alias Ankole.AdminAuth
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession
  alias AnkoleWeb.Assets

  @spas %{
    auth: %{entry: "auth", title: "Ankole Sign In"},
    console: %{entry: "console", title: "Ankole Console"},
    setup: %{entry: "setup", title: "Ankole Setup"}
  }

  @doc """
  Sends the operator to the only valid first screen for the installation state.
  """
  def home(conn, _params) do
    case setup_completed?() do
      true -> redirect(conn, to: ~p"/auth")
      false -> redirect(conn, to: ~p"/setup")
    end
  end

  @doc """
  Serves the sign-in SPA only after setup is complete and no admin is signed in.
  """
  def auth(conn, _params) do
    cond do
      not setup_completed?() ->
        redirect(conn, to: ~p"/setup")

      active_admin_session?(conn) ->
        redirect(conn, to: ~p"/console")

      true ->
        render_spa(conn, :auth)
    end
  end

  @doc """
  Serves the console SPA only for active human admins.
  """
  def console(conn, _params) do
    cond do
      not setup_completed?() ->
        redirect(conn, to: ~p"/setup")

      not active_admin_session?(conn) ->
        redirect(conn, to: ~p"/auth")

      true ->
        render_spa(conn, :console)
    end
  end

  @doc """
  Serves the setup SPA while the installation is still uninitialized.
  """
  def setup(conn, _params) do
    case setup_completed?() do
      true ->
        conn
        |> WebSession.clear_setup_session()
        |> redirect(to: ~p"/")

      false ->
        render_spa(conn, :setup)
    end
  end

  defp render_spa(conn, spa) do
    html(conn, spa_document(conn, Map.fetch!(@spas, spa)))
  end

  defp spa_document(conn, %{entry: entry, title: title}) do
    locale = app_locale()

    # The shell is built as iodata so Phoenix can send it without a separate
    # template layer. That keeps Phoenix as a thin HTML boundary while Vite
    # still owns the SPA assets.
    [
      "<!DOCTYPE html>\n",
      "<html lang=\"",
      Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(locale)),
      "\">\n",
      "  <head>\n",
      "    <meta charset=\"utf-8\">\n",
      "    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
      "    <meta name=\"csrf-token\" content=\"",
      get_csrf_token(),
      "\">\n",
      "    <title>",
      title,
      "</title>\n",
      Assets.entry_tags(conn, entry),
      "  </head>\n",
      "  <body>\n",
      "    <div id=\"ankole-app\"></div>\n",
      "  </body>\n",
      "</html>\n"
    ]
  end

  defp setup_completed? do
    case SetupConfig.completed?() do
      # Failing closed to setup is intentional: a broken setup marker should not
      # expose auth or console routes as if the installation were ready.
      {:ok, completed?} -> completed?
      {:error, _reason} -> false
    end
  end

  defp active_admin_session?(conn) do
    case WebSession.admin_session(conn) do
      %{"principal_uid" => principal_uid} -> AdminAuth.active_human_admin?(principal_uid)
      _session -> false
    end
  end

  defp app_locale do
    case Ankole.I18n.Config.default_locale() do
      {:ok, locale} -> locale
      {:error, _reason} -> "en-US"
    end
  end
end
