defmodule AnkoleWeb.SpaController do
  @moduledoc """
  Serves the Phoenix-owned HTML shell for each client-side application.

  Phoenix keeps routing, CSRF, session checks, and static asset lookup here. The
  React applications own the page content after the shell has loaded.
  """

  use AnkoleWeb, :controller

  alias Ankole.AppConfigure
  alias Ankole.I18n.Config, as: I18nConfig
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.Version
  alias AnkoleWeb.Session, as: WebSession
  alias AnkoleWeb.Assets
  alias AnkoleWeb.PodURL

  # Maps each logical screen to its Vite entry bundle and document <title>. Note
  # the `:sessions` screen mounts the `auth` bundle — the route name and the
  # frontend entry name differ.
  @spas %{
    console: %{entry: "console", title: "Ankole Console"},
    sessions: %{entry: "auth", title: "Ankole Sign In"},
    setup: %{entry: "setup", title: "Ankole Setup"},
    pod: %{entry: "pod", title: "Ankole"}
  }

  def home(conn, _params) do
    if setup_completed?(), do: pod(conn, %{}), else: redirect(conn, to: ~p"/setup")
  end

  def logout_confirmation(conn, _params), do: render_spa(conn, :sessions)
  def join(conn, _params), do: render_spa(conn, :sessions)
  def logged_out(conn, _params), do: render_spa(conn, :sessions)
  def logout_error(conn, _params), do: render_spa(conn, :sessions)

  def sessions_new(conn, params) do
    cond do
      not setup_completed?() ->
        redirect(conn, to: ~p"/setup")

      is_binary(params["oauth_request"]) ->
        render_oauth_request(conn, params["oauth_request"])

      params["purpose"] == "console" ->
        console_login(conn, params)

      true ->
        pod_login(conn, params)
    end
  end

  defp console_login(conn, params) do
    :ok = WebSession.put_privileged_tenant()

    if params["switch"] != "1" and params["prompt"] != "login" and
         not is_nil(WebSession.site_admin_session(conn)) do
      redirect(conn, to: login_return_to(:console, params["return_to"]))
    else
      render_spa(conn, :sessions)
    end
  end

  defp pod_login(conn, params) do
    with :ok <- put_pod_target(conn) do
      tenant_id = Ankole.Repo.tenant_id!()
      {:ok, tenant} = Ankole.Tenants.get(tenant_id)
      origin = PodURL.origin(conn, tenant)

      cond do
        request_origin(conn) != origin ->
          query = params |> Map.delete("tenant_id") |> URI.encode_query()

          redirect(conn,
            external: origin <> "/sessions/new" <> if(query == "", do: "", else: "?" <> query)
          )

        is_binary(params["reauth"]) ->
          case WebSession.unseal_reauthentication(conn, params["reauth"], tenant_id) do
            {:ok, _} -> render_tenant_login(conn, tenant_id)
            {:error, _} -> conn |> put_status(401) |> render_spa(:sessions)
          end

        is_binary(params["invitation"]) ->
          case WebSession.unseal_membership_invitation(conn, params["invitation"], tenant_id) do
            {:ok, _} -> render_tenant_login(conn, tenant_id)
            {:error, _} -> conn |> put_status(401) |> render_spa(:sessions)
          end

        is_binary(params["invitation_token"]) ->
          case Ankole.Principals.locate_invitation(params["invitation_token"]) do
            {:ok, %{tenant_id: ^tenant_id}} -> render_tenant_login(conn, tenant_id)
            _ -> conn |> put_status(401) |> render_spa(:sessions)
          end

        params["switch"] != "1" and params["prompt"] != "login" and
            is_map(WebSession.pod_session(conn)) ->
          redirect(conn, to: login_return_to(:pod, params["return_to"]))

        true ->
          render_tenant_login(conn, tenant_id)
      end
    else
      _ -> send_resp(conn, 404, "Pod not found")
    end
  end

  defp render_oauth_request(conn, id) do
    case Ankole.OIDC.AuthorizationRequests.get(WebSession.browser_reference(conn), id) do
      {:ok, request} ->
        case conn.assigns[:host_context] do
          {:pod, tenant_id} when tenant_id != request.tenant_id ->
            conn |> put_status(401) |> render_spa(:sessions)

          _ ->
            :ok = Ankole.Repo.put_tenant_id(request.tenant_id)
            render_tenant_login(conn, request.tenant_id)
        end

      {:error, _} ->
        conn |> put_status(401) |> render_spa(:sessions)
    end
  end

  defp render_tenant_login(conn, tenant_id),
    do: conn |> assign(:login_tenant_id, tenant_id) |> render_spa(:sessions)

  def console(conn, _params) do
    :ok = WebSession.put_privileged_tenant()

    cond do
      not setup_completed?() ->
        redirect(conn, to: ~p"/setup")

      is_nil(WebSession.site_admin_session(conn)) ->
        return_to = current_return_to(conn)

        query =
          if return_to == AnkoleWeb.SiteAdminConsole.path(),
            do: %{"purpose" => "console"},
            else: %{"purpose" => "console", "return_to" => return_to}

        redirect(conn, to: "/sessions/new?" <> URI.encode_query(query))

      true ->
        render_spa(conn, :console)
    end
  end

  def pod(conn, _params) do
    with true <- setup_completed?(),
         {:ok, tenant_id} <- AnkoleWeb.Plugs.RequirePodSession.target_tenant(conn),
         :ok <- Ankole.Repo.put_tenant_id(tenant_id),
         {:ok, tenant} <- Ankole.Tenants.get(tenant_id),
         {:ok, path} <- PodURL.path(conn) do
      canonical = PodURL.origin(conn, tenant) <> path

      if Plug.Conn.request_url(conn) != canonical do
        redirect(conn, external: canonical)
      else
        case WebSession.pod_session(conn) do
          nil ->
            target =
              if path == "/",
                do: "/sessions/new",
                else: "/sessions/new?" <> URI.encode_query(%{"return_to" => path})

            redirect(conn, to: target)

          %{"principal_uid" => uid} ->
            conn |> assign(:current_principal_uid, uid) |> render_spa(:pod)
        end
      end
    else
      false -> redirect(conn, to: ~p"/setup")
      _ -> send_resp(conn, 404, "Pod not found")
    end
  end

  defp put_pod_target(conn) do
    with {:ok, id} <- AnkoleWeb.Plugs.RequirePodSession.target_tenant(conn),
         do: Ankole.Repo.put_tenant_id(id)
  end

  defp login_return_to(:console, nil), do: AnkoleWeb.SiteAdminConsole.path()

  defp login_return_to(:pod, nil), do: "/"

  defp login_return_to(_, return_to), do: WebSession.safe_return_to(return_to)

  @doc """
  Serves the setup SPA while the installation is still uninitialized.
  """
  def setup(conn, _params) do
    :ok = WebSession.put_privileged_tenant()

    case setup_completed?() do
      true ->
        conn
        |> WebSession.clear_setup_session()
        |> redirect(to: ~p"/")

      false ->
        render_spa(conn, :setup)
    end
  end

  def render_spa(conn, spa) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")
    descriptor = if is_atom(spa), do: Map.fetch!(@spas, spa), else: spa
    html(conn, spa_document(conn, descriptor))
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
      html_escape(locale),
      "\">\n",
      "  <head>\n",
      "    <meta charset=\"utf-8\">\n",
      "    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
      "    <meta name=\"csrf-token\" content=\"",
      get_csrf_token(),
      "\">\n",
      "    <meta name=\"ankole-version\" content=\"",
      Version.current() |> html_escape(),
      "\">\n",
      "    <meta name=\"ankole-response-status\" content=\"",
      to_string(conn.status || 200),
      "\">\n",
      "    <title>",
      html_escape(title),
      "</title>\n",
      # The theme class must be on <html> before the first paint. The React
      # ThemeProvider applies it only after the bundle loads, so without this
      # inline script every full page load flashes the light background at a
      # dark-mode operator. The storage key and attribute mirror the uikit
      # ThemeProvider configuration.
      "    <script>try{var t=localStorage.getItem(\"ankole-theme\");" <>
        "if(t===\"dark\"){var d=document.documentElement;" <>
        "d.dataset.theme=\"dark\";d.style.colorScheme=\"dark\"}}catch(e){}</script>\n",
      [
        "<meta name=\"ankole-site-origin\" content=\"",
        html_escape(PodURL.site_origin(conn)),
        "\">\n"
      ],
      login_tenant_meta(conn),
      authentication_meta(conn, entry),
      console_path_meta(entry),
      "<meta name=\"ankole-active-plugins\" content=\"",
      Ankole.Plugins.list_active() |> Enum.map(& &1.id) |> Ankole.JSON.encode!() |> html_escape(),
      "\">\n",
      "<meta name=\"ankole-features\" content=\"",
      Ankole.Features.client_snapshot() |> Ankole.JSON.encode!() |> html_escape(),
      "\">\n",
      Assets.entry_tags(conn, entry),
      Assets.locale_preload_tags(locale),
      "  </head>\n",
      "  <body>\n",
      "    <div id=\"ankole-app\"></div>\n",
      "  </body>\n",
      "</html>\n"
    ]
  end

  defp login_tenant_meta(%{assigns: %{login_tenant_id: tenant_id}})
       when is_binary(tenant_id) do
    {:ok, tenant} = Ankole.Tenants.get(tenant_id)

    [
      "<meta name=\"ankole-login-tenant-name\" content=\"",
      html_escape(tenant.display_name),
      "\">\n"
    ]
  end

  defp login_tenant_meta(_conn), do: []

  defp authentication_meta(_conn, entry) when entry in ["auth", "setup"], do: []

  defp authentication_meta(conn, _entry) do
    case WebSession.authentication_reference(conn) do
      nil ->
        []

      ref ->
        tenant = Ankole.Repo.tenant_id() || ""

        [
          "<meta name=\"ankole-authentication\" content=\"",
          Ankole.BrowserSessions.encode_reference(ref),
          "\"><meta name=\"ankole-pod\" content=\"",
          tenant,
          "\">\n",
          principal_meta(conn.assigns[:current_principal_uid])
        ]
    end
  end

  defp principal_meta(nil), do: []

  defp principal_meta(uid) do
    ["<meta name=\"ankole-principal\" content=\"", html_escape(uid), "\">\n"]
  end

  defp console_path_meta("console") do
    [
      "    <meta name=\"ankole-site-admin-console-path\" content=\"",
      html_escape(AnkoleWeb.SiteAdminConsole.path()),
      "\">\n"
    ]
  end

  defp console_path_meta(_entry), do: []

  defp setup_completed? do
    case SetupConfig.completed?() do
      # Failing closed to setup is intentional: a broken setup marker should not
      # expose auth or console routes as if the installation were ready.
      {:ok, completed?} -> completed?
      {:error, _reason} -> false
    end
  end

  defp current_return_to(%Plug.Conn{query_string: ""} = conn), do: conn.request_path

  defp current_return_to(%Plug.Conn{query_string: query_string} = conn),
    do: conn.request_path <> "?" <> query_string

  defp request_origin(conn),
    do: URI.to_string(%URI{scheme: to_string(conn.scheme), host: conn.host, port: conn.port})

  # The authentication and administration shells belong to the site, including
  # logout errors without a verified client or tenant. Read their locale explicitly
  # from the site configuration. If that locale can't be read we
  # still must emit a valid document, so fall back to a sane default rather than
  # failing the whole shell render over a presentation attribute.
  defp app_locale do
    case AppConfigure.get(I18nConfig.default_locale_definition(), scope: :global) do
      {:ok, locale} -> locale
      {:error, _reason} -> "en-US"
    end
  end

  defp html_escape(value),
    do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
