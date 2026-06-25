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

  # Maps each logical screen to its Vite entry bundle and document <title>. Note
  # the `:sessions` screen mounts the `auth` bundle — the route name and the
  # frontend entry name differ.
  @spas %{
    console: %{entry: "console", title: "Ankole Console"},
    sessions: %{entry: "auth", title: "Ankole Sign In"},
    setup: %{entry: "setup", title: "Ankole Setup"}
  }

  @doc """
  Sends the operator to the only valid first screen for the installation state.

  Before setup completes the only legitimate destination is `/setup`; afterwards
  it is the sign-in screen. `/` itself never renders a shell — it only redirects.
  """
  def home(conn, _params) do
    case setup_completed?() do
      true -> redirect(conn, to: ~p"/sessions/new")
      false -> redirect(conn, to: ~p"/setup")
    end
  end

  @doc """
  Serves the sign-in SPA only after setup is complete and no admin is signed in.

  The `cond` clauses are an ordered server-side gate: un-setup installs go to
  setup, already-signed-in admins skip straight to the console, and only the
  remaining case (setup done, not signed in) actually renders the sign-in shell.
  """
  def sessions_new(conn, _params) do
    cond do
      not setup_completed?() ->
        redirect(conn, to: ~p"/setup")

      active_admin_session?(conn) ->
        redirect(conn, to: ~p"/console")

      true ->
        render_spa(conn, :sessions)
    end
  end

  @doc """
  Keeps the older `/auth` URL as a browser redirect to the sessions SPA.
  """
  def auth_redirect(conn, params) do
    case setup_completed?() do
      true -> redirect(conn, to: sessions_new_path(params))
      false -> redirect(conn, to: ~p"/setup")
    end
  end

  @doc """
  Serves the console SPA only for active human admins.

  This is the server-side authentication gate for the console — it is enforced
  on the shell request itself, so the React app is never even delivered to an
  unauthenticated visitor. When not signed in, redirect to sign-in carrying a
  `return_to` so the operator lands back on the page they wanted post-login.
  """
  def console(conn, _params) do
    cond do
      not setup_completed?() ->
        redirect(conn, to: ~p"/setup")

      not active_admin_session?(conn) ->
        redirect(conn, to: sessions_new_path(%{"return_to" => current_console_return_to(conn)}))

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
    # still owns the SPA assets. The `csrf-token` <meta> is how the SPA picks up
    # the token to send back to the session_api endpoints; `<div id="ankole-app">`
    # is the mount point every entry bundle expects.
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

  # A cookie session is necessary but not sufficient: the principal it names must
  # still be an active human admin right now. Re-checking against AdminAuth means
  # a revoked/disabled admin loses console access immediately, without waiting
  # for the session cookie to expire.
  defp active_admin_session?(conn) do
    case WebSession.admin_session(conn) do
      %{"principal_uid" => principal_uid} -> AdminAuth.active_human_admin?(principal_uid)
      _session -> false
    end
  end

  defp sessions_new_path(%{"return_to" => return_to}) do
    safe_return_to = WebSession.safe_return_to(return_to)
    ~p"/sessions/new?return_to=#{safe_return_to}"
  end

  defp sessions_new_path(_params), do: ~p"/sessions/new"

  defp current_console_return_to(%Plug.Conn{query_string: ""} = conn), do: conn.request_path

  defp current_console_return_to(%Plug.Conn{query_string: query_string} = conn),
    do: conn.request_path <> "?" <> query_string

  # Sets the shell's `<html lang>`. If the installation locale can't be read we
  # still must emit a valid document, so fall back to a sane default rather than
  # failing the whole shell render over a presentation attribute.
  defp app_locale do
    case Ankole.I18n.Config.default_locale() do
      {:ok, locale} -> locale
      {:error, _reason} -> "en-US"
    end
  end
end
