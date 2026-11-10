defmodule Ankole.EgressProxy do
  @moduledoc """
  Resolves the HTTPS_PROXY/ALL_PROXY/HTTP_PROXY/NO_PROXY environment for
  control-plane Req calls.

  The kernel's UniversalAIClient reads the same variables for model traffic;
  an Elixir call site composes `req_options/1` in so both runtimes leave the
  instance through the same proxy. Differences stay explicit: this module
  speaks only `http://` and `https://` proxies (Mint has no SOCKS support),
  and NO_PROXY entries match by host or dot-suffix, not by CIDR block. An
  unsupported or unparsable proxy value logs a warning and connects directly,
  so a misconfigured proxy stays visible in the log instead of failing
  silently.
  """

  alias Ankole.Logging

  @doc """
  Returns Req options for one outbound URL: a proxy with optional
  Proxy-Authorization when the environment or `opts` configures one,
  otherwise `[]`.
  """
  @spec req_options(String.t(), keyword()) :: keyword()
  def req_options(url, opts \\ []) when is_binary(url) and is_list(opts) do
    case resolve_req_options(url, opts) do
      {:ok, req_opts} -> req_opts
      {:error, _reason} -> []
    end
  end

  @doc """
  Resolves Req proxy options for `url`, failing closed with
  `{:error, :proxy_required | :invalid_proxy}` when `require_proxy: true`
  or an explicit `proxy_url` is supplied and cannot be used.
  """
  @spec resolve_req_options(String.t(), keyword()) ::
          {:ok, keyword()} | {:error, :proxy_required | :invalid_proxy}
  def resolve_req_options(url, opts \\ []) when is_binary(url) and is_list(opts) do
    explicit = Keyword.get(opts, :proxy_url)

    require_proxy? =
      Keyword.get(opts, :require_proxy, false) == true or
        (is_binary(explicit) and String.trim(explicit) != "")

    cond do
      is_binary(explicit) and String.trim(explicit) != "" ->
        resolve_required_proxy_value(String.trim(explicit))

      require_proxy? ->
        case env_proxy_for_url(url) do
          {:ok, value} ->
            resolve_required_proxy_value(value)

          :none ->
            Logging.warning(
              "egress_proxy.proxy_required",
              "an outbound proxy is required but no proxy is configured; failing closed",
              %{error_class: "proxy_required"}
            )

            {:error, :proxy_required}
        end

      true ->
        resolve_optional_env_proxy(url)
    end
  end

  @doc """
  Extracts sanitized proxy log metadata (`proxy_scheme`, `proxy_host`,
  `error_class`) while stripping any `userinfo` credentials or raw URL text.
  """
  @spec sanitized_proxy_metadata(term(), String.t()) :: map()
  def sanitized_proxy_metadata(value, error_class \\ "invalid_proxy_url") do
    case safe_parse_uri(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        %{
          proxy_scheme: scheme,
          proxy_host: sanitize_host(host),
          error_class: error_class
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

      _ ->
        %{error_class: error_class}
    end
  end

  defp resolve_required_proxy_value(value) do
    case parse_proxy(value) do
      {:ok, proxy, headers} ->
        {:ok, [connect_options: [proxy: proxy] ++ proxy_header_options(headers)]}

      :error ->
        Logging.warning(
          "egress_proxy.invalid_proxy",
          "the required proxy URL is invalid or unsupported; failing closed",
          sanitized_proxy_metadata(value, "invalid_proxy_url")
        )

        {:error, :invalid_proxy}
    end
  end

  defp resolve_optional_env_proxy(url) do
    case env_proxy_for_url(url) do
      {:ok, value} ->
        case parse_proxy(value) do
          {:ok, proxy, headers} ->
            {:ok, [connect_options: [proxy: proxy] ++ proxy_header_options(headers)]}

          :error ->
            Logging.warning(
              "egress_proxy.invalid_proxy",
              "the configured proxy URL is unsupported; connecting directly",
              sanitized_proxy_metadata(value, "invalid_proxy_url")
            )

            {:ok, []}
        end

      :none ->
        {:ok, []}
    end
  end

  defp env_proxy_for_url(url) do
    with value when is_binary(value) <-
           environment_value(
             ~w(HTTPS_PROXY https_proxy ALL_PROXY all_proxy HTTP_PROXY http_proxy)
           ),
         %URI{host: host} when is_binary(host) and host != "" <- URI.parse(url),
         false <- no_proxy?(host) do
      {:ok, String.trim(value)}
    else
      _no_proxy -> :none
    end
  end

  defp proxy_header_options([]), do: []
  defp proxy_header_options(headers), do: [proxy_headers: headers]

  defp environment_value(names) do
    Enum.find_value(names, fn name ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" -> value
        _value -> nil
      end
    end)
  end

  defp no_proxy?(host) do
    case environment_value(~w(NO_PROXY no_proxy)) do
      nil ->
        false

      list ->
        list
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.any?(&no_proxy_entry_matches?(&1, host))
    end
  end

  defp no_proxy_entry_matches?("*", _host), do: true

  defp no_proxy_entry_matches?(entry, host) do
    bare = String.trim_leading(entry, ".")
    host == bare or String.ends_with?(host, "." <> bare)
  end

  defp parse_proxy(value) when is_binary(value) do
    trimmed = String.trim(value)

    with {:ok, %URI{scheme: scheme, host: host, port: port} = uri} <- URI.new(trimmed),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "",
         true <- is_integer(port) and port in 1..65_535,
         true <- declared_port_or_scheme_default?(trimmed, scheme, host, port),
         true <- uri.path in [nil, "", "/"] and is_nil(uri.query) and is_nil(uri.fragment) do
      {:ok, {String.to_existing_atom(scheme), host, port, []}, proxy_auth_headers(uri)}
    else
      _invalid -> :error
    end
  end

  defp parse_proxy(_value), do: :error

  defp declared_port_or_scheme_default?(raw, scheme, host, port)
       when is_binary(raw) and is_binary(host) and is_integer(port) do
    host_marker = if String.contains?(host, ":"), do: "[#{host}]", else: host

    String.contains?(raw, host_marker <> ":" <> Integer.to_string(port)) or
      (not String.contains?(raw, host_marker <> ":") and port == default_proxy_port(scheme))
  end

  defp default_proxy_port("http"), do: 80
  defp default_proxy_port("https"), do: 443

  defp safe_parse_uri(value) when is_binary(value), do: URI.parse(String.trim(value))
  defp safe_parse_uri(_value), do: nil

  defp sanitize_host(host) when is_binary(host) do
    host
    |> String.split("@")
    |> List.last()
    |> to_string()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
  end

  defp sanitize_host(_host), do: nil

  defp proxy_auth_headers(%URI{userinfo: userinfo}) when is_binary(userinfo) and userinfo != "" do
    [{"proxy-authorization", "Basic " <> Base.encode64(userinfo)}]
  end

  defp proxy_auth_headers(_uri), do: []
end
