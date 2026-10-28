defmodule AnkoleWeb.MeOperations do
  @moduledoc "The selected member's login credentials and voluntary Pod exit."
  use Ankole.Ash.OperationResource,
    extensions: [Ankole.AuthZ.Extension],
    domain: AnkoleWeb.MemberAPI,
    authorizers: [Ankole.AuthZ.Authorizer]

  alias Ankole.AuthZ.Actor
  alias Ankole.Authn.AddOns.SiteCredentialBinding, as: CredentialBinding
  alias Ankole.Ash.Types.UUIDv7

  authz do
    scope(:self)
    allow(:show, check: :guardrail)
    allow(:update_profile, check: :guardrail)
    allow(:begin_reauthentication, check: :guardrail)
    allow(:request_email, check: :guardrail)
    allow(:verify_email, check: :guardrail)
    allow(:unbind, check: :guardrail)
    allow(:exit, check: :guardrail)
  end

  json_api do
    type("pod_member_account")
  end

  actions do
    action :begin_reauthentication, :map do
      constraints(fields: [loginURL: [type: :string, allow_nil?: false]])
      transaction?(false)

      run(fn input, context ->
        tenant_id = Actor.tenant_id(context.actor)

        with {:ok, ticket} <-
               AnkoleWeb.Session.seal_reauthentication(
                 input.context.conn,
                 Actor.uid(context.actor),
                 input.context.authentication_ref,
                 tenant_id
               ) do
          {:ok, tenant} = Ankole.Tenants.get(tenant_id)

          login_url =
            AnkoleWeb.PodURL.login_url(input.context.conn, tenant, %{
              "reauth" => ticket,
              "return_to" => "/me"
            })

          {:ok, %{loginURL: login_url}}
        else
          error -> result(error)
        end
      end)
    end

    action :show, :map do
      constraints(
        fields: [
          displayName: [type: :string, allow_nil?: false],
          credentialChangeAllowed: [type: :boolean, allow_nil?: false],
          managed: [type: :boolean, allow_nil?: false],
          credentials: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  id: [type: UUIDv7, allow_nil?: false],
                  provider: [type: :string, allow_nil?: false],
                  identifier: [type: :string, allow_nil?: false],
                  kind: [type: :string, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      )

      run(fn _, context ->
        {:ok,
         %{
           displayName: Actor.principal(context.actor).display_name,
           credentialChangeAllowed: CredentialBinding.permitted(context.actor) == :ok,
           managed: Ankole.IdentityProviders.directory_managed_member?(Actor.uid(context.actor)),
           credentials:
             Ankole.Principals.PodAdministration.credential_views(Actor.uid(context.actor))
         }}
      end)
    end

    action :update_profile, :map do
      constraints(fields: [displayName: [type: :string, allow_nil?: false]])

      argument(:displayName, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 160]
      )

      transaction?(false)

      run(fn input, context ->
        with {:ok, principal} <-
               Ankole.Principals.update_human(Actor.uid(context.actor), %{
                 display_name: input.arguments.displayName
               }),
             do: {:ok, %{displayName: principal.display_name}},
             else: (error -> result(error))
      end)
    end

    action :request_email, :map do
      constraints(fields: [challengeID: [type: UUIDv7, allow_nil?: false]])
      argument(:email, :string, allow_nil?: false)
      transaction?(false)

      run(fn input, context ->
        with {:ok, challenge} <-
               binding(:request, %{
                 actor: context.actor,
                 browser: input.context.browser_reference,
                 email: input.arguments.email,
                 ip: input.context.client_ip,
                 locale:
                   Ankole.I18n.negotiate_locale(
                     Plug.Conn.get_req_header(input.context.conn, "accept-language")
                   )
               }),
             do: {:ok, %{challengeID: challenge.challenge_id}},
             else: (error -> result(error))
      end)
    end

    action :verify_email, :map do
      constraints(
        fields: [
          ok: [type: :boolean, allow_nil?: false],
          authenticationRef: [type: :string, allow_nil?: false],
          csrfToken: [type: :string, allow_nil?: false]
        ]
      )

      argument(:challengeID, UUIDv7, allow_nil?: false)
      argument(:code, :string, allow_nil?: false, sensitive?: true, constraints: [trim?: false])
      transaction?(false)

      run(fn input, context ->
        with {:ok, completed} <-
               binding(:verify, %{
                 actor: context.actor,
                 browser: input.context.browser_reference,
                 id: input.arguments.challengeID,
                 code: input.arguments.code,
                 ip: input.context.client_ip
               }) do
          Plug.CSRFProtection.delete_csrf_token()

          :ok =
            Plug.CSRFProtection.load_state(
              input.context.conn.secret_key_base,
              completed.authentication.csrf_token
            )

          input.context.conn
          |> AnkoleWeb.Session.put_authentication(completed.browser, completed.authentication)
          |> AnkoleWeb.BrowserAPI.ok(%{
            ok: true,
            authenticationRef:
              completed.authentication
              |> Ankole.BrowserSessions.reference()
              |> Ankole.BrowserSessions.encode_reference(),
            csrfToken: Plug.CSRFProtection.get_csrf_token()
          })
        else
          error -> result(error)
        end
      end)
    end

    action :unbind, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])
      argument(:id, UUIDv7, allow_nil?: false)
      transaction?(false)

      run(fn input, context ->
        result(binding(:unbind, %{actor: context.actor, id: input.arguments.id}))
      end)
    end

    action :exit, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])
      transaction?(false)

      run(fn _, context ->
        with :ok <- CredentialBinding.recent(context.actor),
             {:ok, _} <- Ankole.Principals.HumanAccess.exit(context.actor),
             do: {:ok, %{ok: true}},
             else: (error -> result(error))
      end)
    end
  end

  defp binding(phase, params),
    do:
      Ankole.Authn.Info.run_add_on(
        Ankole.Principals.Principal,
        :site_credential_binding,
        phase,
        params
      )

  defp result({:error, reason}), do: Ankole.Authn.Error.login(reason)
  defp result(result), do: result
end
