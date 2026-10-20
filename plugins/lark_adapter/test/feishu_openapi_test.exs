defmodule FeishuOpenAPITest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.Client

  describe "FeishuOpenAPI.new/3" do
    test "defaults to the Feishu domain" do
      client = FeishuOpenAPI.new("cli_x", "secret_x")
      assert %Client{app_id: "cli_x", domain: :feishu} = client
      assert client.base_url == "https://open.feishu.cn"
    end

    test "accepts a Lark domain" do
      client = FeishuOpenAPI.new("cli_x", "secret_x", domain: :lark)
      assert client.base_url == "https://open.larksuite.com"
    end

    test "accepts an explicit base_url override" do
      client = FeishuOpenAPI.new("cli_x", "secret_x", base_url: "https://example.test")
      assert client.base_url == "https://example.test"
    end
  end
end
