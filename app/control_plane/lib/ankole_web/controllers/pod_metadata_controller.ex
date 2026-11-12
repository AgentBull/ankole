defmodule AnkoleWeb.PodMetadataController do
  @moduledoc "Tenant-wide Pod metadata files, such as the shared custom-emoji library."
  use AnkoleWeb, :controller
  import AnkoleWeb.PodResponse, only: [respond: 2, error: 2, send_sandboxed_object: 5]

  alias Ankole.Pod.Metadata

  def bootstrap(conn, _params) do
    tenant = conn.assigns.current_tenant
    principal = conn.assigns.current_principal

    authentication_ref =
      case conn.assigns[:oidc_session] do
        %Ankole.OIDC.Session{} ->
          "oauth"

        _ ->
          case AnkoleWeb.Session.authentication_reference(conn) do
            %{} = ref -> Ankole.BrowserSessions.encode_reference(ref)
            _ -> "current"
          end
      end

    locale =
      case Ankole.I18n.configured_default_locale() do
        {:ok, configured} when is_binary(configured) -> configured
        _ -> "en-US"
      end

    json(conn, %{
      version: Ankole.Version.current(),
      podOrigin: AnkoleWeb.PodURL.origin(conn, tenant),
      siteOrigin: AnkoleWeb.PodURL.site_origin(conn),
      tenantId: tenant.id,
      tenantSlug: tenant.slug,
      tenantDisplayName: tenant.display_name || tenant.slug,
      tenantAvatarUrl: tenant.avatar_url,
      principalUid: principal.uid,
      principalDisplayName: principal.display_name || principal.uid,
      principalAvatarUrl: principal.avatar_url,
      authenticationRef: authentication_ref,
      activePlugins: Ankole.Plugins.list_active() |> Enum.map(& &1.id),
      features: Ankole.Features.client_snapshot(),
      locale: locale
    })
  end

  def custom_emojis(conn, _params) do
    respond(conn, Metadata.custom_emojis(conn.assigns.authz_actor))
  end

  def upload_custom_emoji(conn, _params) do
    body = conn.body_params

    case Ankole.Attrs.get(body, :file) do
      %Plug.Upload{} = file ->
        name = Ankole.Attrs.get(body, :name)

        respond(
          conn,
          Metadata.upload_custom_emoji(
            conn.assigns.authz_actor,
            name,
            {:file, file.path},
            file.content_type
          )
        )

      _ ->
        error(conn, :missing_file)
    end
  end

  def download(conn, %{"path" => path} = params) do
    with {:ok, file} <- Metadata.resolve(conn.assigns.authz_actor, path),
         {:ok, object} <- Ankole.Files.fetch_object(file.object_id) do
      send_sandboxed_object(
        conn,
        object,
        Path.basename(file.path),
        file.content_type,
        params["download"] == "true"
      )
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def download(conn, _params), do: error(conn, :invalid_path)
end
