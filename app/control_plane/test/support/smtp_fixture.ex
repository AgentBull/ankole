defmodule Ankole.Authn.SMTPFixture do
  @moduledoc "Local test SMTP peer. Production gen_smtp uses its real TLS socket."
  @behaviour :gen_smtp_server_session

  def start(parent, opts \\ []) do
    rsa = [{:key, {:rsa, 2048, 17}}, {:digest, :sha256}]

    san =
      {:Extension, {2, 5, 29, 17}, false,
       [
         dNSName: String.to_charlist(Keyword.get(opts, :hostname, "localhost")),
         iPAddress: <<127, 0, 0, 1>>
       ]}

    certificates =
      :public_key.pkix_test_data(%{
        server_chain: %{root: rsa, intermediates: [], peer: rsa ++ [{:extensions, [san]}]},
        client_chain: %{root: rsa, intermediates: [], peer: rsa}
      })

    name = :"authn_smtp_#{System.unique_integer([:positive])}"
    ca_path = Path.join(System.tmp_dir!(), "#{name}.pem")
    ca = Enum.map(certificates[:client_config][:cacerts], &{:Certificate, &1, :not_encrypted})
    File.write!(ca_path, :public_key.pem_encode(ca))

    {:ok, _} =
      :gen_smtp_server.start(name, __MODULE__,
        port: 0,
        address: Keyword.get(opts, :address, {127, 0, 0, 1}),
        domain: ~c"localhost",
        protocol: :ssl,
        ranch_opts: %{socket_opts: Keyword.take(certificates[:server_config], [:cert, :key])},
        sessionoptions: [callbackoptions: [parent: parent]]
      )

    %{name: name, port: :ranch.get_port(name), ca_path: ca_path}
  end

  def stop(server) do
    :ranch.stop_listener(server.name)
    File.rm(server.ca_path)
  end

  def text(message), do: message |> Ankole.Plugins.EmailAdapter.Mime.parse() |> text_part()
  def html(message), do: message |> Ankole.Plugins.EmailAdapter.Mime.parse() |> html_part()
  defp text_part(%{type: "text", subtype: "plain", body: body}), do: body
  defp text_part(%{parts: parts}) when is_list(parts), do: Enum.find_value(parts, &text_part/1)
  defp text_part(_), do: nil
  defp html_part(%{type: "text", subtype: "html", body: body}), do: body
  defp html_part(%{parts: parts}) when is_list(parts), do: Enum.find_value(parts, &html_part/1)
  defp html_part(_), do: nil

  @impl true
  def init(_, _, _, options),
    do: {:ok, "Local test SMTP", %{parent: Keyword.fetch!(options, :parent)}}

  @impl true
  def handle_HELO(_, state), do: {:ok, state}
  @impl true
  def handle_EHLO(_, extensions, state), do: {:ok, extensions, state}
  @impl true
  def handle_MAIL(_, state), do: {:ok, state}
  @impl true
  def handle_MAIL_extension(_, _), do: :error
  @impl true
  def handle_RCPT(_, state), do: {:ok, state}
  @impl true
  def handle_RCPT_extension(_, _), do: :error
  @impl true
  def handle_DATA(from, to, data, state) do
    send(state.parent, {:smtp_message, from, to, data})
    {:ok, "queued by test SMTP", state}
  end

  @impl true
  def handle_RSET(state), do: state
  @impl true
  def handle_VRFY(_, state), do: {:error, "252 VRFY disabled", state}
  @impl true
  def handle_other(_, _, state), do: {"500 Unsupported", state}
  @impl true
  def handle_AUTH(_, _, _, _), do: :error
  @impl true
  def handle_STARTTLS(state), do: state
  @impl true
  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def handle_error(_, _, state), do: {:ok, state}
  @impl true
  def code_change(_, state, _), do: {:ok, state}
  @impl true
  def terminate(reason, state), do: {:ok, reason, state}
end
