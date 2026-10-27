defmodule Ankole.Principals.PodAdminOperations do
  @moduledoc "Pod member, invitation, login policy, and enterprise provider operations."
  use Ankole.Ash.OperationResource,
    extensions: [Ankole.AuthZ.Extension],
    domain: Ankole.Principals,
    authorizers: [Ankole.AuthZ.Authorizer]

  alias Ankole.Principals.PodAdministration, as: Admin
  alias Ankole.Ash.Types.{UUIDv7, PrincipalKey, JSONMap}

  authz do
    scope(:tenant_console)
    resolve_param(:uid, :principal_key)
    resolve_param(:provider_id, :provider_id)
    allow(:settings, resource: "tenant_console:pod_settings", action: "read")
    allow(:update_settings, resource: "tenant_console:pod_settings", action: "update")
    allow(:members, resource: "tenant_console:principals", action: "read")
    allow(:create_member, resource: "tenant_console:principals", action: "update")
    allow(:change_membership, resource: "tenant_console:principal:{uid}", action: "update")
    allow(:set_admin, resource: "tenant_console:group:pod_admin", action: "update")
    allow(:disable_member, resource: "tenant_console:principal:{uid}", action: "update")
    allow(:access_review, resource: "tenant_console:principal:{uid}", action: "read")
    allow(:restore_member, resource: "tenant_console:principal:{uid}", action: "update")
    allow(:unbind_credential, resource: "tenant_console:principal:{uid}", action: "update")
    allow(:invitations, resource: "tenant_console:invitations", action: "read")
    allow(:create_invitation, resource: "tenant_console:invitations", action: "update")
    allow(:revoke_invitation, resource: "tenant_console:invitations", action: "update")
    allow(:providers, resource: "tenant_console:identity_providers", action: "read")

    allow(:save_provider,
      resource: "tenant_console:identity_provider:{provider_id}",
      action: "update"
    )

    allow(:create_provider,
      resource: "tenant_console:identity_provider:{provider_id}",
      action: "update"
    )

    allow(:sync_directory,
      resource: "tenant_console:identity_provider:{provider_id}",
      action: "sync"
    )
  end

  json_api do
    type("pod_admin_operation")
  end

  @policy [
    allow_email_otp: [type: :boolean, allow_nil?: false],
    allow_member_credential_change: [type: :boolean, allow_nil?: false],
    allowed_email_domains: [type: {:array, :string}, allow_nil?: false],
    require_sso_for_members: [type: :boolean, allow_nil?: false],
    allow_invite_links: [type: :boolean, allow_nil?: false]
  ]
  @settings [
    displayName: [type: :string, allow_nil?: false],
    allowExternalGuests: [type: :boolean, allow_nil?: false],
    loginPolicy: [type: :map, constraints: [fields: @policy], allow_nil?: false],
    emailAvailable: [type: :boolean, allow_nil?: false]
  ]
  @credentials [
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
  @member [
    uid: [type: PrincipalKey, allow_nil?: false],
    displayName: [type: :string, allow_nil?: false],
    email: [type: :string],
    status: [type: :string, allow_nil?: false],
    membership: [type: :string, allow_nil?: false],
    administrator: [type: :boolean, allow_nil?: false],
    credentials: @credentials
  ]
  @invitation [
    id: [type: UUIDv7, allow_nil?: false],
    kind: [type: :string, allow_nil?: false],
    membership: [type: :string, allow_nil?: false],
    invited_email: [type: :string],
    expires_at: [type: :utc_datetime_usec, allow_nil?: false],
    max_uses: [type: :integer],
    used_count: [type: :integer, allow_nil?: false],
    revoked_at: [type: :utc_datetime_usec]
  ]

  actions do
    action :settings, :map do
      constraints(fields: @settings)
      run(fn _, _ -> Admin.settings() end)
    end

    action :update_settings, :map do
      constraints(fields: @settings)

      argument(:displayName, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 160]
      )

      argument(:allowExternalGuests, :boolean, allow_nil?: false)
      argument(:loginPolicy, :map, constraints: [fields: @policy], allow_nil?: false)
      transaction?(false)
      run(fn input, context -> result(Admin.update_settings(context.actor, input.arguments)) end)
    end

    action :members, :map do
      constraints(
        fields: [
          members: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @member]]
          ]
        ]
      )

      run(fn _, _ -> {:ok, %{members: Admin.members()}} end)
    end

    action :create_member, :map do
      constraints(fields: [uid: [type: PrincipalKey, allow_nil?: false]])
      argument(:displayName, :string, allow_nil?: false)
      argument(:email, :string, allow_nil?: false, constraints: [min_length: 1])

      argument(:membership, :atom,
        allow_nil?: false,
        default: :member,
        constraints: [one_of: [:member, :guest]]
      )

      transaction?(false)

      run(fn input, _ ->
        Ankole.Repo.transact_top_level(fn ->
          with {:ok, principal} <-
                 Ankole.Principals.create_member_in_tx(%{
                   display_name: input.arguments.displayName,
                   email: Map.get(input.arguments, :email),
                   membership: input.arguments.membership
                 }),
               do: {:ok, %{uid: principal.uid}}
        end)
        |> result()
      end)
    end

    action :change_membership, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])
      argument(:uid, PrincipalKey, allow_nil?: false)
      argument(:membership, :atom, allow_nil?: false, constraints: [one_of: [:member, :guest]])
      transaction?(false)

      run(fn input, _ ->
        changed(
          Ankole.Principals.change_human_membership(
            input.arguments.uid,
            input.arguments.membership
          )
        )
      end)
    end

    action :set_admin, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])
      argument(:uid, PrincipalKey, allow_nil?: false)
      argument(:administrator, :boolean, allow_nil?: false)
      transaction?(false)

      run(fn input, _ ->
        changed(Admin.set_admin(input.arguments.uid, input.arguments.administrator))
      end)
    end

    action :disable_member, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])
      argument(:uid, PrincipalKey, allow_nil?: false)

      argument(:disposition, :atom,
        allow_nil?: false,
        constraints: [one_of: [:suspended, :offboarded]]
      )

      argument(:reason, :string, allow_nil?: false, constraints: [min_length: 1])
      transaction?(false)

      run(fn input, context ->
        changed(
          Admin.disable(
            context.actor,
            input.arguments.uid,
            input.arguments.disposition,
            input.arguments.reason
          )
        )
      end)
    end

    action :access_review, :map do
      constraints(fields: [review: [type: Ankole.Principals.AccessView, allow_nil?: false]])
      argument(:uid, PrincipalKey, allow_nil?: false)

      run(fn input, _ ->
        case Ankole.Principals.HumanAccess.console_view(input.arguments.uid) do
          {:ok, view} -> {:ok, %{review: Ankole.JSON.plain(view)}}
          error -> result(error)
        end
      end)
    end

    action :restore_member, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])
      argument(:uid, PrincipalKey, allow_nil?: false)
      argument(:reviewFingerprint, :string, allow_nil?: false)
      argument(:reason, :string, allow_nil?: false, constraints: [min_length: 1])
      argument(:identityVerified, :boolean, allow_nil?: false)
      transaction?(false)

      run(fn input, context ->
        if input.arguments.identityVerified,
          do:
            changed(
              Admin.restore(
                context.actor,
                input.arguments.uid,
                input.arguments.reviewFingerprint,
                input.arguments.reason
              )
            ),
          else: result({:error, :identity_review_required})
      end)
    end

    action :unbind_credential, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])
      argument(:uid, PrincipalKey, allow_nil?: false)
      argument(:credential_id, UUIDv7, allow_nil?: false)
      transaction?(false)

      run(fn input, _ ->
        changed(Admin.unbind(input.arguments.uid, input.arguments.credential_id))
      end)
    end

    action :invitations, :map do
      constraints(
        fields: [
          invitations: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @invitation]]
          ]
        ]
      )

      run(fn _, _ ->
        {:ok,
         %{
           invitations:
             Enum.map(
               Ankole.Principals.list_invitations(),
               &Map.take(&1, Keyword.keys(@invitation))
             )
         }}
      end)
    end

    action :create_invitation, :map do
      constraints(
        fields: [
          id: [type: UUIDv7, allow_nil?: false],
          url: [type: :string, allow_nil?: false],
          code: [type: :string, allow_nil?: false]
        ]
      )

      argument(:membership, :atom,
        allow_nil?: false,
        default: :member,
        constraints: [one_of: [:member, :guest]]
      )

      argument(:email, :string)
      argument(:expiresAt, :utc_datetime_usec, allow_nil?: false)
      argument(:maxUses, :integer, constraints: [min: 1])
      transaction?(false)

      run(fn input, context ->
        args = input.arguments
        email = Ankole.Principals.normalize_email(Map.get(args, :email))

        Ankole.Authn.Info.run_add_on(Ankole.Principals.Principal, :pod_invitation, :create, %{
          uid: Ankole.AuthZ.Actor.uid(context.actor),
          origin: input.context.pod_origin,
          attrs: %{
            kind: if(email, do: :email, else: :link),
            membership: args.membership,
            invited_email: email,
            expires_at: args.expiresAt,
            max_uses: Map.get(args, :maxUses)
          }
        })
        |> result()
      end)
    end

    action :revoke_invitation, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])
      argument(:id, UUIDv7, allow_nil?: false)
      transaction?(false)
      run(fn input, _ -> changed(Ankole.Principals.revoke_invitation(input.arguments.id)) end)
    end

    action :providers, :map do
      constraints(
        fields: [
          providers: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  provider_id: [type: :string, allow_nil?: false],
                  adapter_id: [type: :string, allow_nil?: false],
                  enabled: [type: :boolean, allow_nil?: false],
                  config: [type: JSONMap, allow_nil?: false],
                  stored_secret_paths: [type: {:array, :string}, allow_nil?: false]
                ]
              ]
            ]
          ],
          adapters: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  adapter_id: [type: :string, allow_nil?: false],
                  default_provider_id: [type: :string, allow_nil?: false],
                  display_name: [type: Ankole.Ash.Types.StringMap, allow_nil?: false],
                  fields: [type: {:array, Ankole.Plugins.ConfigField}, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      )

      run(fn _, _ ->
        with {:ok, providers} <- Ankole.IdentityProviders.list_configured_providers(),
             do:
               {:ok,
                %{
                  providers: Enum.map(providers, &Ankole.JSON.plain/1),
                  adapters:
                    Enum.map(Ankole.IdentityProviders.list_active_adapters(), fn adapter ->
                      adapter
                      |> Map.take([
                        :adapter_id,
                        :display_name,
                        :fields,
                        :default_provider_id,
                        :plugin_id
                      ])
                      |> Ankole.JSON.plain()
                    end)
                }}
      end)
    end

    for operation <- [:create_provider, :save_provider] do
      action operation, :map do
        constraints(fields: [ok: [type: :boolean, allow_nil?: false]])
        argument(:provider_id, :string, allow_nil?: false)
        argument(:adapter_id, :string, allow_nil?: false)
        argument(:config, JSONMap, allow_nil?: false, sensitive?: true)
        argument(:enabled, :boolean, allow_nil?: false)
        transaction?(false)

        run(fn input, _ ->
          args = input.arguments

          changed(
            Ankole.IdentityProviders.save_provider(
              args.provider_id,
              args.adapter_id,
              args.config,
              args.enabled,
              source: "pod_admin",
              mode: if(input.action.name == :create_provider, do: :create, else: :update)
            )
          )
        end)
      end
    end

    action :sync_directory, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])
      argument(:provider_id, :string, allow_nil?: false)
      transaction?(false)

      run(fn input, _ ->
        changed(
          Ankole.IdentityProviders.DirectorySync.enqueue_sync(input.arguments.provider_id,
            reason: "manual",
            source: "pod_admin"
          )
        )
      end)
    end
  end

  defp changed(:ok), do: {:ok, %{ok: true}}
  defp changed({:ok, _}), do: {:ok, %{ok: true}}
  defp changed(error), do: result(error)
  defp result({:error, reason}), do: Ankole.Authn.Error.login(reason)
  defp result(result), do: result
end
