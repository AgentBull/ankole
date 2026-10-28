defmodule Ankole.EditionFixture.Router do
  use AnkoleWeb, :router

  pipeline :edition do
    plug :host_scope
    plug :add_authentications
    plug :fixture_challenge
  end

  pipeline :browser do
    plug :fetch_session
    plug :browser_csrf
    plug :put_secure_browser_headers
  end

  pipeline :pod_api do
    plug :require_pod_session
  end

  scope "/api/v2/saas-pod" do
    pipe_through [:edition, :browser, :pod_api]
    AnkoleWeb.runtime_forward("/", Ankole.SaaSWeb.PodJSONAPIRouter)
  end

  scope "/api/v2/saas" do
    pipe_through [:edition, :browser]
    AnkoleWeb.runtime_forward("/", Ankole.SaaSWeb.JSONAPIRouter)
  end

  scope "/fixture-browser" do
    pipe_through [:edition, :browser]
    get "/pod/:uid", Ankole.EditionFixture.Controller, :pod
  end

  scope "/" do
    pipe_through :edition
    get "/edition-fixture", Ankole.EditionFixture.Controller, :show
    AnkoleWeb.runtime_forward("/", AnkoleWeb.Router)
  end

  defp browser_csrf(conn, opts),
    do: AnkoleWeb.Plugs.BrowserCSRF.call(conn, AnkoleWeb.Plugs.BrowserCSRF.init(opts))

  defp require_pod_session(conn, opts),
    do: AnkoleWeb.Plugs.RequirePodSession.call(conn, AnkoleWeb.Plugs.RequirePodSession.init(opts))

  defp host_scope(conn, _) do
    case {conn.assigns[:host_context], conn.path_info} do
      {:site, ["api", "v2", "saas-pod" | _]} -> conn |> send_resp(404, "Not found") |> halt()
      {{:pod, _}, ["api", "v2", "saas" | _]} -> conn |> send_resp(404, "Not found") |> halt()
      _ -> conn
    end
  end

  defp fixture_challenge(
         %{method: "POST", request_path: "/api/v2/browser/sessions/email-otp/challenges"} = conn,
         _
       ) do
    params = if is_map(conn.body_params["data"]), do: conn.body_params["data"], else: %{}
    conn = conn |> fetch_session() |> AnkoleWeb.BrowserAuth.Targets.assign_context(params)

    if Ankole.Plugins.active?("fixture-challenge") and
         Ankole.Features.boolean_value("fixture.auth-challenge") and
         get_req_header(conn, "x-fixture-challenge") != ["passed"],
       do: conn |> send_resp(403, "Fixture challenge required") |> halt(),
       else: conn
  end

  defp fixture_challenge(conn, _), do: conn

  defp add_authentications(conn, _opts) do
    conn = Plug.Conn.assign(conn, :browser_login_mode, :add)

    if not match?({:pod, _}, conn.assigns[:host_context]),
      do: Plug.Conn.assign(conn, :default_login_purpose, :site),
      else: conn
  end
end

defmodule Ankole.EditionFixture.Controller do
  use AnkoleWeb, :controller
  def show(conn, _params), do: text(conn, "SaaS build fixture")

  def pod(conn, %{"uid" => uid}) do
    conn
    |> AnkoleWeb.Session.put_admin_session(%{
      principal_uid: uid,
      provider_id: "fixture",
      external_id: uid
    })
    |> redirect(to: "/settings")
  end
end

defmodule Ankole.EditionFixture.HostPolicy do
  @behaviour AnkoleWeb.Plugs.RequestHost
  def domain, do: "example.test"
  def pod_origin(%Ankole.Tenants.Tenant{}), do: "https://pod.example.test"
  def canonical_origin(:site), do: "https://site.example.test"

  def canonical_origin({:pod, "019a2b00-0000-7000-8000-000000000001"}),
    do: "https://pod.example.test"

  def login_url(_tenant, params),
    do: "https://site.example.test/sessions/new?" <> URI.encode_query(params)

  def membership_login_url(_conn, tenant, _reason, params),
    do: {:ok, login_url(tenant, params)}

  def classify(%URI{host: "site.example.test"}), do: {:ok, :site}

  def classify(%URI{host: "pod.example.test"}),
    do: {:ok, {:pod, "019a2b00-0000-7000-8000-000000000001"}}

  def classify(_), do: :error
end

defmodule Ankole.EditionFixture.Config do
  def runtime_config(_env), do: []

  def definitions do
    [
      Ankole.AppConfigure.define(
        key: "fixture.edition",
        scope: :global,
        encrypted: false,
        schema: Ankole.AppConfigure.Schema.non_empty_string(),
        default_value: "saas"
      )
    ]
  end

  def patterns, do: []
end

defmodule Ankole.EditionFixture.Source do
  @behaviour Ankole.IdentityProviders.SiteSources
  def authenticate(_), do: {:error, :invalid_authentication}
  def display_name, do: "Build fixture"
  def login_path, do: "/edition-fixture"
  def fresh_authentication?, do: false
end

defmodule Ankole.EditionFixture.PodSettingsPlugin do
  @behaviour Ankole.Plugins.Plugin
  @impl true
  def plugin_id, do: "fixture-pod-settings"
  @impl true
  def activation, do: :always
end

defmodule Ankole.EditionFixture.ChallengePlugin do
  @behaviour Ankole.Plugins.Plugin
  @impl true
  def plugin_id, do: "fixture-challenge"
  @impl true
  def activation, do: :always
end

defmodule Ankole.EditionFixture.QuotaPlugin do
  @behaviour Ankole.Plugins.Plugin
  @behaviour Ankole.Plugins.Hook
  @impl true
  def plugin_id, do: "fixture-quota"
  @impl true
  def activation, do: :always
  @impl true
  def hooks, do: [create_agent: __MODULE__]
  @impl true
  def before_commit_in_tx(:create_agent, _attrs) do
    limit = Application.get_env(:ankole, :fixture_agent_limits, %{})[Ankole.Repo.tenant_id()]

    if limit != nil and length(Ankole.Principals.list_agents()) >= limit,
      do: {:error, :fixture_quota_exceeded},
      else: :ok
  end
end
