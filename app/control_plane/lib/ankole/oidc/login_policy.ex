defmodule Ankole.OIDC.LoginPolicy do
  @moduledoc false
  alias Ankole.IdentityProviders.Login
  alias Ankole.OIDC
  alias Ankole.OIDC.Client

  def validate(params) do
    with true <- params["prompt"] in [nil, "none", "login"],
         {:ok, _} <- max_age(params),
         {:ok, _} <- essential_auth_time(params) do
      :ok
    else
      _ -> {:error, "invalid_request", "prompt, max_age, or essential claims are not supported"}
    end
  end

  def requires_auth_time?(params) do
    params["prompt"] == "login" or Map.has_key?(params, "max_age") or
      essential_auth_time(params) == {:ok, true}
  end

  def can_reuse?(auth, params) when is_map(auth) do
    with {:ok, age} <- max_age(params) do
      cond do
        params["prompt"] == "login" or age == 0 -> false
        requires_auth_time?(params) and not is_integer(auth["auth_time"]) -> false
        is_integer(age) -> System.system_time(:second) - auth["auth_time"] <= age
        true -> true
      end
    else
      _ -> false
    end
  end

  def can_reuse?(_, _), do: false

  def completed_authentication_allowed?(auth, params) do
    with {:ok, age} <- max_age(params) do
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
    with {:ok, providers} <- Login.list_login_providers() do
      allowed =
        Enum.filter(providers, fn provider ->
          source_allowed?(client, provider["provider_id"]) and
            (not requires_auth_time?(params) or provider["kind"] == "password")
        end)

      if allowed == [], do: {:error, :no_allowed_login_provider}, else: {:ok, allowed}
    end
  end

  def authorize_source(%Client{} = client, provider_id) do
    with true <- source_allowed?(client, provider_id),
         {:ok, providers} <- Login.list_login_providers(),
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

  def authorize_login(%{purpose: :console}, provider_id) do
    with {:ok, providers} <- Login.list_login_providers(),
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

  defp source_allowed?(%Client{allowed_identity_provider_ids: ids}, provider_id),
    do: is_binary(provider_id) and (ids == [] or provider_id in ids)

  defp max_age(%{"max_age" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 and seconds <= 2_147_483_647 ->
        if Regex.match?(~r/\A[0-9]+\z/, value), do: {:ok, seconds}, else: :error

      _ ->
        :error
    end
  end

  defp max_age(%{"max_age" => _}), do: :error
  defp max_age(_), do: {:ok, nil}

  defp essential_auth_time(%{"claims" => raw}) when is_binary(raw) do
    with {:ok, %{} = claims} <- Ankole.JSON.decode(raw),
         true <-
           Enum.all?(claims, fn {target, fields} ->
             target in ["id_token", "userinfo"] and is_map(fields) and
               Enum.all?(fields, fn
                 {"auth_time", %{} = requirement} ->
                   target == "id_token" and Map.keys(requirement) -- ["essential"] == [] and
                     requirement["essential"] in [nil, true, false]

                 {_name, %{"essential" => true}} ->
                   false

                 {_name, value} ->
                   is_nil(value) or is_map(value)
               end)
           end) do
      {:ok, get_in(claims, ["id_token", "auth_time", "essential"]) == true}
    else
      _ -> :error
    end
  end

  defp essential_auth_time(%{"claims" => _}), do: :error
  defp essential_auth_time(_), do: {:ok, false}
end
