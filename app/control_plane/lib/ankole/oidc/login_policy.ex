defmodule Ankole.OIDC.LoginPolicy do
  @moduledoc false
  alias Ankole.IdentityProviders.Login
  alias Ankole.OIDC
  alias Ankole.OIDC.Client

  defp requires_auth_time?(params) do
    requires_login?(params) or is_integer(params["max_age"]) or
      params["auth_time_essential?"] == true
  end

  def can_reuse?(auth, params) when is_map(auth) do
    with age when is_nil(age) or is_integer(age) <- params["max_age"] do
      cond do
        reauthentication_required?(params) or selection_required?(params) -> false
        requires_auth_time?(params) and not is_integer(auth["auth_time"]) -> false
        is_integer(age) -> System.system_time(:second) - auth["auth_time"] <= age
        true -> true
      end
    else
      _ -> false
    end
  end

  def can_reuse?(_, _), do: false

  def selection_required?(params),
    do: select_account?(params) and params["selection_confirmed"] != true

  def authorization_ready?(%{status: :authenticated, request: request}),
    do: not selection_required?(request)

  def authorization_ready?(_), do: false

  def select_authentication(transaction, auth) do
    with :ok <- authorize_source(transaction.request["client_id"], auth["provider_id"]) do
      request = Map.put(transaction.request, "selection_confirmed", true)

      completed? =
        transaction.authentication_id == auth["authentication_id"] and
          transaction.authentication_revision == auth["authentication_revision"]

      reuse? =
        if completed?,
          do: completed_authentication_allowed?(auth, request) == :ok,
          else: can_reuse?(auth, request)

      {:ok, request, if(reuse?, do: :reuse, else: :reauthenticate)}
    end
  end

  def completed_authentication_allowed?(auth, params) do
    with age when is_nil(age) or is_integer(age) <- params["max_age"] do
      cond do
        requires_auth_time?(params) and not is_integer(auth["auth_time"]) ->
          {:error, :authentication_time_unavailable}

        is_integer(age) and age > 0 and System.system_time(:second) - auth["auth_time"] > age ->
          {:error, :authentication_too_old}

        true ->
          :ok
      end
    else
      _ -> {:error, :invalid_authentication_request}
    end
  end

  def providers(client, params) do
    with {:ok, providers} <- login_providers() do
      allowed =
        Enum.filter(providers, fn provider ->
          source_allowed?(client, provider["provider_id"]) and
            (not requires_auth_time?(params) or
               provider["fresh_authentication"] == true)
        end)

      if allowed == [], do: {:error, :no_allowed_login_provider}, else: {:ok, allowed}
    end
  end

  def authorize_source(%Client{} = client, provider_id) do
    with true <- source_allowed?(client, provider_id),
         {:ok, providers} <- login_providers(),
         true <- Enum.any?(providers, &(&1["provider_id"] == provider_id)) do
      :ok
    else
      false -> {:error, :identity_provider_not_allowed}
      error -> error
    end
  end

  def authorize_source(client_id, provider_id) do
    with {:ok, client} <- OIDC.get_active_client(client_id),
         do: authorize_source(client, provider_id)
  end

  def authorize_login(%{purpose: purpose}, provider_id) when purpose in [:console, :pod] do
    with {:ok, providers} <- login_providers(),
         true <- Enum.any?(providers, &(&1["provider_id"] == provider_id)) do
      :ok
    else
      false -> {:error, :identity_provider_not_allowed}
      error -> error
    end
  end

  def authorize_login(%{purpose: :oauth, request: request}, provider_id) do
    with {:ok, client} <- OIDC.get_active_client(request["client_id"]),
         {:ok, providers} <- providers(client, request),
         true <- Enum.any?(providers, &(&1["provider_id"] == provider_id)) do
      :ok
    else
      false -> {:error, :reauthentication_unsupported}
      error -> error
    end
  end

  def requires_login?(params), do: "login" in prompt_values(params) or params["max_age"] == 0

  def reauthentication_required?(params),
    do: params["reauthenticate"] == true or requires_login?(params)

  def upstream_options(transaction) do
    request = transaction.request

    prompt =
      cond do
        requires_login?(request) -> "login"
        select_account?(request) -> "select_account"
        true -> nil
      end

    [
      nonce: transaction.upstream_state,
      prompt: prompt,
      max_age: if(requires_login?(request), do: 0, else: request["max_age"]),
      auth_time_required: requires_auth_time?(request),
      auth_time_not_before:
        if(requires_login?(request), do: DateTime.to_unix(transaction.updated_at))
    ]
  end

  def select_account?(params), do: "select_account" in prompt_values(params)
  def silent?(params), do: "none" in prompt_values(params)

  def login_providers do
    with {:ok, providers} <- Login.list_login_providers(),
         {:ok, policy} <- Ankole.Principals.PodLoginPolicy.get() do
      site =
        Ankole.IdentityProviders.SiteSources.providers()
        |> Enum.reject(&(&1["provider_id"] == "email_otp" and not policy["allow_email_otp"]))

      {:ok, providers ++ site}
    end
  end

  defp prompt_values(params), do: params["prompt"] || []

  defp source_allowed?(%Client{allowed_identity_provider_ids: ids}, provider_id),
    do: is_binary(provider_id) and (ids == [] or provider_id in ids)
end
