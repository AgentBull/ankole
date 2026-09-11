defmodule Ankole.Plugins.EmailAdapterTest.FakeImap do
  @moduledoc false

  # A scripted IMAP server on a loopback TCP socket. It keeps a mailbox of
  # `uid => raw` messages, marks `\Seen` on STORE, reports every command line
  # to the test process, and pushes `* n EXISTS` while the client idles.

  def start(opts) do
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: true, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    state = %{
      parent: parent,
      messages: Keyword.get(opts, :messages, %{}),
      seen: MapSet.new(),
      password: Keyword.get(opts, :password, "secret"),
      capabilities: Keyword.get(opts, :capabilities, ["IMAP4rev1", "IDLE"]),
      uidvalidity: Keyword.get(opts, :uidvalidity, 7),
      socket: nil,
      idle_tag: nil,
      pending_exists: false,
      literal_size: Keyword.get(opts, :literal_size)
    }

    pid = spawn_link(fn -> accept_loop(listener, state) end)
    {:ok, port, pid}
  end

  def add_message(pid, uid, raw), do: send(pid, {:add_message, uid, raw})

  defp accept_loop(listener, state) do
    {:ok, socket} = :gen_tcp.accept(listener)
    :ok = :gen_tcp.send(socket, "* OK fake IMAP ready\r\n")
    state = serve(%{state | socket: socket, idle_tag: nil})
    accept_loop(listener, state)
  end

  defp serve(state) do
    receive do
      {:tcp, socket, line} when socket == state.socket ->
        send(state.parent, {:imap_command, String.trim(line)})

        case handle(String.trim(line), state) do
          {:continue, state} -> serve(state)
          {:close, state} -> :gen_tcp.close(socket) && state
        end

      {:tcp_closed, socket} when socket == state.socket ->
        state

      {:add_message, uid, raw} ->
        state = %{state | messages: Map.put(state.messages, uid, raw)}

        # A real server reports the new message with the next command; the
        # IDLE handler replays it when no IDLE was open at arrival.
        if state.idle_tag do
          :ok = :gen_tcp.send(state.socket, "* #{map_size(state.messages)} EXISTS\r\n")
          serve(state)
        else
          serve(%{state | pending_exists: true})
        end
    end
  end

  defp handle("DONE", %{idle_tag: tag} = state) when is_binary(tag) do
    reply(state, "#{tag} OK IDLE terminated")
    {:continue, %{state | idle_tag: nil}}
  end

  defp handle(line, state) do
    [tag, verb | rest] = String.split(line, " ", parts: 3)
    args = List.first(rest) || ""

    case String.upcase(verb) do
      "CAPABILITY" ->
        reply(state, "* CAPABILITY #{Enum.join(state.capabilities, " ")}")
        reply(state, "#{tag} OK CAPABILITY completed")
        {:continue, state}

      "LOGIN" ->
        if String.ends_with?(args, "\"#{state.password}\"") do
          reply(state, "#{tag} OK LOGIN completed")
        else
          reply(state, "#{tag} NO [AUTHENTICATIONFAILED] Invalid credentials")
        end

        {:continue, state}

      "SELECT" ->
        reply(state, "* #{map_size(state.messages)} EXISTS")
        reply(state, "* OK [UIDVALIDITY #{state.uidvalidity}] UIDs valid")
        reply(state, "#{tag} OK [READ-WRITE] SELECT completed")
        {:continue, state}

      "UID" ->
        handle_uid(tag, args, state)

      "IDLE" ->
        reply(state, "+ idling")
        if state.pending_exists, do: reply(state, "* #{map_size(state.messages)} EXISTS")
        {:continue, %{state | idle_tag: tag, pending_exists: false}}

      "NOOP" ->
        reply(state, "#{tag} OK NOOP completed")
        {:continue, state}

      "LOGOUT" ->
        reply(state, "* BYE")
        reply(state, "#{tag} OK LOGOUT completed")
        {:close, state}

      _other ->
        reply(state, "#{tag} BAD unsupported")
        {:continue, state}
    end
  end

  defp handle_uid(tag, "SEARCH UNSEEN", state) do
    unseen =
      state.messages
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(state.seen, &1))
      |> Enum.sort()

    reply(state, String.trim("* SEARCH #{Enum.join(unseen, " ")}"))
    reply(state, "#{tag} OK SEARCH completed")
    {:continue, state}
  end

  defp handle_uid(tag, "FETCH " <> rest, state) do
    [uid, items] = String.split(rest, " ", parts: 2)
    uid = String.to_integer(uid)
    raw = Map.fetch!(state.messages, uid)

    cond do
      items == "(RFC822.SIZE)" ->
        reply(state, "* #{uid} FETCH (UID #{uid} RFC822.SIZE #{byte_size(raw)})")

      items == "(BODY.PEEK[HEADER])" ->
        [headers, _body] = String.split(raw, "\r\n\r\n", parts: 2)
        headers = headers <> "\r\n\r\n"

        :ok =
          :gen_tcp.send(
            state.socket,
            "* #{uid} FETCH (UID #{uid} BODY[HEADER] {#{byte_size(headers)}}\r\n"
          )

        :ok = :gen_tcp.send(state.socket, headers <> ")\r\n")

      true ->
        :ok =
          :gen_tcp.send(
            state.socket,
            "* #{uid} FETCH (UID #{uid} BODY[] {#{state.literal_size || byte_size(raw)}}\r\n"
          )

        :ok = :gen_tcp.send(state.socket, raw <> ")\r\n")
    end

    reply(state, "#{tag} OK FETCH completed")
    {:continue, state}
  end

  defp handle_uid(tag, "STORE " <> rest, state) do
    [uid | _flags] = String.split(rest, " ")
    reply(state, "#{tag} OK STORE completed")
    {:continue, %{state | seen: MapSet.put(state.seen, String.to_integer(uid))}}
  end

  defp reply(state, line), do: :ok = :gen_tcp.send(state.socket, line <> "\r\n")
end

defmodule Ankole.Plugins.EmailAdapterTest.FakeSmtp do
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

defmodule Ankole.Plugins.EmailAdapterTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.Eventually, only: [eventually: 1]

  alias Ankole.Plugins.EmailAdapter
  alias Ankole.Plugins.EmailAdapterTest.{FakeImap, FakeSmtp}

  alias Ankole.Plugins.EmailAdapter.{
    Authentication,
    Config,
    ConnectionOwner,
    ConnectionSupervisor,
    ErrorPolicy,
    Inbound,
    MailboxSession,
    Message,
    Mime,
    Outbox,
    ReplyText
  }

  alias Ankole.Plugins.EmailAdapter.Imap.Client
  alias Ankole.Principals
  alias Ankole.Principals.MappingRequests
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{AdapterContext, Channel, Entry, OutboxEntry}

  @mailbox "agent@corp.example"

  setup do
    previous = Application.get_env(:ankole, Config)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:ankole, Config),
        else: Application.put_env(:ankole, Config, previous)
    end)

    :ok
  end

  describe "plugin and catalog contract" do
    test "declares one consumer IM adapter with only the capabilities email has" do
      assert EmailAdapter.plugin_id() == "email-adapter"
      assert [declaration] = EmailAdapter.adapter_declarations()
      assert declaration.id == "email"
      assert declaration.adapter_category == "email"
      assert declaration.inbound_capabilities == ["entry_receive"]
      assert declaration.outbound_capabilities == ["post_entry", "reply_entry"]
      refute Map.has_key?(declaration, :reply_preview_module)
      assert :ok = Ankole.SignalsGateway.Adapters.validate_declaration(declaration)

      assert [%{path: "password"}] = Enum.filter(declaration.fields, & &1.encrypted)
      assert Enum.all?(EmailAdapter.app_config_patterns(), & &1.encrypted)
    end

    test "validates settings, applies defaults, and keeps credentials out of inspection" do
      assert {:ok, config} = Config.validate_binding_config(binding_config())
      assert config["address"] == @mailbox
      assert config["imapPort"] == 993
      assert config["smtpPort"] == 587
      assert config["smtpSecurity"] == "starttls"
      assert config["senderAuthentication"] == "dmarc"

      assert {:error, {:invalid_email_address, "address"}} =
               Config.validate_binding_config(Map.put(binding_config(), "address", "not-mail"))

      assert {:error, {:invalid_credential, "password"}} =
               Config.validate_binding_config(Map.put(binding_config(), "password", "密码"))

      assert {:error, {:invalid_choice, "smtpSecurity"}} =
               Config.validate_binding_config(Map.put(binding_config(), "smtpSecurity", "plain"))

      runtime = Config.runtime(config)
      refute inspect(runtime) =~ "secret"
      assert inspect(runtime) =~ "[REDACTED]"
      assert runtime.sender_authentication == :dmarc
    end

    test "one mailbox can belong to only one enabled binding" do
      %{principal: first} = agent_fixture()
      %{principal: second} = agent_fixture()

      assert {:ok, %{binding: binding}} =
               SignalsGateway.put_binding(first.uid, "email", "mail", %{
                 "config" => binding_config()
               })

      assert binding.config_ref =~ ~r/signals_gateway\.email\.bindings\.[a-f0-9]{64}\z/

      assert {:error, {:email_mailbox_already_bound, _agent, "mail"}} =
               SignalsGateway.put_binding(second.uid, "email", "other", %{
                 "config" => binding_config()
               })

      assert {:ok, _binding} =
               SignalsGateway.put_binding(second.uid, "email", "other", %{
                 "config" => Map.put(binding_config(), "username", "other-user")
               })

      %{principal: third} = agent_fixture()

      assert {:error, {:email_mailbox_already_bound, _agent, "mail"}} =
               SignalsGateway.put_binding(third.uid, "email", "cased", %{
                 "config" => Map.put(binding_config(), "username", "AGENT")
               })
    end
  end

  describe "message decoding" do
    test "decodes nested MIME, GB2312 text, encoded headers, and RFC 2231 file names" do
      message = Message.decode(sample_multipart_mail())

      assert message.message_id == "abc123@example.com"
      assert message.in_reply_to == ["root@corp.example"]
      assert message.references == ["root@corp.example", "mid@corp.example"]
      assert message.from == %{address: "ada@example.com", name: "张三"}
      assert Enum.map(message.to, & &1.address) == [@mailbox, "bob@example.org"]
      assert message.subject == "Re: 回复： budget"
      assert message.text =~ "你好，请看附件。"
      assert message.text =~ "> earlier text"
      assert message.date == ~U[2026-09-11 06:41:42Z]

      assert [%{index: 1, name: "报告.pdf", mime_type: "application/pdf", body: "%PDF-1.4\n"}] =
               message.attachments

      assert :ok = Authentication.verify(:dmarc, message.authentication_results, "example.com")
    end

    test "falls back to HTML text, records unsupported charsets, and flags bulk mail" do
      html_only =
        raw_mail(
          extra_headers: ["Content-Type: text/html; charset=utf-8"],
          body: "<p>Hello &amp; <a href=\"https://x.test/y\">docs</a></p><br><div>Bye</div>"
        )

      assert %Message{text: "Hello & docs (https://x.test/y)\n\nBye"} = Message.decode(html_only)

      shift_jis =
        raw_mail(
          extra_headers: ["Content-Type: text/plain; charset=shift_jis"],
          body: "ascii only " <> <<0x82, 0xA0>>
        )

      assert %Message{text: "ascii only", unsupported_charsets: ["shift_jis"]} =
               Message.decode(shift_jis)

      assert %Message{auto_submitted: true} =
               Message.decode(raw_mail(extra_headers: ["Auto-Submitted: auto-replied"]))

      assert %Message{auto_submitted: true} =
               Message.decode(raw_mail(extra_headers: ["List-Id: <list.example.org>"]))

      assert %Message{auto_submitted: false} =
               Message.decode(raw_mail(extra_headers: ["Auto-Submitted: no"]))
    end

    test "parses address structure before decoding display names" do
      injected = Base.encode64("Victim <victim@gmail.com>,")

      raw =
        "From: =?UTF-8?B?#{injected}?= <attacker@gmail.com>\r\nTo: =?UTF-8?Q?Victim_<victim@gmail.com>,?= <agent@corp.example>\r\nSubject: hi\r\n\r\nbody"

      message = Message.decode(raw)
      assert message.from == %{address: "attacker@gmail.com", name: "Victim <victim@gmail.com>,"}
      assert Enum.map(message.to, & &1.address) == ["agent@corp.example"]

      assert %Message{from: %{address: "zhang@example.cn", name: "张三 李四"}} =
               Message.decode(
                 "From: =?UTF-8?B?5byg5LiJ?= =?UTF-8?B?IOadjuWbmw==?= <zhang@example.cn>\r\n\r\nx"
               )
    end

    test "prefers extended MIME parameters and joins only numbered segments" do
      assert {"attachment", %{"filename" => "报告.pdf"}} =
               Mime.parse_disposition(
                 "attachment; filename=report.pdf; filename*=UTF-8''%E6%8A%A5%E5%91%8A.pdf"
               )

      assert {"attachment", %{"filename" => "报告.pdf"}} =
               Mime.parse_disposition(
                 "attachment; filename=report.pdf; filename*0*=UTF-8''%E6%8A%A5; filename*1*=%E5%91%8A.pdf"
               )

      assert {"attachment", %{"filename" => "report.pdf"}} =
               Mime.parse_disposition("attachment; filename=report.pdf")
    end

    test "decodes mixed RFC 2231 segments one by one" do
      assert {"attachment", %{"filename" => "report%20Q3.pdf"}} =
               Mime.parse_disposition(
                 ~s(attachment; filename*0*=UTF-8''report; filename*1="%20Q3.pdf")
               )

      assert {"attachment", %{"filename" => "报告 Q3.pdf"}} =
               Mime.parse_disposition(
                 ~s(attachment; filename*0*=UTF-8''%E6%8A%A5%E5%91%8A; filename*1=" Q3"; filename*2*=%2Epdf)
               )
    end

    test "keeps a forward that starts with its marker, including quoted lines inside it" do
      body =
        "---------- Forwarded message ---------\nFrom: ops <ops@example.org>\nDate: Thu\n\n故障详情\n> 用户报告\n> 无法登录"

      assert {^body, false} = ReplyText.strip_quoted(body)
    end

    test "refuses a multi-mailbox From, survives odd parameters, and keeps literal mask text" do
      assert %Message{from: nil} = Message.decode("From: a@x.test, b@y.test\r\n\r\nx")

      assert {"attachment", %{"filename" => "a.pdf"}} =
               Mime.parse_disposition("attachment; x*y=1; filename=a.pdf")

      assert %Message{from: %{name: "EW__1__ literal 张三", address: "z@example.cn"}} =
               Message.decode(
                 "From: EW__1__ literal =?UTF-8?B?5byg5LiJ?= <z@example.cn>\r\n\r\nx"
               )
    end

    test "strips quoted replies below common separators" do
      assert {"Yes, go ahead.", true} =
               ReplyText.strip_quoted(
                 "Yes, go ahead.\n\n在 2026年9月10日，Agent <agent@corp.example> 写道：\n> question"
               )

      assert {"Yes, go ahead.", true} =
               ReplyText.strip_quoted(
                 "Yes, go ahead.\n\nFrom: Agent\nSent: Thursday\nTo: Ada\nSubject: x\n\nold"
               )

      assert {"Only text", false} = ReplyText.strip_quoted("Only text")
    end

    test "verifies DMARC results from the first Authentication-Results header" do
      assert {:error, :authentication_results_missing} =
               Authentication.verify(:dmarc, [], "example.com")

      assert {:error, :dmarc_not_passed} =
               Authentication.verify(
                 :dmarc,
                 ["mx.test; spf=pass smtp.mailfrom=a.test; dmarc=fail header.from=a.test"],
                 "a.test"
               )

      assert {:error, :dmarc_domain_mismatch} =
               Authentication.verify(
                 :dmarc,
                 ["mx.test; dmarc=pass header.from=other.test"],
                 "a.test"
               )

      assert {:error, :dmarc_domain_mismatch} =
               Authentication.verify(
                 :dmarc,
                 ["mx.test; dmarc=pass header.from=a.test"],
                 "sub.a.test"
               )

      assert {:error, :dmarc_domain_missing} =
               Authentication.verify(:dmarc, ["mx.test; dmarc=pass"], "a.test")

      assert :ok =
               Authentication.verify(
                 :dmarc,
                 [
                   "spf=pass (sender IP is 1.2.3.4) smtp.mailfrom=a.test; dkim=pass header.d=a.test;dmarc=pass action=none header.from=a.test;compauth=pass reason=100"
                 ],
                 "a.test"
               )

      assert :ok = Authentication.verify(:none, [], "a.test")
    end
  end

  describe "inbound projection" do
    test "admits an authenticated sender, names the thread, and joins replies to it" do
      %{principal: agent} = agent_fixture()
      consumer = bound_consumer(agent.uid, "mail", "create_standalone")

      first =
        raw_mail(
          message_id: "first@example.com",
          subject: "Budget review",
          body: "Please review."
        )

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", event(1, first), [consumer])

      channel_id = Inbound.signal_channel_id(@mailbox, "first@example.com")

      assert %Channel{kind: :im_dm, name: "Budget review", reply_mode: :entry} =
               channel = Repo.get(Channel, channel_id)

      assert channel.metadata["participants"] == ["ada@example.com"]

      assert %Entry{} =
               entry =
               Repo.get_by(Entry,
                 signal_channel_id: channel_id,
                 source_entry_id: "first@example.com"
               )

      assert entry.text == "Please review."
      assert entry.metadata["subject"] == "Budget review"
      assert entry.author["platform_subject"] == "ada@example.com"
      refute Map.has_key?(entry.author, "email")
      assert entry.raw_payload["from"] == %{"address" => "ada@example.com", "name" => "Ada"}
      assert {:ok, principal} = Principals.resolve_platform_subject("email", "ada@example.com")
      assert principal.type == :human

      reply =
        raw_mail(
          message_id: "second@example.com",
          in_reply_to: "first@example.com",
          references: ["first@example.com"],
          subject: "Re: Budget review",
          cc: ["Bob <bob@example.org>"],
          body: "Adding Bob."
        )

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", event(2, reply), [consumer])

      assert %Entry{signal_channel_id: ^channel_id, reply_to_source_entry_id: "first@example.com"} =
               Repo.get_by(Entry, source_entry_id: "second@example.com")

      assert %Channel{kind: :im_group, name: "Budget review"} =
               channel = Repo.get(Channel, channel_id)

      assert channel.metadata["participants"] == ["ada@example.com", "bob@example.org"]

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", event(2, reply), [consumer])

      assert Repo.aggregate(Entry, :count) == 2
    end

    test "strips quoted history only after the thread is mirrored" do
      %{principal: agent} = agent_fixture()
      consumer = bound_consumer(agent.uid, "mail", "create_standalone")

      quoted = "请分析下面的问题\n\nOn Thu, Sep 10, 2026 Bob <bob@example.org> wrote:\n> 生产故障详情"

      first_join =
        raw_mail(
          message_id: "join@example.com",
          in_reply_to: "unseen@example.org",
          references: ["unseen@example.org"],
          body: quoted
        )

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", event(1, first_join), [consumer])

      assert %Entry{text: ^quoted, metadata: metadata} =
               Repo.get_by(Entry, source_entry_id: "join@example.com")

      refute Map.has_key?(metadata, "quoted_text_removed")

      followup =
        raw_mail(
          message_id: "follow@example.com",
          in_reply_to: "join@example.com",
          body: "收到\n\nOn Fri, Sep 11, 2026 Ada <ada@example.com> wrote:\n> 请分析下面的问题"
        )

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", event(2, followup), [consumer])

      assert %Entry{text: "收到", metadata: %{"quoted_text_removed" => true}} =
               Repo.get_by(Entry, source_entry_id: "follow@example.com")

      forwarded_body =
        "请调查下面的问题\n\n---------- Forwarded message ---------\nFrom: ops <ops@example.org>\nDate: Thu, Sep 10, 2026\nSubject: incident\nTo: ada@example.com\n\n生产故障详情"

      forwarded =
        raw_mail(
          message_id: "fwd@example.com",
          in_reply_to: "join@example.com",
          body: forwarded_body
        )

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", event(3, forwarded), [consumer])

      assert %Entry{text: ^forwarded_body} =
               Repo.get_by(Entry, source_entry_id: "fwd@example.com")

      outlook_body =
        "请调查\n\n________________________________\nFrom: ops <ops@example.org>\nSent: Thursday\nTo: ada@example.com\nSubject: incident\n\n生产故障详情"

      outlook =
        raw_mail(
          message_id: "fw@example.com",
          in_reply_to: "join@example.com",
          subject: "FW: incident",
          body: outlook_body
        )

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", event(4, outlook), [consumer])

      assert %Entry{text: ^outlook_body} = Repo.get_by(Entry, source_entry_id: "fw@example.com")
    end

    test "keeps a leading control command recognizable" do
      %{principal: agent} = agent_fixture()
      consumer = bound_consumer(agent.uid, "mail", "create_standalone")

      assert {:ok, input, _bytes} =
               Inbound.normalize_message_receive(
                 event(1, raw_mail(subject: "Re: Work", body: "/stop")),
                 consumer
               )

      assert input.text == "/stop"
      assert {:ok, %{"name" => "stop"}} = Ankole.SignalsGateway.Commands.classify(input.text)
    end

    test "keeps a Cc-only message implicit and ignores own, bulk, and unauthenticated mail" do
      %{principal: agent} = agent_fixture()
      consumer = bound_consumer(agent.uid, "mail", "create_standalone")

      cc_only =
        raw_mail(
          message_id: "cc@example.com",
          to: ["Bob <bob@example.org>"],
          cc: ["Agent <#{@mailbox}>"]
        )

      assert {:ok, input, _bytes} = Inbound.normalize_message_receive(event(3, cc_only), consumer)
      refute input.explicit
      assert input.channel.kind == :im_group

      assert {:ok, [%{status: :ignored, reason: :own_message}]} =
               Inbound.handle_message_receive(
                 "message",
                 event(4, raw_mail(from: "Agent <#{@mailbox}>")),
                 [consumer]
               )

      assert {:ok, [%{status: :ignored, reason: :auto_submitted}]} =
               Inbound.handle_message_receive(
                 "message",
                 event(5, raw_mail(extra_headers: ["Precedence: bulk"])),
                 [consumer]
               )

      assert {:ok, [%{status: :ignored, reason: {:unauthenticated_sender, :dmarc_not_passed}}]} =
               Inbound.handle_message_receive(
                 "message",
                 event(
                   6,
                   raw_mail(authentication: "mx.test; dmarc=fail header.from=example.com")
                 ),
                 [consumer]
               )

      assert {:ok, [%{status: :ignored, reason: :missing_sender}]} =
               Inbound.handle_message_receive("message", event(7, "\r\nnot even headers"), [
                 consumer
               ])

      assert Repo.aggregate(Entry, :count) == 0
    end

    test "manual review holds an unknown sender with a reply notice and admits a known email" do
      %{principal: agent} = agent_fixture()
      consumer = bound_consumer(agent.uid, "mail", "manual_review")

      assert {:ok, [%{status: :held_unmapped_sender}]} =
               Inbound.handle_message_receive(
                 "message",
                 event(1, raw_mail(message_id: "held@example.com")),
                 [consumer]
               )

      assert [request] = MappingRequests.list_requests()
      assert request.provider == "email"
      assert request.external_id == "ada@example.com"
      assert is_nil(request.email)
      assert Repo.aggregate(Entry, :count) == 0

      assert %OutboxEntry{
               operation: :reply,
               reply_to_source_entry_id: "held@example.com",
               fallback_visible_text: notice
             } =
               Repo.one!(OutboxEntry)

      assert notice == Ankole.I18n.t("signals_gateway.reply.unmapped_sender")

      notice_row = Repo.one!(OutboxEntry)

      assert notice_row.payload["metadata"]["unmatched_sender"]["platform_subject"] ==
               "ada@example.com"

      drifted = Repo.get!(Channel, notice_row.signal_channel_id)

      {:ok, _channel} =
        drifted
        |> Ecto.Changeset.change(
          metadata: Map.put(drifted.metadata, "participants", ["bob@example.org"])
        )
        |> Repo.update()

      assert {:ok, notice_email} = Outbox.build(notice_row, Config.runtime(validated_config()))
      assert notice_email.recipients == ["ada@example.com"]
      assert notice_email.headers["In-Reply-To"] == "<held@example.com>"
      assert notice_email.headers["References"] == "<held@example.com>"
      assert notice_email.headers["Subject"] == "Re: Hello"

      %{principal: human} = human_fixture(%{email: "carol@example.com"})

      assert {:ok, [%{status: :held_unmapped_sender}]} =
               Inbound.handle_message_receive(
                 "message",
                 event(
                   2,
                   raw_mail(message_id: "typed@example.com", from: "Carol <Carol@Example.com>")
                 ),
                 [consumer]
               )

      assert {:ok, _identity} =
               MappingRequests.bind_subject(human.uid, %{
                 provider: "email",
                 external_id: "carol@example.com"
               })

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 event(
                   3,
                   raw_mail(message_id: "known@example.com", from: "Carol <Carol@Example.com>")
                 ),
                 [consumer]
               )

      assert {:ok, matched} = Principals.resolve_platform_subject("email", "carol@example.com")
      assert matched.uid == human.uid
    end

    test "holds a sender whose address is a local account's UID under either policy" do
      %{principal: agent} = agent_fixture()

      assert {:ok, %{principal: local}} =
               Principals.create_local_user(
                 %{uid: "owner@corp.example", email: "owner@corp.example"},
                 false
               )

      standalone = bound_consumer(agent.uid, "mail", "create_standalone")

      assert {:ok, [%{status: :held_unmapped_sender}]} =
               Inbound.handle_message_receive(
                 "message",
                 event(
                   1,
                   raw_mail(message_id: "owner1@corp.example", from: "Owner <owner@corp.example>")
                 ),
                 [standalone]
               )

      assert [request] = MappingRequests.list_requests()
      assert request.external_id == "owner@corp.example"

      assert {:error, :not_found} =
               Principals.resolve_platform_subject("email", "owner@corp.example")

      assert Repo.aggregate(Entry, :count) == 0

      assert {:ok, _identity} = MappingRequests.bind_request(request.id, local.uid)

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 event(
                   2,
                   raw_mail(message_id: "owner2@corp.example", from: "Owner <owner@corp.example>")
                 ),
                 [standalone]
               )

      assert %Entry{author: %{"principal_uid" => uid}} =
               Repo.get_by(Entry, source_entry_id: "owner2@corp.example")

      assert uid == local.uid
    end

    test "keeps a message over the size limit as headers only" do
      %{principal: agent} = agent_fixture()
      consumer = bound_consumer(agent.uid, "mail", "create_standalone")
      raw = raw_mail(message_id: "big@example.com", subject: "Huge", body: "ignored")
      [headers, _body] = String.split(raw, "\r\n\r\n", parts: 2)

      event = %{
        "uid" => 9,
        "uidvalidity" => 7,
        "raw" => headers <> "\r\n\r\n",
        "size" => 30_000_000,
        "headers_only" => true
      }

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", event, [consumer])

      assert %Entry{
               text: text,
               metadata: %{"size_limit_exceeded" => true, "subject" => "Huge"},
               attachments: []
             } =
               Repo.get_by(Entry, source_entry_id: "big@example.com")

      assert text =~ "exceeds the 25 MB limit"

      assert %Channel{name: "Huge"} =
               Repo.get(Channel, Inbound.signal_channel_id(@mailbox, "big@example.com"))
    end
  end

  describe "mailbox session" do
    test "confirms a message only after ingress accepts it and keeps it unseen after a failure" do
      raw = raw_mail(message_id: "session@example.com")
      {:ok, port, _server} = FakeImap.start(messages: %{1 => raw})

      Application.put_env(:ankole, Config,
        imap_opts: [transport: :tcp, host: "127.0.0.1", port: port]
      )

      runtime = Config.runtime(validated_config())

      {:ok, client} = Client.connect(Config.imap_options(runtime))
      {:ok, client} = Client.login(client, runtime.username, runtime.password)
      {:ok, client, %{uidvalidity: 7}} = Client.select(client, "INBOX")
      assert Client.supports?(client, "IDLE")

      assert {:error, :database_unavailable} =
               MailboxSession.sync(client, 7, fn _event -> {:error, :database_unavailable} end)

      refute received_store?(1)

      parent = self()

      assert {:ok, client, 1} =
               MailboxSession.sync(client, 7, fn event ->
                 send(parent, {:handled, event})
                 {:ok, %{status: :accepted}}
               end)

      assert_received {:handled,
                       %{"uid" => 1, "uidvalidity" => 7, "raw" => ^raw, "headers_only" => false}}

      assert received_store?(1)

      assert {:ok, client, 0} =
               MailboxSession.sync(client, 7, fn _event -> flunk("seen mail must not repeat") end)

      assert {:ok, client, :timeout} = Client.idle(client, 100)
      assert :ok = Client.logout(client)
    end

    test "refuses a literal larger than the client limit before reading it" do
      raw = raw_mail(message_id: "huge@example.com")
      {:ok, port, _server} = FakeImap.start(messages: %{1 => raw}, literal_size: 99_999_999_999)

      Application.put_env(:ankole, Config,
        imap_opts: [transport: :tcp, host: "127.0.0.1", port: port]
      )

      runtime = Config.runtime(validated_config())

      {:ok, client} = Client.connect(Config.imap_options(runtime))
      {:ok, client} = Client.login(client, runtime.username, runtime.password)
      {:ok, client, _mailbox} = Client.select(client, "INBOX")

      assert {:error, {:literal_too_large, 99_999_999_999}} =
               Client.uid_fetch_body(client, 1, :full)

      assert :ok = Client.close(client)
    end

    test "runs a supervised owner that blocks on a bad password and restarts on a changed password" do
      %{principal: agent} = agent_fixture()
      raw = raw_mail(message_id: "owner@example.com", subject: "Owner test")
      {:ok, port, server} = FakeImap.start(messages: %{}, password: "rotated")

      Application.put_env(:ankole, Config,
        imap_opts: [transport: :tcp, host: "127.0.0.1", port: port]
      )

      consumer = bound_consumer(agent.uid, "mail", "create_standalone")
      key = {agent.uid, "mail"}

      assert {:ok, blocked} = ConnectionSupervisor.ensure_started(validated_config(), [consumer])
      assert eventually(fn -> ConnectionOwner.status(blocked).state == :blocked end)
      assert %{blocked_reason: :authentication_failed} = ConnectionOwner.status(blocked)
      refute inspect(ConnectionOwner.status(blocked)) =~ "secret"

      rotated = Map.put(validated_config(), "password", "rotated")

      assert {:ok, running} =
               ConnectionSupervisor.ensure_started(rotated, [
                 Inbound.chat_consumer(consumer.context, rotated)
               ])

      refute running == blocked
      assert eventually(fn -> ConnectionOwner.status(running).state == :running end)
      assert %{uidvalidity: 7, idle?: true, address: @mailbox} = ConnectionOwner.status(running)

      FakeImap.add_message(server, 1, raw)
      assert eventually(fn -> Repo.get_by(Entry, source_entry_id: "owner@example.com") != nil end)
      assert eventually(fn -> received_store?(1) end)

      assert :ok = ConnectionSupervisor.stop(key)
      assert eventually(fn -> ConnectionSupervisor.registered_keys() == [] end)
    end
  end

  describe "outbound delivery" do
    test "builds a threaded reply with a deterministic Message-ID and sends it over SMTP" do
      %{principal: agent} = agent_fixture()
      consumer = bound_consumer(agent.uid, "mail", "create_standalone")

      inbound =
        raw_mail(
          message_id: "q@example.com",
          references: ["root@example.com"],
          subject: "Budget review",
          cc: ["Bob <bob@example.org>", "Agent <#{@mailbox}>"],
          extra_headers: ["Reply-To: ada.replies@example.com"]
        )

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", event(1, inbound), [consumer])

      channel_id = Inbound.signal_channel_id(@mailbox, "q@example.com")

      outbox = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "mail",
        outbound_key: "reply-1",
        operation: :reply,
        signal_channel_id: channel_id,
        reply_to_source_entry_id: "q@example.com",
        payload: %{},
        fallback_visible_text: "Looks good.\n\n谢谢"
      }

      runtime = Config.runtime(validated_config())
      assert {:ok, email} = Outbox.build(outbox, runtime)
      assert email.recipients == ["ada.replies@example.com", "bob@example.org"]
      assert email.headers["Subject"] == "Re: Budget review"
      assert email.headers["In-Reply-To"] == "<q@example.com>"
      assert email.headers["References"] == "<root@example.com> <q@example.com>"
      assert email.message_id =~ ~r/\Aank-[a-f0-9]{40}@corp\.example\z/
      assert Outbox.message_id(outbox, runtime) == email.message_id
      assert email.headers["From"] == "Ankole Agent <#{@mailbox}>"

      port = start_fake_smtp()

      Application.put_env(:ankole, Config,
        smtp_opts: [relay: ~c"127.0.0.1", port: port, tls: :never, ssl: false, tls_options: []]
      )

      assert {:ok,
              %{
                created_source_entry_id: created,
                provider_thread_id: ^channel_id,
                raw_payload: raw_payload
              }} =
               Outbox.send(outbox)

      assert created == email.message_id
      assert raw_payload["to"] == Enum.map(email.recipients, &%{"address" => &1})

      assert_receive {:smtp_data, @mailbox, recipients, data}, 5_000
      assert Enum.sort(recipients) == Enum.sort(email.recipients)
      sent = Message.decode(data)
      assert sent.message_id == email.message_id
      assert sent.text == "Looks good.\n\n谢谢"
      assert sent.in_reply_to == ["q@example.com"]

      assert {:ok, %OutboxEntry{status: :succeeded}} = commit_and_dispatch(outbox)

      assert %Entry{author: %{"agent_uid" => _agent}} =
               mirror = Repo.get_by(Entry, source_entry_id: email.message_id)

      assert mirror.raw_payload["message_id"] == email.message_id

      human_reply =
        raw_mail(
          message_id: "r@example.com",
          in_reply_to: email.message_id,
          subject: "Re: Budget review",
          body: "Thanks!"
        )

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive("message", event(2, human_reply), [consumer])

      assert %Entry{signal_channel_id: ^channel_id} =
               Repo.get_by(Entry, source_entry_id: "r@example.com")
    end

    test "verifies the server certificate on an implicit TLS submission" do
      %{principal: agent} = agent_fixture()
      consumer = bound_consumer(agent.uid, "mail", "create_standalone")

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 event(1, raw_mail(message_id: "tls@example.com")),
                 [consumer]
               )

      outbox = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "mail",
        outbound_key: "reply-tls",
        operation: :reply,
        signal_channel_id: Inbound.signal_channel_id(@mailbox, "tls@example.com"),
        reply_to_source_entry_id: "tls@example.com",
        payload: %{},
        fallback_visible_text: "over tls"
      }

      runtime = Config.runtime(Map.put(validated_config(), "smtpSecurity", "tls"))

      assert [ssl: true, tls: :never, sockopts: sockopts] =
               Keyword.take(Config.smtp_options(runtime), [:ssl, :tls, :sockopts])

      assert sockopts[:verify] == :verify_peer
      refute Keyword.has_key?(Config.smtp_options(runtime), :tls_options)

      assert [tls: :always, tls_options: tls_options] =
               Keyword.take(Config.smtp_options(Config.runtime(validated_config())), [
                 :tls,
                 :tls_options
               ])

      assert tls_options[:verify] == :verify_peer

      {port, cacerts} = start_fake_tls_smtp()
      trusted = Config.tls_options(~c"localhost") |> Keyword.put(:cacerts, cacerts)

      Application.put_env(:ankole, Config,
        smtp_opts: [relay: ~c"127.0.0.1", port: port, ssl: true, tls: :never, sockopts: trusted]
      )

      assert {:ok, %{created_source_entry_id: _created}} = Outbox.send(outbox)
      assert_receive {:smtp_data, @mailbox, ["ada@example.com"], _data}, 5_000

      Application.put_env(:ankole, Config,
        smtp_opts: [
          relay: ~c"127.0.0.1",
          port: port,
          ssl: true,
          tls: :never,
          sockopts: Config.tls_options(~c"localhost")
        ]
      )

      assert {:error,
              {:reply_delivery, :operator_action_required,
               %{"code" => "smtp_session_failed", "failure" => failure}}} =
               Outbox.send(outbox)

      assert failure =~ "tls_alert"
    end

    test "refuses declared oversize attachments before reading any file" do
      %{principal: agent} = agent_fixture()
      consumer = bound_consumer(agent.uid, "mail", "create_standalone")

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 event(1, raw_mail(message_id: "big-att@example.com")),
                 [
                   consumer
                 ]
               )

      outbox = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "mail",
        outbound_key: "reply-big",
        operation: :reply,
        signal_channel_id: Inbound.signal_channel_id(@mailbox, "big-att@example.com"),
        reply_to_source_entry_id: "big-att@example.com",
        payload: %{
          "attachments" => [
            %{
              "name" => "big.bin",
              "user_files_relative_path" => "out/big.bin",
              "size" => 30_000_000
            }
          ]
        },
        fallback_visible_text: "see attachment"
      }

      assert {:error, {:reply_delivery, :permanent, %{"code" => "email_attachments_too_large"}}} =
               Outbox.send(outbox)
    end

    test "classifies SMTP failures for the outbox" do
      %{principal: agent} = agent_fixture()
      consumer = bound_consumer(agent.uid, "mail", "create_standalone")

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "message",
                 event(
                   1,
                   raw_mail(message_id: "f@example.com", from: "Nobody <nobody@example.org>")
                 ),
                 [
                   consumer
                 ]
               )

      outbox = %OutboxEntry{
        agent_uid: agent.uid,
        binding_name: "mail",
        outbound_key: "reply-2",
        operation: :reply,
        signal_channel_id: Inbound.signal_channel_id(@mailbox, "f@example.com"),
        reply_to_source_entry_id: "f@example.com",
        payload: %{},
        fallback_visible_text: "hello"
      }

      port = start_fake_smtp()
      smtp_opts = [relay: ~c"127.0.0.1", port: port, tls: :never, ssl: false, tls_options: []]

      Application.put_env(:ankole, Config, smtp_opts: smtp_opts)

      assert {:error,
              {:reply_delivery, :permanent,
               %{"code" => "smtp_delivery_failed", "failure" => failure}}} =
               Outbox.send(outbox)

      assert failure =~ "550"

      Application.put_env(:ankole, Config,
        smtp_opts: Keyword.put(smtp_opts, :password, ~c"wrong")
      )

      assert {:error,
              {:reply_delivery, :operator_action_required, %{"code" => "smtp_session_failed"}}} =
               Outbox.send(outbox)

      {:ok, closed} = :gen_tcp.listen(0, [:binary])
      {:ok, closed_port} = :inet.port(closed)
      :gen_tcp.close(closed)
      Application.put_env(:ankole, Config, smtp_opts: Keyword.put(smtp_opts, :port, closed_port))

      assert {:error, {:reply_delivery, :retryable, %{"code" => "smtp_session_failed"}}} =
               Outbox.send(outbox)

      assert {:error, {:reply_delivery, :permanent, %{"code" => "email_no_recipients"}}} =
               ErrorPolicy.normalize_delivery_result({:error, :no_recipients})

      assert :unknown = ErrorPolicy.normalize_delivery_result(:unknown)
    end
  end

  defp binding_config do
    %{
      "address" => "Agent@Corp.example",
      "displayName" => "Ankole Agent",
      "imapHost" => "imap.corp.example",
      "smtpHost" => "smtp.corp.example",
      "username" => "agent",
      "password" => "secret"
    }
  end

  defp bound_consumer(agent_uid, binding_name, policy) do
    assert {:ok, _binding} =
             SignalsGateway.put_binding(agent_uid, "email", binding_name, %{
               "config" => binding_config(),
               "unmatched_sender_policy" => policy
             })

    Inbound.chat_consumer(
      AdapterContext.new(
        agent_uid: agent_uid,
        binding_name: binding_name,
        adapter: "email",
        user_name: "Email"
      ),
      validated_config()
    )
  end

  defp validated_config do
    {:ok, config} = Config.validate_binding_config(binding_config())
    config
  end

  defp event(uid, raw) do
    %{
      "uid" => uid,
      "uidvalidity" => 7,
      "raw" => raw,
      "size" => byte_size(raw),
      "headers_only" => false
    }
  end

  defp raw_mail(opts) do
    from = Keyword.get(opts, :from, "Ada <ada@example.com>")
    to = Keyword.get(opts, :to, ["Agent <#{@mailbox}>"])
    body = Keyword.get(opts, :body, "Hello from the sender.")

    from_domain =
      from |> String.split("@") |> List.last() |> String.trim_trailing(">") |> String.downcase()

    headers =
      [
        "Authentication-Results: " <>
          Keyword.get(
            opts,
            :authentication,
            "mx.corp.example; dmarc=pass header.from=#{from_domain}"
          ),
        "Message-ID: <#{Keyword.get(opts, :message_id, "m#{System.unique_integer([:positive])}@example.com")}>",
        opts[:in_reply_to] && "In-Reply-To: <#{opts[:in_reply_to]}>",
        opts[:references] && "References: " <> Enum.map_join(opts[:references], " ", &"<#{&1}>"),
        "From: #{from}",
        "To: #{Enum.join(to, ", ")}",
        opts[:cc] && "Cc: #{Enum.join(opts[:cc], ", ")}",
        "Subject: #{Keyword.get(opts, :subject, "Hello")}",
        "Date: Fri, 11 Sep 2026 14:41:42 +0800",
        "MIME-Version: 1.0"
      ] ++ Keyword.get(opts, :extra_headers, ["Content-Type: text/plain; charset=utf-8"])

    Enum.map_join(Enum.reject(headers, &is_nil/1), "\r\n", & &1) <> "\r\n\r\n" <> body
  end

  defp sample_multipart_mail do
    gb_body =
      Codepagex.from_string!(
        "你好，请看附件。\r\n\r\nOn Thu, Sep 10, 2026 at 10:00 AM Agent <agent@corp.example> wrote:\r\n> earlier text",
        :"VENDORS/MICSFT/WINDOWS/CP936"
      )

    """
    Authentication-Results: mx.corp.example; spf=pass smtp.mailfrom=example.com;\r
     dkim=pass header.d=example.com; dmarc=pass (p=reject) header.from=example.com\r
    Message-ID: <abc123@example.com>\r
    In-Reply-To: <root@corp.example>\r
    References: <root@corp.example> <mid@corp.example>\r
    From: =?UTF-8?B?5byg5LiJ?= <Ada@Example.com>\r
    To: Agent <agent@corp.example>, Bob <bob@example.org>\r
    Subject: =?UTF-8?Q?Re=3A_=E5=9B=9E=E5=A4=8D=EF=BC=9A?= budget\r
    Date: Fri, 11 Sep 2026 14:41:42 +0800\r
    MIME-Version: 1.0\r
    Content-Type: multipart/mixed; boundary="outer"\r
    \r
    --outer\r
    Content-Type: multipart/alternative; boundary="inner"\r
    \r
    --inner\r
    Content-Type: text/plain; charset="gb2312"\r
    Content-Transfer-Encoding: base64\r
    \r
    #{Base.encode64(gb_body)}\r
    --inner\r
    Content-Type: text/html; charset="utf-8"\r
    \r
    <p>你好</p>\r
    --inner--\r
    --outer\r
    Content-Type: application/pdf; name="report.pdf"\r
    Content-Disposition: attachment; filename*=UTF-8''%E6%8A%A5%E5%91%8A.pdf\r
    Content-Transfer-Encoding: base64\r
    \r
    JVBERi0xLjQK\r
    --outer--\r
    """
  end

  defp start_fake_smtp do
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

  defp start_fake_tls_smtp do
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

  defp commit_and_dispatch(%OutboxEntry{} = outbox) do
    attrs =
      outbox
      |> Map.take([
        :agent_uid,
        :binding_name,
        :outbound_key,
        :operation,
        :signal_channel_id,
        :reply_to_source_entry_id,
        :payload,
        :fallback_visible_text
      ])
      |> Map.put(:delivery_class, :generic)
      |> Map.put(:idempotency_key, outbox.outbound_key)

    with {:ok, _outbox} <- SignalsGateway.commit_outbox(attrs) do
      SignalsGateway.dispatch_outbox_by_key(
        outbox.agent_uid,
        outbox.binding_name,
        outbox.outbound_key
      )
    end
  end

  defp received_store?(uid) do
    receive do
      {:imap_command, "A" <> _rest = command} ->
        if String.contains?(command, "UID STORE #{uid} "), do: true, else: received_store?(uid)
    after
      0 -> false
    end
  end
end
