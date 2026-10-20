defmodule AnkoleWeb.Plugs.RequestHostTest do
  use ExUnit.Case, async: true

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
end
