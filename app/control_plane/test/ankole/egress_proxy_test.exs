defmodule Ankole.EgressProxyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ankole.EgressProxy

  setup do
    vars = ~w(HTTPS_PROXY https_proxy ALL_PROXY all_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy)
    saved = Map.new(vars, &{&1, System.get_env(&1)})
    Enum.each(vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  test "redacts proxy userinfo credentials from invalid proxy warning logs" do
    System.put_env("HTTPS_PROXY", "http://user:secret_pass@bad-proxy:70000")

    log =
      capture_log([metadata: [:event, :proxy_scheme, :proxy_host, :error_class]], fn ->
        assert EgressProxy.req_options("https://auth.openai.com/oauth/token") == []
      end)

    assert log =~ "egress_proxy.invalid_proxy"
    assert log =~ "bad-proxy"
    refute log =~ "secret_pass"
    refute log =~ "user:secret_pass"

    log_required =
      capture_log([metadata: [:event, :proxy_scheme, :proxy_host, :error_class]], fn ->
        assert {:error, :invalid_proxy} =
                 EgressProxy.resolve_req_options(
                   "https://auth.openai.com/oauth/token",
                   proxy_url: "http://user:secret_pass@bad-proxy:70000",
                   require_proxy: true
                 )
      end)

    assert log_required =~ "bad-proxy"
    refute log_required =~ "secret_pass"
    refute log_required =~ "user:secret_pass"
  end

  test "accepts portless and IPv6 proxy URLs" do
    assert {:ok, [connect_options: connect_opts]} =
             EgressProxy.resolve_req_options("https://auth.openai.com/oauth/token",
               proxy_url: "http://proxy.corp",
               require_proxy: true
             )

    assert Keyword.get(connect_opts, :proxy) == {:http, "proxy.corp", 80, []}

    assert {:ok, [connect_options: ipv6_opts]} =
             EgressProxy.resolve_req_options("https://auth.openai.com/oauth/token",
               proxy_url: "http://[::1]:3128",
               require_proxy: true
             )

    assert Keyword.get(ipv6_opts, :proxy) == {:http, "::1", 3128, []}
  end

  test "sanitized proxy metadata never logs a credential fragment as the scheme" do
    assert EgressProxy.sanitized_proxy_metadata("user:secret@proxy:3128") == %{
             error_class: "invalid_proxy_url"
           }

    assert EgressProxy.sanitized_proxy_metadata("http://user:secret@proxy:3128") == %{
             proxy_scheme: "http",
             proxy_host: "proxy",
             error_class: "invalid_proxy_url"
           }
  end

  test "resolve_req_options fails closed when require_proxy is true and proxy is missing or invalid" do
    assert {:error, :proxy_required} =
             EgressProxy.resolve_req_options("https://auth.openai.com/oauth/token",
               require_proxy: true
             )

    assert {:ok, [connect_options: connect_opts]} =
             EgressProxy.resolve_req_options("https://auth.openai.com/oauth/token",
               proxy_url: "http://user:secret_pass@127.0.0.1:8888",
               require_proxy: true
             )

    assert Keyword.get(connect_opts, :proxy) == {:http, "127.0.0.1", 8888, []}
    assert [{"proxy-authorization", _}] = Keyword.get(connect_opts, :proxy_headers)
  end
end
