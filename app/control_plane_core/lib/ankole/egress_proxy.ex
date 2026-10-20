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
  Proxy-Authorization when the environment configures one, otherwise `[]`.
  """
  @spec req_options(String.t()) :: keyword()
  def req_options(url) when is_binary(url) do
    with value when is_binary(value) <-
           environment_value(
             ~w(HTTPS_PROXY https_proxy ALL_PROXY all_proxy HTTP_PROXY http_proxy)
           ),
         %URI{host: host} when is_binary(host) <- URI.parse(url),
         false <- no_proxy?(host) do
      case parse_proxy(value) do
        {:ok, proxy, headers} ->
          [connect_options: [proxy: proxy] ++ proxy_header_options(headers)]

        :error ->
          Logging.warning(
            "egress_proxy.invalid_proxy",
            "the configured proxy URL is unsupported; connecting directly",
            %{proxy: value}
          )

          []
      end
    else
      _no_proxy -> []
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

  defp parse_proxy(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, port: port} = uri
      when scheme in ["http", "https"] and is_binary(host) and is_integer(port) ->
        {:ok, {String.to_existing_atom(scheme), host, port, []}, proxy_auth_headers(uri)}

      _invalid ->
        :error
    end
  end

  defp proxy_auth_headers(%URI{userinfo: userinfo}) when is_binary(userinfo) and userinfo != "" do
    [{"proxy-authorization", "Basic " <> Base.encode64(userinfo)}]
  end

  defp proxy_auth_headers(_uri), do: []
end
