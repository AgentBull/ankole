defmodule Ankole.Authn.AddOns.PodInvitation do
  @moduledoc "Invitation delivery outside the domain's durable invitation transaction."
  @behaviour Ankole.Authn.AddOn
  @impl true
  def call(:create, %{uid: uid, attrs: attrs, origin: origin} = params, opts) do
    mail_opts =
      opts
      |> Keyword.take([:locale])
      |> Keyword.merge(if(params[:locale], do: [locale: params[:locale]], else: []))

    with :ok <- delivery_available(attrs.invited_email),
         {:ok, created} <- Ankole.Principals.create_invitation(uid, attrs),
         {:ok, tenant} <- Ankole.Tenants.get(Ankole.Repo.tenant_id!()),
         url = origin <> "/join/" <> created.token,
         result <- deliver(attrs.invited_email, url, tenant.display_name, mail_opts) do
      case result do
        :ok ->
          {:ok, %{id: created.invitation.id, url: url, code: created.code}}

        error ->
          {:ok, _} = Ankole.Principals.revoke_invitation(created.invitation.id)
          error
      end
    end
  end

  defp delivery_available(nil), do: :ok

  defp delivery_available(_email) do
    if Ankole.Authn.Mailer.configured?(), do: :ok, else: {:error, :mail_unavailable}
  end

  defp deliver(nil, _, _, _), do: :ok

  defp deliver(email, url, name, opts),
    do: Ankole.Authn.Mailer.send_invitation(email, url, name, opts)
end
