defmodule Ankole.Authn.AddOns.SiteCredentialBinding do
  @moduledoc "Recent authentication and new credential verification for the current Pod member."
  alias Ankole.AuthZ.Actor
  alias Ankole.{Principals, Repo}

  @behaviour Ankole.Authn.AddOn
  @impl true
  def call(:request, params, _opts),
    do: request(params.actor, params.browser, params.email, params.ip, locale: params[:locale])

  def call(:verify, params, _opts),
    do: verify(params.actor, params.browser, params.id, params.code, params.ip)

  def call(:unbind, params, _opts), do: unbind(params.actor, params.id)

  def request(actor, browser, email, ip, opts \\ []) do
    with :ok <- permitted(actor),
         :ok <- recent(actor) do
      Ankole.Authn.Info.run(
        Principals.SiteCredential,
        :email_otp,
        :request,
        %{browser: browser, email: email, source: ip},
        purpose: "bind_credential",
        tenant_id: Actor.tenant_id(actor),
        principal_uid: Actor.uid(actor),
        locale: Keyword.get(opts, :locale),
        ceremony_context: %{
          "principal_uid" => Actor.uid(actor),
          "tenant_id" => Actor.tenant_id(actor)
        }
      )
    end
  end

  def verify(actor, browser, id, code, ip) do
    with :ok <- permitted(actor),
         :ok <- recent(actor) do
      Ankole.Authn.Info.run(
        Principals.SiteCredential,
        :email_otp,
        :verify,
        %{browser: browser, challenge_id: id, code: code, source: ip},
        complete: fn challenge ->
          with true <-
                 challenge.purpose == "bind_credential" and
                   challenge.ceremony_context ==
                     %{"principal_uid" => Actor.uid(actor), "tenant_id" => Actor.tenant_id(actor)},
               {:ok, %{status: :active}} <-
                 Principals.lock_principal_in_tx(Actor.uid(actor), :update),
               proof = Ankole.Authn.Strategies.Otp.Actions.proof(challenge),
               true <- Principals.site_credential_claim_current?(proof),
               :ok <- policy_allows(actor, proof),
               :ok <- Principals.replace_site_credential_in_tx(Actor.uid(actor), proof),
               do: Ankole.BrowserSessions.replace_site_credential_in_tx(browser, actor, proof),
               else: (
                 false -> {:error, :invalid_authentication}
                 error -> error
               )
        end
      )
    end
  end

  def unbind(actor, id) do
    with :ok <- permitted(actor),
         :ok <- recent(actor),
         do:
           Repo.transact_top_level(fn ->
             Principals.unbind_site_credential_in_tx(Actor.uid(actor), id)
           end)
  end

  def permitted(actor) do
    with {:ok, policy} <- Ankole.Principals.PodLoginPolicy.get(),
         true <-
           policy["allow_member_credential_change"] and policy["allow_email_otp"] and
             Ankole.Authn.Mailer.configured?() and
             not (Actor.principal(actor).membership == :member and
                    policy["require_sso_for_members"]),
         do: :ok,
         else: (_ -> {:error, :credential_change_disabled})
  end

  def recent(%Actor{authn: %{"authenticated_at" => time}}) when is_integer(time) do
    if System.system_time(:second) <= time + 900,
      do: :ok,
      else: {:error, :reauthentication_required}
  end

  def recent(_), do: {:error, :reauthentication_required}

  defp policy_allows(actor, proof) do
    if Ankole.Principals.PodLoginPolicy.authentication_allowed?(
         Actor.principal(actor),
         proof.provider_id,
         proof
       ), do: :ok, else: {:error, :login_policy_rejected}
  end
end
