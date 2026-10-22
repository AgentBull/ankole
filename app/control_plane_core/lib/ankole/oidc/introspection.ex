defmodule Ankole.OIDC.Introspection do
  @moduledoc false
  alias Ankole.OIDC.{RefreshStore, Sessions, Tokens}

  def check(token, client) do
    with {:ok, _key} <- Ankole.OIDC.SigningKey.get(),
         {:ok, _providers} <- Ankole.IdentityProviders.Login.list_login_providers() do
      {:ok, credential(token, client.id)}
    else
      _ -> {:error, :temporarily_unavailable}
    end
  end

  defp credential(token, id) do
    case Tokens.verify_access_context(token, Tokens.userinfo_audience()) do
      {:ok, %{claims: %{"client_id" => ^id} = claims}} ->
        Map.take(claims, ~w(iss sub client_id scope exp iat)) |> Map.put("active", true)

      {:ok, _} ->
        %{active: false}

      _ ->
        refresh(token, id)
    end
  end

  defp refresh(token, id) do
    with {:ok, %{consumed: false, data: %{client_id: ^id} = context} = entry} <-
           RefreshStore.get(Attesto.Secret.hash(token)),
         true <- entry.expires_at > System.system_time(:second),
         scope <- Enum.join(context.scope, " "),
         {:ok, _} <-
           Sessions.validate(context.claims["session_id"], id, context.subject, scope, :refresh) do
      %{
        active: true,
        iss: Ankole.TokenSigning.issuer(),
        sub: context.subject,
        client_id: id,
        scope: scope,
        exp: entry.expires_at
      }
    else
      _ -> %{active: false}
    end
  end
end
