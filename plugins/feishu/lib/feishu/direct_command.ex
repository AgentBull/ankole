defmodule Feishu.DirectCommand do
  @moduledoc false

  alias Feishu.Source

  @spec parse(String.t() | nil) :: {:ok, map()} | :error
  def parse(text) when is_binary(text) do
    text = String.trim(text)

    with true <- String.starts_with?(text, "/"),
         [name | rest] <- String.split(String.trim_leading(text, "/"), ~r/\s+/, parts: 2),
         true <- name != "" do
      {:ok, %{name: name, args: Enum.join(rest, " ")}}
    else
      _other -> :error
    end
  end

  def parse(_text), do: :error

  @spec handle(map(), Source.t()) :: {:ok, map()} | {:error, map()}
  def handle(%{event_id: event_id} = command, %Source{} = source) do
    start_time = System.monotonic_time()
    meta = %{channel_id: source.channel_id, command_name: command.name}

    :telemetry.execute(
      [:bullx, :feishu, :direct_command, :start],
      %{system_time: System.system_time()},
      meta
    )

    result = do_handle(command, source, event_id)

    :telemetry.execute(
      [:bullx, :feishu, :direct_command, :stop],
      %{duration: System.monotonic_time() - start_time},
      Map.put(meta, :result, telemetry_result(result))
    )

    result
  end

  defp do_handle(command, %Source{} = source, event_id) do
    key = direct_cache_key(source, event_id)

    case BullX.Cache.get(key) do
      {:ok, result} ->
        {:ok, Map.put(result, "duplicate", true)}

      {:error, :not_found} ->
        run_and_cache(command, source, key)

      {:error, reason} ->
        {:error, Feishu.Error.map(reason)}
    end
  end

  defp telemetry_result({:ok, _result}), do: :ok
  defp telemetry_result({:error, %{"kind" => kind}}) when is_binary(kind), do: kind
  defp telemetry_result(_result), do: :error

  @spec reply_text(map(), Source.t(), String.t(), String.t()) :: {:ok, map()} | {:error, map()}
  def reply_text(command, %Source{} = source, text, command_name) do
    delivery = %{
      id: BullX.Ext.gen_uuid_v7(),
      op: :send,
      channel: {source.adapter, source.channel_id},
      scope_id: command.chat_id,
      thread_id: command.thread_id,
      reply_to_external_id: command.message_id,
      content: [%{"kind" => "text", "body" => %{"text" => text}}],
      extensions: %{"command_name" => command_name}
    }

    case BullX.Gateway.deliver(delivery) do
      {:ok, :accepted, delivery_id} ->
        {:ok,
         %{"command_name" => command_name, "delivery_id" => delivery_id, "status" => "accepted"}}

      {:error, error} ->
        {:error, Feishu.Error.map(error)}
    end
  end

  defp run_and_cache(command, %Source{} = source, key) do
    with {:ok, result} <- run(command, source),
         :ok <- BullX.Cache.put(key, result, source.direct_command_dedupe_ttl_seconds) do
      {:ok, result}
    end
  end

  defp run(%{name: "ping"} = command, %Source{} = source) do
    reply_text(command, source, BullX.I18n.t("gateway.feishu.ping.pong"), "ping")
  end

  defp run(%{name: "preauth", chat_type: chat_type} = command, %Source{} = source)
       when chat_type != "p2p" do
    reply_text(
      command,
      source,
      BullX.I18n.t("gateway.feishu.auth.direct_command_dm_only"),
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
       when chat_type != "p2p" do
    reply_text(
      command,
      source,
      BullX.I18n.t("gateway.feishu.auth.direct_command_dm_only"),
      "web_auth"
    )
  end

  defp run(%{name: "web_auth"} = command, %Source{} = source) do
    text =
      "feishu"
      |> BullX.Principals.issue_login_auth_code(source.channel_id, command.actor.id)
      |> web_auth_reply(web_login_url())

    reply_text(command, source, text, "web_auth")
  end

  defp run(command, %Source{} = source) do
    reply_text(
      command,
      source,
      BullX.I18n.t("gateway.feishu.errors.unsupported_message"),
      command.name
    )
  end

  defp activation_reply({:ok, _principal, _identity}),
    do: BullX.I18n.t("gateway.feishu.auth.activation_success")

  defp activation_reply({:error, :invalid_or_expired_code}),
    do: BullX.I18n.t("gateway.feishu.auth.activation_code_invalid")

  defp activation_reply({:error, :already_bound}),
    do: BullX.I18n.t("gateway.feishu.auth.already_linked")

  defp activation_reply({:error, :principal_disabled}),
    do: BullX.I18n.t("gateway.feishu.auth.denied")

  defp activation_reply({:error, _reason}),
    do: BullX.I18n.t("gateway.feishu.auth.activation_failed")

  defp web_auth_reply({:ok, code}, login_url) do
    BullX.I18n.t("gateway.feishu.auth.web_auth_created", %{code: code, login_url: login_url})
  end

  defp web_auth_reply({:error, :not_bound}, _login_url),
    do: BullX.I18n.t("gateway.feishu.auth.web_auth_not_bound")

  defp web_auth_reply({:error, :not_human}, _login_url),
    do: BullX.I18n.t("gateway.feishu.auth.web_auth_not_bound")

  defp web_auth_reply({:error, :principal_disabled}, _login_url),
    do: BullX.I18n.t("gateway.feishu.auth.denied")

  defp web_auth_reply({:error, _reason}, _login_url),
    do: BullX.I18n.t("gateway.feishu.auth.web_auth_failed")

  defp direct_cache_key(%Source{} = source, event_id) do
    "feishu:#{source.channel_id}:direct_command:#{event_id}"
  end

  defp web_login_url do
    BullXWeb.Endpoint.url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/sessions/new")
  end
end
