defmodule FeishuOpenAPI.ClientTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.Client

  test "app_secret is hidden from inspect/1" do
    client = Client.new("cli_i", "secret_should_not_appear")

    rendered = inspect(client)

    refute rendered =~ "secret_should_not_appear"
    assert rendered =~ "cli_i"
  end

  test "app_secret can be provided as a closure for lazy evaluation" do
    parent = self()

    fun = fn ->
      send(parent, :resolved)
      "lazy_secret"
    end

    client = Client.new("cli_lazy", fun)

    refute_received :resolved

    assert Client.app_secret(client) == "lazy_secret"
    assert_received :resolved
  end

  test "default req_options carry both timeouts inside :finch only" do
    client = Client.new("cli_t", "secret")

    assert client.req_options[:receive_timeout] == :timer.seconds(15)
    assert client.req_options[:finch][:pool_timeout] == :timer.seconds(5)
    assert client.req_options[:finch][:conn_opts][:transport_opts][:timeout] == :timer.seconds(5)

    # Req 0.7 raises on a request that sets both :finch and :connect_options,
    # so the defaults must never include :connect_options.
    refute Keyword.has_key?(client.req_options, :connect_options)
  end

  test "user-supplied req_options override defaults and deep-merge :finch" do
    client =
      Client.new("cli_t2", "secret",
        req_options: [receive_timeout: :timer.seconds(99), finch: [pool_timeout: 1_234]]
      )

    assert client.req_options[:receive_timeout] == :timer.seconds(99)
    assert client.req_options[:finch][:pool_timeout] == 1_234
    assert client.req_options[:finch][:conn_opts][:transport_opts][:timeout] == :timer.seconds(5)
  end

  test "user-supplied :connect_options replaces the :finch defaults" do
    client =
      Client.new("cli_t3", "secret", req_options: [connect_options: [timeout: 1_234]])

    assert client.req_options[:connect_options][:timeout] == 1_234
    refute Keyword.has_key?(client.req_options, :finch)
  end

  test "a named Finch pool replaces the :finch defaults instead of merging" do
    client =
      Client.new("cli_t4", "secret", req_options: [finch: [name: MyNamedPool]])

    # Req 0.7 rejects pool-creation options such as :conn_opts together with
    # :name, so no default pool option may survive the merge.
    assert client.req_options[:finch] == [name: MyNamedPool]
  end

  test "from_env/1 reads Application config" do
    Application.put_env(:feishu_openapi, :default_client,
      app_id: "env_app",
      app_secret: "env_secret",
      domain: :lark
    )

    try do
      client = Client.from_env()
      assert client.app_id == "env_app"
      assert client.domain == :lark
      assert Client.app_secret(client) == "env_secret"
    after
      Application.delete_env(:feishu_openapi, :default_client)
    end
  end

  test "raises on invalid app_type" do
    assert_raise ArgumentError, ~r/app_type/, fn ->
      Client.new("cli_bad", "secret", app_type: :custom_app)
    end
  end

  test "raises on invalid string domain/base URL" do
    assert_raise ArgumentError, ~r/base_url|domain/, fn ->
      Client.new("cli_bad", "secret", domain: "not-a-url")
    end
  end

  test "raises on malformed default headers" do
    assert_raise ArgumentError, ~r/headers/, fn ->
      Client.new("cli_bad", "secret", headers: [authorization: "token"])
    end
  end

  describe "Error.Inspect protocol" do
    test "redacts raw_body and details" do
      err = %FeishuOpenAPI.Error{
        code: 42,
        msg: "oops",
        log_id: "log-x",
        raw_body: %{"secret" => "do-not-show", "code" => 42},
        details: %{"permission_violations" => [1, 2, 3]}
      }

      rendered = inspect(err)

      refute rendered =~ "do-not-show"
      refute rendered =~ "permission_violations"
      assert rendered =~ "redacted"
      assert rendered =~ "log-x"
      assert rendered =~ "42"
    end
  end

  describe "Error.message/1" do
    test "points numeric business codes at the official error-code reference" do
      err = %FeishuOpenAPI.Error{code: 44_004, msg: "permission denied", log_id: "log-x"}
      rendered = Exception.message(err)

      assert rendered =~ "code=44004"
      assert rendered =~ "msg=permission denied"
      assert rendered =~ FeishuOpenAPI.Error.error_code_reference_url()
    end

    test "does not append the reference URL for SDK-internal atom codes" do
      for code <- [:transport, :rate_limited, :http_error, :bad_path, :tenant_key_required] do
        err = %FeishuOpenAPI.Error{code: code, msg: "some msg"}
        rendered = Exception.message(err)

        refute rendered =~ FeishuOpenAPI.Error.error_code_reference_url(),
               "unexpected doc URL for SDK-internal code #{inspect(code)}"
      end
    end
  end
end
