defmodule AnkoleWeb.BrowserInvitation do
  @moduledoc "Invitation preview and acceptance without a pre-existing Pod session."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: AnkoleWeb.BrowserAPI,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:public)
    allow(:preview, check: :public)
    allow(:begin_login, check: :public)
    allow(:accept, check: :public)
  end

  alias AnkoleWeb.{BrowserAPI, Session}
  alias Ankole.{BrowserSessions, Principals, Repo, Tenants}
  alias Ankole.Ash.Types.UUIDv7

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("browser_invitation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :preview, :map do
      constraints(
        fields: [
          tenantID: [type: UUIDv7, allow_nil?: false],
          displayName: [type: :string, allow_nil?: false],
          membership: [type: :atom, allow_nil?: false, constraints: [one_of: [:member, :guest]]],
          podURL: [type: :string, allow_nil?: false],
          emailOTPAvailable: [type: :boolean, allow_nil?: false],
          oidcProviders: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  providerID: [type: :string, allow_nil?: false],
                  displayName: [type: Ankole.Ash.Types.StringMap, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      )

      argument(:token, :string, allow_nil?: false, sensitive?: true)
      transaction?(false)
      run(fn input, _ -> preview(input.context.conn, input.arguments.token) end)
    end

    action :begin_login, :map do
      constraints(fields: [flow: [type: UUIDv7, allow_nil?: false]])
      argument(:token, :string, allow_nil?: false, sensitive?: true)
      transaction?(false)

      run(fn input, _ ->
        conn = input.context.conn

        with {:ok, invitation} <- Principals.locate_invitation(input.arguments.token) do
          Repo.with_tenant(invitation.tenant_id, fn ->
            with {:ok, conn, transaction} <-
                   Session.begin_login(conn, :pod, %{
                     "return_to" => "/",
                     "invitation_id" => invitation.id
                   }),
                 do: BrowserAPI.ok(conn, %{flow: transaction.id})
          end)
        else
          {:error, reason} -> BrowserAPI.error(410, reason)
        end
      end)
    end

    action :accept, :map do
      constraints(fields: [podURL: [type: :string, allow_nil?: false]])
      argument(:token, :string, allow_nil?: false, sensitive?: true)
      argument(:authenticationRef, :string, allow_nil?: false)
      transaction?(false)

      run(fn input, _ ->
        conn = input.context.conn

        with {:ok, invitation} <- Principals.locate_invitation(input.arguments.token),
             {:ok, reference} <-
               BrowserSessions.decode_reference(input.arguments.authenticationRef),
             true <- Session.authentication_proven?(conn, reference),
             {:ok, _} <-
               BrowserSessions.accept_invitation(reference, invitation.tenant_id, invitation.id),
             {:ok, tenant} <- Tenants.get(invitation.tenant_id) do
          BrowserAPI.ok(conn, %{podURL: AnkoleWeb.PodURL.origin(conn, tenant) <> "/"})
        else
          false -> BrowserAPI.error(401, :invalid_authentication)
          {:error, reason} -> AnkoleWeb.BrowserAPI.Error.login(reason)
        end
      end)
    end
  end

  defp preview(conn, token) do
    with {:ok, invitation} <- Principals.locate_invitation(token),
         {:ok, tenant} <- Tenants.get(invitation.tenant_id) do
      Repo.with_tenant(tenant.id, fn ->
        {:ok, policy} = Ankole.Principals.PodLoginPolicy.get()
        {:ok, providers} = Ankole.IdentityProviders.Login.list_login_providers()

        BrowserAPI.ok(conn, %{
          tenantID: tenant.id,
          displayName: tenant.display_name,
          membership: invitation.membership,
          podURL: AnkoleWeb.PodURL.origin(conn, tenant) <> "/",
          emailOTPAvailable:
            Ankole.Authn.Mailer.configured?() and policy["allow_email_otp"] and
              (invitation.membership == :guest or not policy["require_sso_for_members"]),
          oidcProviders:
            Enum.map(
              providers,
              &%{providerID: &1["provider_id"], displayName: &1["display_name"]}
            )
        })
      end)
    else
      {:error, reason} -> BrowserAPI.error(410, reason)
    end
  end
end
