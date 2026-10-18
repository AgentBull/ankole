defmodule Ankole.EmailTransportFixtures.SMTP do
  @moduledoc false

  @behaviour :gen_smtp_server_session

  def init(_hostname, _session_count, _address, options) do
    {:ok, "fake ESMTP", %{parent: Keyword.fetch!(options, :parent)}}
  end

  def handle_HELO(_hostname, state), do: {:ok, state}

  def handle_EHLO(_hostname, extensions, state),
    do: {:ok, extensions ++ [{~c"AUTH", ~c"PLAIN LOGIN"}], state}

  def handle_MAIL(_from, state), do: {:ok, state}
  def handle_MAIL_extension(_extension, _state), do: :error
  def handle_RCPT("nobody@example.org", state), do: {:error, "550 No such recipient", state}
  def handle_RCPT(_to, state), do: {:ok, state}
  def handle_RCPT_extension(_extension, _state), do: :error

  def handle_DATA(from, to, data, state) do
    send(state.parent, {:smtp_data, from, to, data})
    {:ok, "queued as fake-1", state}
  end

  def handle_RSET(state), do: state
  def handle_VRFY(_address, state), do: {:error, "252 VRFY disabled", state}

  def handle_other(verb, _args, state),
    do: {["500 Error: command not recognized : '", verb, "'"], state}

  def handle_AUTH(type, "agent", "secret", state) when type in [:login, :plain], do: {:ok, state}
  def handle_AUTH(_type, _username, _credential, _state), do: :error

  def handle_STARTTLS(state), do: state
  def handle_info(_info, state), do: {:noreply, state}
  def handle_error(_class, _details, state), do: {:ok, state}
  def code_change(_old, state, _extra), do: {:ok, state}
  def terminate(reason, state), do: {:ok, reason, state}
end

defmodule Ankole.EmailTransportFixtures do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]
  alias Ankole.EmailTransportFixtures.SMTP, as: FakeSmtp

  def start_fake_smtp do
    name = :"fake_smtp_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      :gen_smtp_server.start(name, FakeSmtp,
        port: 0,
        address: {127, 0, 0, 1},
        domain: ~c"fake.test",
        sessionoptions: [callbackoptions: [parent: self()]]
      )

    on_exit(fn -> :ranch.stop_listener(name) end)
    :ranch.get_port(name)
  end

  def start_fake_tls_smtp do
    rsa = [{:key, {:rsa, 2048, 17}}, {:digest, :sha256}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: rsa, intermediates: [], peer: rsa ++ [{:extensions, [san]}]},
        client_chain: %{root: rsa, intermediates: [], peer: rsa}
      })

    name = :"fake_tls_smtp_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      :gen_smtp_server.start(name, FakeSmtp,
        port: 0,
        address: {127, 0, 0, 1},
        domain: ~c"fake.test",
        protocol: :ssl,
        ranch_opts: %{socket_opts: Keyword.take(data[:server_config], [:cert, :key])},
        sessionoptions: [callbackoptions: [parent: self()]]
      )

    on_exit(fn -> :ranch.stop_listener(name) end)
    {:ranch.get_port(name), data[:client_config][:cacerts]}
  end
end
