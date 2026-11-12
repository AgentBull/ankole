defmodule AnkoleWeb.JSONAPI.PodRealtime do
  @moduledoc "A short-lived socket credential for the selected Pod authentication."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: AnkoleWeb.MemberAPI,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:pod)
    allow(:token, check: :guardrail)
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("pod_realtime")
  end

  actions do
    action :token, :map do
      constraints(
        fields: [
          token: [type: :string, allow_nil?: false],
          principal: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields: [
                uid: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
                name: [type: :string, allow_nil?: false]
              ]
            ]
          ]
        ]
      )

      run(fn input, context ->
        credential =
          case input.context[:oidc_session] do
            %Ankole.OIDC.Session{} = session ->
              %{
                oidc_session_id: session.id,
                client_id: session.client_id,
                scope: get_in(input.context, [:oidc_claims, "scope"]) || "openid pod"
              }

            _ ->
              input.context.authentication_ref
          end

        Ankole.Pod.Access.principal(context.actor)
        |> Ankole.Pod.APIError.result(fn principal ->
          %{
            token: AnkoleWeb.PodSocket.token(principal.uid, credential),
            principal: %{uid: principal.uid, name: principal.display_name}
          }
        end)
      end)
    end
  end
end
