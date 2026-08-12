defmodule FakeFeishu.CLI do
  @moduledoc """
  Escript entrypoint of the `fake-feishu` tool.

  `serve` runs the standalone platform; every other subcommand drives a
  running server through its `/sim/v1` admin API as the user side of a
  conversation.
  """

  alias FakeFeishu.CLI.HTTP
  alias FakeFeishu.CLI.Render
  alias FakeFeishu.Sim

  @default_url "http://127.0.0.1:7788"

  @usage """
  fake-feishu — standalone fake Feishu platform for local e2e work

  Server:
    fake-feishu serve [--port 7788] [--app ID:SECRET[:BOT_OPEN_ID]]...
                      [--user NAME]... [--no-cardkit] [--strict-apps]

  User side (target server: --url URL or FAKE_FEISHU_URL, default #{@default_url}):
    fake-feishu status
    fake-feishu chats [--json]
    fake-feishu chat-create --name NAME [--p2p] [--user NAME]... [--bot APP_ID]...
    fake-feishu send TEXT [--chat ID] [--as NAME] [--mention-bot]
                     [--reply MSG_ID] [--file PATH] [--image PATH]
    fake-feishu ls [--chat ID] [--json]
    fake-feishu tail [--all]
    fake-feishu repl [--chat ID] [--as NAME] [--no-mention]
    fake-feishu recall MSG_ID
    fake-feishu react MSG_ID EMOJI [--remove] [--as NAME]
    fake-feishu click MSG_ID [--value JSON] [--as NAME]
    fake-feishu download KEY [-o PATH]
    fake-feishu fault OP (--code N | --http-500 | --rate-limited |
                          --token-invalid | --delay MS)

  The repl sends each line as the chosen persona; in group chats it mentions
  the bot per default (start a line with `!` to skip the mention, use
  `--no-mention` to flip the default). Repl commands: /help /chats /chat ID
  /as NAME /ls /recall ID /react ID EMOJI /click ID [JSON] /file PATH
  /image PATH /quit
  """

  def main(argv) do
    {url, argv} = take_url(argv)

    case argv do
      ["serve" | args] -> serve(args)
      ["status"] -> status(url)
      ["chats" | args] -> chats(url, args)
      ["chat-create" | args] -> chat_create(url, args)
      ["send" | args] -> send_message(url, args)
      ["ls" | args] -> ls(url, args)
      ["tail" | args] -> tail(url, args)
      ["repl" | args] -> repl(url, args)
      ["recall", message_id] -> recall(url, message_id)
      ["react" | args] -> react(url, args)
      ["click" | args] -> click(url, args)
      ["download" | args] -> download(url, args)
      ["fault" | args] -> fault(url, args)
      _help -> IO.puts(@usage)
    end
  end

  # Extracts --url by hand so subcommand flags pass through untouched.
  defp take_url(argv), do: take_url(argv, System.get_env("FAKE_FEISHU_URL") || @default_url, [])

  defp take_url([], url, acc), do: {url, Enum.reverse(acc)}
  defp take_url(["--url", url | rest], _url, acc), do: take_url(rest, url, acc)
  defp take_url(["--url=" <> url | rest], _url, acc), do: take_url(rest, url, acc)
  defp take_url([arg | rest], url, acc), do: take_url(rest, url, [arg | acc])

  # -- serve ---------------------------------------------------------------------

  defp serve(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          port: :integer,
          app: :keep,
          user: :keep,
          cardkit: :boolean,
          strict_apps: :boolean
        ]
      )

    port = opts[:port] || 7788
    apps = for app <- Keyword.get_values(opts, :app), do: parse_app(app)

    users =
      case Keyword.get_values(opts, :user) do
        [] -> ["Alice", "Bob"]
        users -> users
      end

    {:ok, _apps} = Application.ensure_all_started([:bandit, :websock_adapter])

    {:ok, _supervisor} =
      FakeFeishu.Standalone.start_link(
        port: port,
        apps: apps,
        users: users,
        cardkit: Keyword.get(opts, :cardkit, true),
        strict_apps: Keyword.get(opts, :strict_apps, false)
      )

    IO.puts("""
    fake-feishu platform listening on http://127.0.0.1:#{port}
      cardkit: #{Keyword.get(opts, :cardkit, true)}   auto-register apps: #{not Keyword.get(opts, :strict_apps, false)}
      apps: #{case apps do
      [] -> "(none yet — unknown apps register on first authentication)"
      apps -> Enum.map_join(apps, ", ", &elem(&1, 0))
    end}
      personas: #{Enum.join(users, ", ")}

    Point the control plane at it:
      export ANKOLE_LARK_BASE_URL_OVERRIDE=http://127.0.0.1:#{port}

    Then talk to the bot:
      tools/fake-feishu/run repl
    """)

    Process.sleep(:infinity)
  end

  defp parse_app(spec) do
    case String.split(spec, ":", parts: 3) do
      [app_id, secret] -> {app_id, secret, nil}
      [app_id, secret, bot_open_id] -> {app_id, secret, bot_open_id}
      _invalid -> abort("--app expects APP_ID:SECRET[:BOT_OPEN_ID], got #{spec}")
    end
  end

  # -- read commands ----------------------------------------------------------------

  defp status(url) do
    with {:ok, status} <- HTTP.get(url, "/sim/v1/status") do
      IO.puts(JSON.encode!(status))
    end
    |> or_abort()
  end

  defp chats(url, args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with {:ok, chats} <- HTTP.get(url, "/sim/v1/chats") do
      case opts[:json] do
        true ->
          IO.puts(JSON.encode!(chats))

        _human ->
          Enum.each(chats, fn chat ->
            members =
              Enum.map_join(chat["members"], ", ", fn
                %{"type" => "bot"} = member -> "🤖" <> (member["app_id"] || member["name"])
                member -> member["name"]
              end)

            IO.puts("#{chat["id"]}  [#{chat["type"]}] #{chat["name"]}  (#{members})")
          end)
      end
    end
    |> or_abort()
  end

  defp chat_create(url, args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [name: :string, p2p: :boolean, user: :keep, bot: :keep]
      )

    body = %{
      "name" => opts[:name] || abort("chat-create requires --name"),
      "type" => if(opts[:p2p], do: "p2p", else: "group"),
      "users" => Keyword.get_values(opts, :user),
      "bots" => Keyword.get_values(opts, :bot)
    }

    with {:ok, chat} <- HTTP.post(url, "/sim/v1/chats", body) do
      IO.puts("created #{chat["id"]}")
    end
    |> or_abort()
  end

  defp ls(url, args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [chat: :string, json: :boolean])

    with {:ok, chat_id} <- resolve_chat(url, opts[:chat]),
         {:ok, messages} <- HTTP.get(url, "/sim/v1/chats/#{chat_id}/messages") do
      case opts[:json] do
        true -> IO.puts(JSON.encode!(messages))
        _human -> Render.print_transcript(messages)
      end

      {:ok, :done}
    end
    |> or_abort()
  end

  # -- user actions -----------------------------------------------------------------

  defp send_message(url, args) do
    {opts, rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          chat: :string,
          as: :string,
          mention_bot: :boolean,
          reply: :string,
          file: :string,
          image: :string
        ]
      )

    body =
      %{}
      |> put_present("text", Enum.join(rest, " "))
      |> put_present("as", opts[:as])
      |> put_present("reply_to", opts[:reply])
      |> then(fn body ->
        case opts[:mention_bot] do
          true -> Map.put(body, "mention_bot", true)
          _off -> body
        end
      end)
      |> attach_upload("file", opts[:file])
      |> attach_upload("image", opts[:image])

    with {:ok, chat_id} <- resolve_chat(url, opts[:chat]),
         {:ok, ids} <- HTTP.post(url, "/sim/v1/chats/#{chat_id}/messages", body) do
      IO.puts("sent #{ids["message_id"]} (event #{ids["event_id"]})")
      {:ok, :done}
    end
    |> or_abort()
  end

  defp recall(url, message_id) do
    with {:ok, _result} <- HTTP.post(url, "/sim/v1/messages/#{message_id}/recall", %{}) do
      IO.puts("recalled #{message_id}")
      {:ok, :done}
    end
    |> or_abort()
  end

  defp react(url, args) do
    {opts, rest, _invalid} =
      OptionParser.parse(args, strict: [remove: :boolean, as: :string])

    [message_id, emoji] =
      case rest do
        [message_id, emoji] -> [message_id, emoji]
        _invalid -> abort("react expects MSG_ID EMOJI")
      end

    body = %{"emoji" => emoji} |> put_present("as", opts[:as])

    result =
      case opts[:remove] do
        true -> HTTP.delete(url, "/sim/v1/messages/#{message_id}/reactions", body)
        _add -> HTTP.post(url, "/sim/v1/messages/#{message_id}/reactions", body)
      end

    with {:ok, _result} <- result do
      IO.puts("ok")
      {:ok, :done}
    end
    |> or_abort()
  end

  defp click(url, args) do
    {opts, rest, _invalid} = OptionParser.parse(args, strict: [value: :string, as: :string])

    message_id =
      case rest do
        [message_id] -> message_id
        _invalid -> abort("click expects MSG_ID")
      end

    value =
      case opts[:value] do
        nil -> %{}
        raw -> JSON.decode!(raw)
      end

    body = %{"value" => value} |> put_present("as", opts[:as])

    with {:ok, _result} <- HTTP.post(url, "/sim/v1/messages/#{message_id}/card-action", body) do
      IO.puts("clicked #{message_id}")
      {:ok, :done}
    end
    |> or_abort()
  end

  defp download(url, args) do
    {opts, rest, _invalid} = OptionParser.parse(args, strict: [o: :string, out: :string])

    key =
      case rest do
        [key] -> key
        _invalid -> abort("download expects KEY")
      end

    result =
      case HTTP.get_binary(url, "/sim/v1/files/#{key}") do
        {:ok, content} -> {:ok, content}
        {:error, _reason} -> HTTP.get_binary(url, "/sim/v1/images/#{key}")
      end

    with {:ok, content} <- result do
      path = opts[:o] || opts[:out] || key
      File.write!(path, content)
      IO.puts("wrote #{path} (#{byte_size(content)} bytes)")
      {:ok, :done}
    end
    |> or_abort()
  end

  defp fault(url, args) do
    {opts, rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          code: :integer,
          http_500: :boolean,
          rate_limited: :boolean,
          token_invalid: :boolean,
          delay: :integer
        ]
      )

    op =
      case rest do
        [op] -> op
        _invalid -> abort("fault expects OP (for example post_message)")
      end

    body =
      cond do
        opts[:code] -> %{"op" => op, "code" => opts[:code]}
        opts[:http_500] -> %{"op" => op, "error" => "http_500"}
        opts[:rate_limited] -> %{"op" => op, "error" => "rate_limited"}
        opts[:token_invalid] -> %{"op" => op, "error" => "token_invalid"}
        opts[:delay] -> %{"op" => op, "delay_ms" => opts[:delay]}
        true -> abort("fault needs --code/--http-500/--rate-limited/--token-invalid/--delay")
      end

    with {:ok, _result} <- HTTP.post(url, "/sim/v1/faults", body) do
      IO.puts("armed one-shot fault on #{op}")
      {:ok, :done}
    end
    |> or_abort()
  end

  # -- tail and repl -------------------------------------------------------------------

  defp tail(url, args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [all: :boolean])

    HTTP.stream(url, "/sim/v1/events/stream", %{}, fn event, cards ->
      case {opts[:all], event["type"]} do
        {nil, type} when type in ["event_acked"] -> cards
        _shown -> Render.print_event(event, cards)
      end
    end)
    |> case do
      {:ok, _cards} ->
        :ok

      {:error, :socket_closed_remotely, _cards} ->
        IO.puts("\nstream closed by server")

      {:error, reason, _cards} ->
        abort("stream failed: #{inspect(reason)}")
    end
  end

  defp repl(url, args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [chat: :string, as: :string, mention: :boolean])

    chat_id =
      case resolve_chat(url, opts[:chat]) do
        {:ok, chat_id} -> chat_id
        {:error, reason} -> abort(format_error(reason))
      end

    {:ok, chat} = fetch_chat(url, chat_id)
    mention_default = Keyword.get(opts, :mention, chat["type"] != "p2p")

    IO.puts("""
    chat #{chat_id} (#{chat["type"]}, #{chat["name"]}) — type to send#{if mention_default, do: " (@bot mention added; prefix ! to skip)", else: ""}
    /help for commands, /quit to leave
    """)

    with {:ok, messages} <- HTTP.get(url, "/sim/v1/chats/#{chat_id}/messages") do
      messages |> Enum.take(-20) |> Render.print_transcript()
    end

    parent = self()
    Task.start_link(fn -> reader_loop(parent) end)

    Task.start_link(fn ->
      HTTP.stream(url, "/sim/v1/events/stream", nil, fn event, acc ->
        send(parent, {:event, event})
        acc
      end)
    end)

    repl_loop(%{
      url: url,
      chat_id: chat_id,
      as: opts[:as],
      mention: mention_default,
      cards: %{}
    })
  end

  defp reader_loop(parent) do
    case IO.gets("") do
      :eof -> send(parent, {:line, "/quit"})
      {:error, _reason} -> send(parent, {:line, "/quit"})
      line -> send(parent, {:line, String.trim_trailing(line, "\n")})
    end

    reader_loop(parent)
  end

  defp repl_loop(state) do
    receive do
      {:event, event} ->
        cards =
          case relevant_event?(event, state.chat_id) do
            true -> Render.print_event(event, state.cards)
            false -> state.cards
          end

        repl_loop(%{state | cards: cards})

      {:line, "/quit"} ->
        :ok

      {:line, line} ->
        repl_loop(handle_repl_line(state, line))
    end
  end

  # Events without chat_id (card updates, uploads, connections) always render;
  # chat-scoped events render only for the current room.
  defp relevant_event?(%{"chat_id" => chat_id}, current), do: chat_id == current
  defp relevant_event?(_event, _current), do: true

  defp handle_repl_line(state, ""), do: state

  defp handle_repl_line(state, "/help") do
    IO.puts(
      "commands: /chats /chat ID /as NAME /ls /recall ID /react ID EMOJI /click ID [JSON] /file PATH /image PATH /quit"
    )

    state
  end

  defp handle_repl_line(state, "/chats") do
    case HTTP.get(state.url, "/sim/v1/chats") do
      {:ok, chats} ->
        Enum.each(chats, &IO.puts("#{&1["id"]}  [#{&1["type"]}] #{&1["name"]}"))

      {:error, reason} ->
        IO.puts("error: #{format_error(reason)}")
    end

    state
  end

  defp handle_repl_line(state, "/chat " <> chat_id) do
    chat_id = String.trim(chat_id)

    case fetch_chat(state.url, chat_id) do
      {:ok, chat} ->
        IO.puts("→ switched to #{chat_id} (#{chat["type"]}, #{chat["name"]})")
        %{state | chat_id: chat_id, mention: chat["type"] != "p2p"}

      {:error, reason} ->
        IO.puts("cannot switch: #{format_error(reason)}")
        state
    end
  end

  defp handle_repl_line(state, "/as " <> name) do
    %{state | as: String.trim(name)}
  end

  defp handle_repl_line(state, "/ls") do
    case HTTP.get(state.url, "/sim/v1/chats/#{state.chat_id}/messages") do
      {:ok, messages} -> Render.print_transcript(messages)
      {:error, reason} -> IO.puts("error: #{format_error(reason)}")
    end

    state
  end

  defp handle_repl_line(state, "/recall " <> message_id) do
    repl_action(state, fn ->
      HTTP.post(state.url, "/sim/v1/messages/#{String.trim(message_id)}/recall", %{})
    end)
  end

  defp handle_repl_line(state, "/react " <> rest) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [message_id, emoji] ->
        repl_action(state, fn ->
          HTTP.post(
            state.url,
            "/sim/v1/messages/#{message_id}/reactions",
            put_present(%{"emoji" => emoji}, "as", state.as)
          )
        end)

      _invalid ->
        IO.puts("usage: /react MSG_ID EMOJI")
        state
    end
  end

  defp handle_repl_line(state, "/click " <> rest) do
    {message_id, value} =
      case String.split(String.trim(rest), " ", parts: 2) do
        [message_id] -> {message_id, %{}}
        [message_id, json] -> {message_id, JSON.decode!(json)}
      end

    repl_action(state, fn ->
      HTTP.post(
        state.url,
        "/sim/v1/messages/#{message_id}/card-action",
        put_present(%{"value" => value}, "as", state.as)
      )
    end)
  end

  defp handle_repl_line(state, "/file " <> path) do
    send_repl_upload(state, "file", String.trim(path))
  end

  defp handle_repl_line(state, "/image " <> path) do
    send_repl_upload(state, "image", String.trim(path))
  end

  defp handle_repl_line(state, "/" <> _unknown = line) do
    IO.puts("unknown command #{line}; /help lists commands")
    state
  end

  defp handle_repl_line(state, line) do
    {mention, text} =
      case {state.mention, line} do
        {true, "!" <> rest} -> {false, rest}
        {mention, line} -> {mention, line}
      end

    body =
      %{"text" => text, "mention_bot" => mention}
      |> put_present("as", state.as)

    repl_action(state, fn ->
      HTTP.post(state.url, "/sim/v1/chats/#{state.chat_id}/messages", body)
    end)
  end

  defp send_repl_upload(state, kind, path) do
    case File.read(path) do
      {:ok, content} ->
        body =
          put_present(
            %{kind => %{"name" => Path.basename(path), "base64" => Base.encode64(content)}},
            "as",
            state.as
          )

        repl_action(state, fn ->
          HTTP.post(state.url, "/sim/v1/chats/#{state.chat_id}/messages", body)
        end)

      {:error, reason} ->
        IO.puts("cannot read #{path}: #{inspect(reason)}")
        state
    end
  end

  defp repl_action(state, fun) do
    case fun.() do
      {:ok, _result} -> :ok
      {:error, reason} -> IO.puts("error: #{format_error(reason)}")
    end

    state
  end

  # -- shared helpers ------------------------------------------------------------

  # Without --chat: a single chat wins, then the seeded general room; anything
  # else needs an explicit choice.
  defp resolve_chat(_url, chat_id) when is_binary(chat_id), do: {:ok, chat_id}

  defp resolve_chat(url, nil) do
    with {:ok, chats} <- HTTP.get(url, "/sim/v1/chats") do
      general = Sim.general_chat_id()

      case chats do
        [] ->
          {:error, "no chats exist yet — is the server running and the bot connected?"}

        [chat] ->
          {:ok, chat["id"]}

        chats ->
          case Enum.find(chats, &(&1["id"] == general)) do
            nil -> {:error, "several chats exist; pass --chat (see `fake-feishu chats`)"}
            _chat -> {:ok, general}
          end
      end
    end
  end

  defp fetch_chat(url, chat_id) do
    with {:ok, chats} <- HTTP.get(url, "/sim/v1/chats") do
      case Enum.find(chats, &(&1["id"] == chat_id)) do
        nil -> {:error, "chat #{chat_id} not found"}
        chat -> {:ok, chat}
      end
    end
  end

  defp attach_upload(body, _kind, nil), do: body

  defp attach_upload(body, kind, path) do
    Map.put(body, kind, %{
      "name" => Path.basename(path),
      "base64" => Base.encode64(File.read!(path))
    })
  end

  defp put_present(body, _key, nil), do: body
  defp put_present(body, _key, ""), do: body
  defp put_present(body, key, value), do: Map.put(body, key, value)

  defp or_abort({:ok, _result}), do: :ok
  defp or_abort(:ok), do: :ok
  defp or_abort({:error, reason}), do: abort(format_error(reason))

  defp format_error({status, detail}), do: "HTTP #{status}: #{inspect(detail)}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp abort(message) do
    IO.puts(:stderr, "fake-feishu: " <> message)
    System.halt(1)
  end
end
