defmodule AnkoleWeb.Plugs.RequestHostTest do
  use ExUnit.Case, async: false

  alias AnkoleWeb.Plugs.RequestHost

  test "the request origin excludes paths and queries and retains non-default ports" do
    for {url, expected} <- [
          {"http://example.com/a?token=x", "http://example.com"},
          {"https://example.com:443/a", "https://example.com"},
          {"https://example.com:8443/a", "https://example.com:8443"},
          {"http://[::1]:4000/a", "http://[::1]:4000"}
        ] do
      assert RequestHost.origin(Plug.Test.conn(:get, url)) == expected
    end
  end

  test "the default classification never returns :cloud_api" do
    assert RequestHost.classify_uri(URI.parse("https://cloudapis.example.com/v1/models")) ==
             {:ok, :site}

    assert RequestHost.classify_uri(URI.parse("https://site.example.com/v1/models")) ==
             {:ok, :site}
  end

  test "a registered classifier supplies a Host category and falls back on :error" do
    :ok =
      RequestHost.register_classifier(fn
        %URI{host: "cloudapis.example.com"} -> {:ok, :cloud_api}
        _uri -> :error
      end)

    on_exit(fn -> RequestHost.unregister_classifier() end)

    assert is_function(RequestHost.classifier(), 1)

    assert RequestHost.classify_uri(URI.parse("https://cloudapis.example.com/v1/models")) ==
             {:ok, :cloud_api}

    assert RequestHost.classify_uri(URI.parse("https://site.example.com/pages")) == {:ok, :site}

    conn = RequestHost.call(Plug.Test.conn(:get, "https://cloudapis.example.com/v1/models"), [])
    assert conn.assigns.host_context == :cloud_api
    refute conn.halted
  end

  test "a registered classifier module is resolved by classify/1" do
    :ok = RequestHost.register_classifier(AnkoleWeb.Plugs.RequestHostTest.CloudApiHost)
    on_exit(fn -> RequestHost.unregister_classifier() end)

    assert RequestHost.classify_uri(URI.parse("https://cloudapis.example.com/v1/models")) ==
             {:ok, :cloud_api}
  end

  defmodule CloudApiHost do
    def classify(%URI{host: "cloudapis.example.com"}), do: {:ok, :cloud_api}
    def classify(_uri), do: :error
  end
end
