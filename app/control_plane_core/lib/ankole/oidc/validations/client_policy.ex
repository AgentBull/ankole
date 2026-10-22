defmodule Ankole.OIDC.Validations.ClientPolicy do
  @moduledoc false
  use Ash.Resource.Validation

  @scheme_format ~r/\A[a-z][a-z0-9+.-]*\z/
  @unsafe_native_schemes ~w(about blob data file javascript vbscript)

  @impl true
  def validate(changeset, _opts, _context) do
    value = &Ash.Changeset.get_attribute(changeset, &1)
    scopes = value.(:scopes) || []
    aliases = value.(:model_aliases) || %{}

    errors =
      redirect_errors(value.(:redirect_uris) || []) ++
        scope_errors(scopes) ++
        secret_errors(value.(:client_type), value.(:secret_ciphertext)) ++
        model_errors(scopes, aliases) ++
        logout_errors(value)

    case errors do
      [] ->
        :ok

      errors ->
        {:error,
         Enum.map(errors, fn {field, message} ->
           Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)
         end)}
    end
  end

  def redirect_origin(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} = parsed
      when scheme in ["http", "https"] and is_binary(host) ->
        URI.to_string(%URI{
          scheme: parsed.scheme,
          host: String.downcase(parsed.host),
          port: parsed.port
        })

      _uri ->
        nil
    end
  end

  def redirect_origin(_uri), do: nil

  defp redirect_errors(uris),
    do:
      Enum.flat_map(uris, fn uri ->
        if valid_redirect_uri?(uri),
          do: [],
          else: [redirect_uris: "contains an invalid redirect URI"]
      end)

  defp scope_errors(scopes) do
    allowed = Ankole.OIDC.Client.supported_scopes()

    errors =
      if Enum.all?(scopes, &(&1 in allowed)), do: [], else: [scopes: "has an invalid entry"]

    if "openid" in scopes, do: errors, else: [scopes: "must include openid"] ++ errors
  end

  defp secret_errors(:public, nil), do: []
  defp secret_errors(:confidential, secret) when is_binary(secret) and secret != "", do: []

  defp secret_errors(:public, _secret),
    do: [secret_ciphertext: "must be empty for a public client"]

  defp secret_errors(:confidential, _secret), do: [secret_ciphertext: "is required"]
  defp secret_errors(_type, _secret), do: []

  defp model_errors(scopes, aliases) do
    if "ai_gateway.write" in scopes and map_size(aliases) == 0,
      do: [model_aliases: "must not be empty with ai_gateway.write"],
      else: []
  end

  defp logout_errors(value) do
    allow_http =
      value.(:allow_insecure_local_logout) == true and value.(:client_type) == :confidential

    errors =
      if value.(:allow_insecure_local_logout) == true and not allow_http,
        do: [allow_insecure_local_logout: "requires a confidential Client"],
        else: []

    uris = Enum.map(value.(:post_logout_redirect_uris) || [], &{:post_logout_redirect_uris, &1})
    backchannel = value.(:backchannel_logout_uri)

    uris =
      if is_binary(backchannel) and backchannel != "",
        do: [{:backchannel_logout_uri, backchannel} | uris],
        else: uris

    Enum.reduce(uris, errors, fn {field, uri}, errors ->
      parsed = URI.parse(uri)

      valid =
        valid_redirect_uri?(uri) and
          (parsed.scheme == "https" or
             (allow_http and parsed.scheme == "http" and localhost?(parsed.host)))

      if valid,
        do: errors,
        else: [{field, "requires HTTPS or an enabled confidential local callback"} | errors]
    end)
  end

  defp valid_redirect_uri?(uri) when is_binary(uri) do
    parsed = URI.parse(uri)

    cond do
      uri =~ "*" or uri =~ ~r/\s/ -> false
      not is_binary(parsed.scheme) or not Regex.match?(@scheme_format, parsed.scheme) -> false
      not is_nil(parsed.fragment) or not is_nil(parsed.userinfo) -> false
      parsed.scheme == "https" -> is_binary(parsed.host) and parsed.host != ""
      parsed.scheme == "http" -> localhost?(parsed.host)
      parsed.scheme in @unsafe_native_schemes -> false
      true -> native_redirect?(parsed)
    end
  end

  defp valid_redirect_uri?(_uri), do: false

  defp localhost?(host) when is_binary(host),
    do: String.downcase(host) in ["localhost", "127.0.0.1", "::1"]

  defp localhost?(_host), do: false

  defp native_redirect?(%URI{host: host, path: path}),
    do: (is_binary(host) and host != "") or (is_binary(path) and path != "")
end
