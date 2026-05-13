defmodule BullxTelegram.DirectCommand do
  @moduledoc """
  Adapter-local Telegram slash commands: `/ping`, `/preauth <code>`, `/web_auth`.

  Commands are intercepted before Gateway inbound publish. Replies go through
  `BullX.Gateway.deliver/1` instead of calling the Bot API directly, so the
  Gateway outbound contract owns retries and dead-letter handling for
  adapter-local replies. Duplicate replies for the same `update_id` are
  suppressed by a short-TTL `BullX.Cache` entry.
  """

  alias BullxTelegram.{Error, Source}

  @intercepted_names ~w(ping preauth web_auth)

  @spec parse(String.t() | nil, Source.t() | nil) ::
          {:ok, map()} | :error | {:error_other_bot, String.t()}
  def parse(text, source \\ nil)

  def parse(text, source) when is_binary(text) do
    text = String.trim(text)

    with true <- String.starts_with?(text, "/"),
         [raw_name | rest] <-
           String.split(String.trim_leading(text, "/"), ~r/\s+/, parts: 2),
         {:ok, name} <- normalize_command_name(raw_name, source),
         true <- name in @intercepted_names do
      {:ok, %{name: name, args: Enum.join(rest, " ")}}
    else
      {:other_bot, name} -> {:error_other_bot, name}
      _other -> :error
    end
  end

  def parse(_text, _source), do: :error

  @spec intercepted?(String.t()) :: boolean()
  def intercepted?(name) when is_binary(name), do: name in @intercepted_names
  def intercepted?(_name), do: false

  @spec handle(map(), Source.t()) :: {:ok, map()} | {:error, map()}
  def handle(%{event_id: event_id} = command, %Source{} = source) do
    start_time = System.monotonic_time()
    meta = %{channel_id: source.channel_id, command_name: command.name}

    :telemetry.execute(
      [:bullx, :telegram, :direct_command, :start],
      %{system_time: System.system_time()},
      meta
    )

    result = do_handle(command, source, event_id)

    :telemetry.execute(
      [:bullx, :telegram, :direct_command, :stop],
      %{duration: System.monotonic_time() - start_time},
      Map.put(meta, :result, telemetry_result(result))
    )

    result
  end

  @spec reply_text(map(), Source.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, map()}
  def reply_text(command, %Source{} = source, text, command_name) do
    delivery = %{
      id: BullX.Ext.gen_uuid_v7(),
      op: :send,
      channel: {source.adapter, source.channel_id},
      scope_id: to_string(command.chat_id),
      thread_id: thread_string(command.thread_id),
      reply_to_external_id: to_string_or_nil(command.message_id),
      content: [%{"kind" => "text", "body" => %{"text" => text}}],
      extensions: %{"command_name" => command_name}
    }

    case BullX.Gateway.deliver(delivery) do
      {:ok, :accepted, delivery_id} ->
        {:ok,
         %{
           "command_name" => command_name,
           "delivery_id" => delivery_id,
           "status" => "accepted"
         }}

      {:error, error} ->
        {:error, Error.map(error)}
    end
  end

  defp do_handle(command, %Source{} = source, event_id) do
    key = direct_cache_key(source, event_id)

    case BullX.Cache.get(key) do
      {:ok, result} ->
        {:ok, Map.put(result, "duplicate", true)}

      {:error, :not_found} ->
        run_and_cache(command, source, key)

      {:error, reason} ->
        {:error, Error.map(reason)}
    end
  end

  defp telemetry_result({:ok, _result}), do: :ok
  defp telemetry_result({:error, %{"kind" => kind}}) when is_binary(kind), do: kind
  defp telemetry_result(_result), do: :error

  defp run_and_cache(command, %Source{} = source, key) do
    with {:ok, result} <- run(command, source),
         :ok <- BullX.Cache.put(key, result, source.direct_command_dedupe_ttl_seconds) do
      {:ok, result}
    end
  end

  defp run(%{name: "ping"} = command, %Source{} = source) do
    reply_text(command, source, BullX.I18n.t("gateway.telegram.ping.pong"), "ping")
  end

  defp run(%{name: "preauth", chat_type: chat_type} = command, %Source{} = source)
       when chat_type != "private" do
    reply_text(
      command,
      source,
      BullX.I18n.t("gateway.telegram.auth.direct_command_dm_only"),
      "preauth"
    )
  end

  defp run(%{name: "preauth", args: args} = command, %Source{} = source) do
    text =
      args
      |> to_string()
      |> String.trim()
      |> BullX.Principals.consume_activation_code(command.account_input)
      |> activation_reply()

    reply_text(command, source, text, "preauth")
  end

  defp run(%{name: "web_auth", chat_type: chat_type} = command, %Source{} = source)
       when chat_type != "private" do
    reply_text(
      command,
      source,
      BullX.I18n.t("gateway.telegram.auth.direct_command_dm_only"),
      "web_auth"
    )
  end

  defp run(%{name: "web_auth"} = command, %Source{} = source) do
    text =
      case Source.web_login_allowed?(source) do
        true ->
          "telegram"
          |> BullX.Principals.issue_login_auth_code(source.channel_id, command.actor.id)
          |> web_auth_reply(web_login_url())

        false ->
          BullX.I18n.t("gateway.telegram.auth.web_auth_disabled")
      end

    reply_text(command, source, text, "web_auth")
  end

  defp run(command, %Source{} = source) do
    reply_text(
      command,
      source,
      BullX.I18n.t("gateway.telegram.errors.unsupported_message"),
      command.name
    )
  end

  defp activation_reply({:ok, _principal, _identity}),
    do: BullX.I18n.t("gateway.telegram.auth.activation_success")

  defp activation_reply({:error, :invalid_or_expired_code}),
    do: BullX.I18n.t("gateway.telegram.auth.activation_code_invalid")

  defp activation_reply({:error, :already_bound}),
    do: BullX.I18n.t("gateway.telegram.auth.already_linked")

  defp activation_reply({:error, :principal_disabled}),
    do: BullX.I18n.t("gateway.telegram.auth.denied")

  defp activation_reply({:error, _reason}),
    do: BullX.I18n.t("gateway.telegram.auth.activation_failed")

  defp web_auth_reply({:ok, code}, login_url) do
    BullX.I18n.t("gateway.telegram.auth.web_auth_created", %{code: code, login_url: login_url})
  end

  defp web_auth_reply({:error, :not_bound}, _login_url),
    do: BullX.I18n.t("gateway.telegram.auth.web_auth_not_bound")

  defp web_auth_reply({:error, :not_human}, _login_url),
    do: BullX.I18n.t("gateway.telegram.auth.web_auth_not_bound")

  defp web_auth_reply({:error, :principal_disabled}, _login_url),
    do: BullX.I18n.t("gateway.telegram.auth.denied")

  defp web_auth_reply({:error, _reason}, _login_url),
    do: BullX.I18n.t("gateway.telegram.auth.web_auth_failed")

  defp normalize_command_name(raw_name, source) do
    case String.split(raw_name, "@", parts: 2) do
      [name] ->
        {:ok, String.downcase(name)}

      [name, bot_username] ->
        normalize_bot_qualified_command(name, bot_username, source)
    end
  end

  defp normalize_bot_qualified_command(name, bot_username, %Source{bot_username: configured})
       when is_binary(configured) do
    case String.downcase(bot_username) == String.downcase(configured) do
      true -> {:ok, String.downcase(name)}
      false -> {:other_bot, String.downcase(name)}
    end
  end

  defp normalize_bot_qualified_command(name, _bot_username, _source),
    # When source has no bot_username configured, accept any addressee so the
    # adapter can still parse the command name.
    do: {:ok, String.downcase(name)}

  defp direct_cache_key(%Source{} = source, event_id) do
    "telegram:#{source.channel_id}:direct_command:#{event_id}"
  end

  defp web_login_url do
    BullXWeb.Endpoint.url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/sessions/new")
  end

  defp thread_string(nil), do: nil
  defp thread_string(value), do: to_string(value)

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(""), do: nil
  defp to_string_or_nil(value), do: to_string(value)
end
