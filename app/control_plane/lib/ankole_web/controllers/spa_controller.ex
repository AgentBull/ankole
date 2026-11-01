defmodule AnkoleWeb.SpaController do
  @moduledoc """
  Serves the Phoenix-owned HTML shell for each client-side application.

  Phoenix keeps routing, CSRF, session checks, and static asset lookup here. The
  React applications own the page content after the shell has loaded.
  """

  use AnkoleWeb, :controller

  alias Ankole.I18n
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.Version
  alias AnkoleWeb.Session, as: WebSession
  alias AnkoleWeb.Assets
  alias AnkoleWeb.PodURL

  @dev_routes Application.compile_env(:ankole, :dev_routes, false)

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

  def join(conn, params) do
    conn =
      if is_nil(Ankole.Repo.tenant_id()) and is_binary(params["token"]) do
        case Ankole.Principals.locate_invitation(params["token"]) do
          {:ok, %{tenant_id: tenant_id}} ->
            :ok = Ankole.Repo.put_tenant_id(tenant_id)
            assign(conn, :login_tenant_id, tenant_id)

          _ ->
            conn
        end
      else
        conn
      end

    render_spa(conn, :sessions)
  end

  def logged_out(conn, _params), do: render_spa(conn, :sessions)
  def logout_error(conn, _params), do: render_spa(conn, :sessions)

  def sessions_new(conn, params) do
    cond do
      not setup_completed?() ->
        redirect(conn, to: ~p"/setup")

      is_binary(params["oauth_request"]) ->
        render_oauth_request(conn, params["oauth_request"])

      conn.assigns[:site_login_host] == true and
          not match?({:pod, _}, conn.assigns[:host_context]) ->
        site_login(conn, params)

      true ->
        pod_login(conn, params)
    end
  end

  defp site_login(conn, params) do
    case AnkoleWeb.BrowserAuth.Targets.resolve(conn, params) do
      {:ok, %{target_tenant: %Ankole.Tenants.Tenant{} = tenant} = target} ->
        active_pod_session =
          Ankole.Repo.with_tenant(tenant.id, fn -> WebSession.pod_session(conn) end)

        if reusable_target_session?(params, target) and is_map(active_pod_session) do
          destination =
            if is_binary(target.console_return_to),
              do: PodURL.site_origin(conn) <> target.console_return_to,
              else: PodURL.origin(conn, tenant) <> target.return_to

          redirect(conn, external: destination)
        else
          :ok = Ankole.Repo.put_tenant_id(tenant.id)
          render_tenant_login(conn, tenant.id)
        end

      {:ok, _target} ->
        render_spa(conn, :sessions)

      {:error, _} ->
        conn |> put_status(401) |> render_spa(:sessions)
    end
  end

  defp pod_login(conn, params) do
    with :ok <- put_pod_target(conn) do
      tenant_id = Ankole.Repo.tenant_id!()
      {:ok, tenant} = Ankole.Tenants.get(tenant_id)
      origin = PodURL.origin(conn, tenant)

      if request_origin(conn) != origin do
        query = params |> Map.delete("tenant_id") |> URI.encode_query()

        redirect(conn,
          external: origin <> "/sessions/new" <> if(query == "", do: "", else: "?" <> query)
        )
      else
        render_or_redirect_pod_login(conn, tenant_id, params)
      end
    else
      _ -> send_resp(conn, 404, "Pod not found")
    end
  end

  defp render_or_redirect_pod_login(conn, tenant_id, params) do
    case AnkoleWeb.BrowserAuth.Targets.resolve(conn, params) do
      {:ok, target} ->
        if reusable_target_session?(params, target) and is_map(WebSession.pod_session(conn)) do
          redirect_pod_target(conn, target)
        else
          render_tenant_login(conn, tenant_id)
        end

      {:error, _} ->
        conn |> put_status(401) |> render_spa(:sessions)
    end
  end

  defp redirect_pod_target(conn, %{console_return_to: console_return_to})
       when is_binary(console_return_to),
       do: redirect(conn, external: PodURL.site_origin(conn) <> console_return_to)

  defp redirect_pod_target(conn, target), do: redirect(conn, to: target.return_to)

  defp reusable_target_session?(params, target) do
    params["switch"] != "1" and params["prompt"] != "login" and
      is_nil(target.reauthentication_principal_uid) and is_nil(target.invitation_id)
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

  def console(conn, params) do
    :ok = WebSession.put_privileged_tenant()
    switch? = params["switch"] == "1"
    resolved = if switch?, do: :unauthenticated, else: WebSession.resolve_site_admin_session(conn)

    cond do
      not setup_completed?() ->
        redirect(conn, to: ~p"/setup")

      match?({:ok, %{}, _ref}, resolved) ->
        {:ok, %{"principal_uid" => uid}, ref} = resolved

        conn
        |> WebSession.pin_authentication(ref)
        |> assign(:current_principal_uid, uid)
        |> render_spa(:console)

      resolved == :forbidden ->
        send_resp(conn, 403, "Site administrator access required")

      true ->
        {:ok, privileged} = Ankole.Tenants.privileged()
        {:ok, ticket} = WebSession.seal_console_return(console_return_to(conn), privileged.id)

        login_params =
          if switch?,
            do: %{"console_return" => ticket, "switch" => "1"},
            else: %{"console_return" => ticket}

        redirect(conn, external: PodURL.login_url(conn, privileged, login_params))
    end
  end

  def pod(conn, _params) do
    with true <- setup_completed?(),
         {:ok, tenant_id} <- entry_tenant(conn),
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
    with {:ok, id} <- entry_tenant(conn),
         do: Ankole.Repo.put_tenant_id(id)
  end

  defp entry_tenant(conn) do
    with {:ok, explicit} <- explicit_entry_tenant(conn) do
      case {Ankole.Repo.tenant_id(), explicit} do
        {host, tenant} when is_binary(host) and is_binary(tenant) and host != tenant ->
          {:error, :tenant_mismatch}

        {host, _} when is_binary(host) ->
          resolve_active_tenant(host)

        {nil, tenant} when is_binary(tenant) ->
          resolve_active_tenant(tenant)

        {nil, nil} ->
          current_or_default_tenant(conn)
      end
    end
  end

  defp explicit_entry_tenant(conn) do
    case WebSession.param(conn, "tenant_id") do
      nil ->
        {:ok, nil}

      id ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> {:ok, uuid}
          _ -> {:error, :not_found}
        end
    end
  end

  defp current_or_default_tenant(conn) do
    ref = WebSession.browser_reference(conn)

    case Ankole.BrowserSessions.get(ref) do
      {:ok, %{active_tenant_id: id}} when is_binary(id) ->
        if Ankole.BrowserSessions.current_reference(ref),
          do: resolve_active_tenant(id),
          else: default_entry_tenant()

      _ ->
        default_entry_tenant()
    end
  end

  defp default_entry_tenant,
    do: with({:ok, tenant} <- Ankole.Tenants.privileged(), do: {:ok, tenant.id})

  defp resolve_active_tenant(id) do
    with {:ok, tenant} <- Ankole.Tenants.get(id),
         true <- Ankole.Tenants.accepting_work?(tenant),
         do: {:ok, tenant.id},
         else: (_ -> {:error, :not_found})
  end

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
    locale = app_locale(conn, entry)

    # The shell is built as iodata so Phoenix can send it without a separate
    # template layer. That keeps Phoenix as a thin HTML boundary while Vite
    # still owns the SPA assets. The `csrf-token` <meta> is how the SPA picks up
    # the token to send back to the session_api endpoints; `<div id="ankole-app">`
    # is the mount point every entry bundle expects.
    [
      "<!DOCTYPE html>\n",
      "<html lang=\"",
      html_escape(locale),
      "\" translate=\"no\" class=\"notranslate\">\n",
      "  <head>\n",
      "    <meta charset=\"utf-8\">\n",
      "    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
      "    <meta name=\"google\" content=\"notranslate\">\n",
      "    <meta name=\"csrf-token\" content=\"",
      get_csrf_token(),
      "\">\n",
      "    <meta name=\"ankole-version\" content=\"",
      Version.current() |> html_escape(),
      "\">\n",
      "    <meta name=\"ankole-response-status\" content=\"",
      to_string(conn.status || 200),
      "\">\n",
      "    <link rel=\"icon\" type=\"image/svg+xml\" href=\"",
      html_escape(~p"/images/logo.svg"),
      "\">\n",
      "    <link rel=\"icon\" href=\"",
      html_escape(~p"/favicon.ico"),
      "\" sizes=\"48x48\">\n",
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
      dev_mailbox_meta(),
      "<meta name=\"ankole-active-plugins\" content=\"",
      Ankole.Plugins.list_active() |> Enum.map(& &1.id) |> Ankole.JSON.encode!() |> html_escape(),
      "\">\n",
      "<meta name=\"ankole-features\" content=\"",
      Ankole.Features.client_snapshot() |> Ankole.JSON.encode!() |> html_escape(),
      "\">\n",
      Assets.entry_tags(conn, entry),
      Assets.locale_preload_tags(locale),
      "  </head>\n",
      "  <body translate=\"no\" class=\"notranslate\">\n",
      "    <div id=\"ankole-app\" translate=\"no\" class=\"notranslate\" data-immersive-translate-ignore=\"\"></div>\n",
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

  defp dev_mailbox_meta do
    if @dev_routes and Ankole.Authn.Mailer.local_mailbox?() do
      "    <meta name=\"ankole-dev-mailbox\" content=\"/dev/mailbox\">\n"
    else
      []
    end
  end

  defp setup_completed? do
    case SetupConfig.completed?() do
      # Failing closed to setup is intentional: a broken setup marker should not
      # expose auth or console routes as if the installation were ready.
      {:ok, completed?} -> completed?
      {:error, _reason} -> false
    end
  end

  defp console_return_to(%Plug.Conn{query_string: ""} = conn), do: conn.request_path

  defp console_return_to(%Plug.Conn{query_string: query_string} = conn) do
    query =
      query_string
      |> URI.decode_query()
      |> Map.delete("switch")
      |> URI.encode_query()

    if query == "", do: conn.request_path, else: conn.request_path <> "?" <> query
  end

  defp request_origin(conn),
    do: URI.to_string(%URI{scheme: to_string(conn.scheme), host: conn.host, port: conn.port})

  # Pod workspaces render in their bound Pod's locale; Setup and the site Console
  # bind and render in the privileged Pod's locale.
  defp app_locale(_conn, entry) when entry in ["pod", "saas-pod", "setup", "console"],
    do: pod_locale()

  defp app_locale(conn, "auth") do
    host_tenant =
      case conn.assigns[:host_context] do
        {:pod, tenant_id} -> tenant_id
        _ -> nil
      end

    case conn.assigns[:login_tenant_id] || host_tenant do
      tenant_id when is_binary(tenant_id) -> Ankole.Repo.with_tenant(tenant_id, &pod_locale/0)
      nil -> request_locale(conn)
    end
  end

  defp app_locale(conn, _entry), do: request_locale(conn)

  defp pod_locale do
    case I18n.configured_default_locale() do
      {:ok, locale} -> locale
      {:error, _reason} -> "en-US"
    end
  end

  defp request_locale(conn),
    do: I18n.negotiate_locale(get_req_header(conn, "accept-language")) || "en-US"

  defp html_escape(value),
    do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
