defmodule BullXWeb.SessionControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullX.Gateway.SourceConfig
  alias BullX.Plugins.{Extension, Registry, Spec}
  alias BullX.Principals
  alias BullX.Principals.ExternalIdentity

  @state_salt "principal-login-provider-state"

  defmodule FakeGatewayAdapter do
    @behaviour BullX.Gateway.Adapter

    @impl true
    def config_schema, do: %{}

    @impl true
    def normalize_config(config), do: {:ok, config}

    @impl true
    def public_config(config), do: config

    @impl true
    def capabilities, do: %{inbound_modes: [], outbound_ops: [], content_kinds: []}

    @impl true
    def connectivity_check(_source), do: {:ok, %{}}

    @impl true
    def source_child_spec(_source), do: :ignore

    @impl true
    def normalize_inbound(_payload, _source, _metadata), do: {:error, :unsupported}

    @impl true
    def deliver(_delivery, _source), do: {:error, %{"kind" => "unsupported"}}

    @impl true
    def stream(_delivery, _enumerable, _source), do: {:error, %{"kind" => "unsupported"}}
  end

  defmodule FakeLoginProvider do
    @behaviour BullX.Principals.LoginProvider

    @impl true
    def authorization_url(%SourceConfig{} = source, request) do
      query =
        URI.encode_query(%{
          "redirect_uri" => request["redirect_uri"],
          "state" => "provider-state"
        })

      {:ok,
       %{
         url: "https://auth.example.test/oauth?" <> query,
         state: %{
           "provider" => source.channel_id,
           "adapter" => source.adapter,
           "channel_id" => source.channel_id,
           "return_to" => request["return_to"],
           "issued_at" => System.system_time(:second),
           "nonce" => "nonce"
         }
       }}
    end

    @impl true
    def callback(%SourceConfig{} = source, %{"code" => "ok"}, state) do
      {:ok,
       %{
         "provider" => state["provider"],
         "external_id" => "fake:#{source.channel_id}:user",
         "profile" => %{"display_name" => "Fake User", "email" => "fake@example.com"},
         "metadata" => %{"adapter" => source.adapter, "channel_id" => source.channel_id}
       }}
    end

    def callback(_source, _params, _state), do: {:error, %{"message" => "fake callback failed"}}
  end

  setup do
    previous_registry = :sys.get_state(Registry)
    previous_gateway = Application.get_env(:bullx, :gateway)
    previous_principals = Application.get_env(:bullx, :principals)

    configure_registry!()
    configure_gateway_sources!(previous_gateway)
    configure_principals!()

    on_exit(fn ->
      :sys.replace_state(Registry, fn _state -> previous_registry end)
      restore_gateway(previous_gateway)
      restore_principals(previous_principals)
    end)

    :ok
  end

  test "OIDC start dispatches a source-slug provider to its login implementation", %{conn: conn} do
    conn = get(conn, ~p"/sessions/oidc/main?return_to=/work")

    location = redirected_to(conn, 302)
    uri = URI.parse(location)
    query = URI.decode_query(uri.query)

    assert uri.host == "auth.example.test"
    assert {:ok, state} = Phoenix.Token.verify(BullXWeb.Endpoint, @state_salt, query["state"])
    assert state["provider"] == "main"
    assert state["adapter"] == "fake_oidc"
    assert state["return_to"] == "/work"
  end

  test "OIDC callback creates a Human Principal from login subject input", %{conn: conn} do
    signed_state =
      Phoenix.Token.sign(BullXWeb.Endpoint, @state_salt, %{
        "provider" => "main",
        "adapter" => "fake_oidc",
        "channel_id" => "main",
        "return_to" => "/after",
        "issued_at" => System.system_time(:second),
        "nonce" => "nonce"
      })

    conn = get(conn, ~p"/sessions/oidc/main/callback?#{[code: "ok", state: signed_state]}")

    assert conn.status == 302, response(conn, conn.status)
    assert redirected_to(conn, 302) == "/after"
    assert principal_id = get_session(conn, :principal_id)
    assert {:ok, principal} = Principals.get_principal(principal_id)
    assert principal.type == :human

    assert %ExternalIdentity{kind: :login_subject, provider: "main"} =
             Repo.get_by(ExternalIdentity, external_id: "fake:main:user")
  end

  defp configure_registry! do
    extensions = [
      %Extension{
        plugin_id: "fake_oidc",
        point: :"bullx.gateway.adapter",
        id: "fake_oidc",
        module: FakeGatewayAdapter
      },
      %Extension{
        plugin_id: "fake_oidc",
        point: :"bullx.principals.login_provider",
        id: "fake_oidc",
        module: FakeLoginProvider,
        opts: %{kind: :oidc}
      }
    ]

    spec = %Spec{
      app: :fake_oidc,
      id: "fake_oidc",
      module: __MODULE__,
      api_version: 1,
      extensions: extensions,
      config_modules: []
    }

    {:ok, state} = Registry.build([spec], ["fake_oidc"])
    :sys.replace_state(Registry, fn _state -> state end)
  end

  defp configure_gateway_sources!(previous_gateway) do
    gateway = previous_gateway || []
    Application.put_env(:bullx, :gateway, Keyword.put(gateway, :sources, [source_config()]))
  end

  defp configure_principals! do
    Application.put_env(:bullx, :principals,
      authn_auto_create_humans: true,
      authn_match_rules: [
        %{
          "result" => "allow_create_human",
          "op" => "email_domain_in",
          "source_path" => "profile.email",
          "domains" => ["example.com"]
        }
      ]
    )
  end

  defp source_config do
    source = %{
      "adapter" => "fake_oidc",
      "channel_id" => "main",
      "enabled" => true,
      "config" => %{"oidc" => %{"enabled" => true}},
      "outbound_retry" => %{}
    }

    {:ok, normalized} = SourceConfig.normalize(source)

    Map.put(source, "connectivity", %{
      "status" => "ok",
      "fingerprint" => SourceConfig.fingerprint(normalized),
      "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp restore_gateway(nil), do: Application.delete_env(:bullx, :gateway)
  defp restore_gateway(value), do: Application.put_env(:bullx, :gateway, value)
  defp restore_principals(nil), do: Application.delete_env(:bullx, :principals)
  defp restore_principals(value), do: Application.put_env(:bullx, :principals, value)
end
