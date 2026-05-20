defmodule BullxTelegram.DirectCommand do
  @moduledoc false

  alias BullxTelegram.Source

  @spec handle(Source.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def handle(%Source{} = source, %{event_id: event_id} = command, opts \\ []) do
    key = "telegram:#{source.id}:direct_command:#{event_id}"

    case BullX.Cache.get(key) do
      {:ok, result} ->
        {:ok, Map.put(result, "duplicate", true)}

      {:error, :not_found} ->
        with {:ok, result} <- run(source, command, opts),
             :ok <- BullX.Cache.put(key, result, source.direct_command_dedupe_ttl_seconds) do
          {:ok, result}
        end

      {:error, reason} ->
        {:error, BullxTelegram.Error.map(reason)}
    end
  end

  @spec reply_text(map(), Source.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def reply_text(command, %Source{} = source, text, command_name, opts \\ []) do
    with {:ok, result} <- BullxTelegram.Outbound.reply_text(command, source, text, opts) do
      {:ok, Map.merge(result, %{"command_name" => command_name})}
    end
  end

  defp run(%Source{} = source, %{name: "preauth", chat_type: chat_type} = command, opts)
       when chat_type != "private" do
    reply_text(
      command,
      source,
      BullX.I18n.t("eventbus.telegram.auth.direct_command_dm_only"),
      "preauth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "preauth", args: args} = command, opts) do
    text =
      args
      |> to_string()
      |> String.trim()
      |> BullX.Principals.consume_activation_code(account_input(source, command))
      |> activation_reply()

    reply_text(command, source, text, "preauth", opts)
  end

  defp run(%Source{} = source, %{name: "webauth", chat_type: chat_type} = command, opts)
       when chat_type != "private" do
    reply_text(
      command,
      source,
      BullX.I18n.t("eventbus.telegram.auth.direct_command_dm_only"),
      "webauth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "webauth"} = command, opts)
       when source.web_login_disabled? do
    reply_text(
      command,
      source,
      BullX.I18n.t("eventbus.telegram.auth.webauth_disabled"),
      "webauth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "webauth"} = command, opts) do
    text =
      "telegram"
      |> BullX.Principals.issue_login_auth_code(source.id, command.actor.id)
      |> webauth_reply(BullX.Principals.web_login_url())

    reply_text(command, source, text, "webauth", opts)
  end

  defp run(%Source{} = source, command, opts) do
    reply_text(
      command,
      source,
      BullX.I18n.t("eventbus.telegram.errors.unsupported_message"),
      command.name,
      opts
    )
  end

  defp account_input(%Source{} = source, command) do
    %{
      "adapter" => "telegram",
      "channel_id" => source.id,
      "external_id" => command.actor.id,
      "profile" => Map.get(command.actor, :profile, %{}),
      "metadata" => %{
        "chat_id" => command.chat_id,
        "chat_type" => command.chat_type,
        "thread_id" => command.thread_id
      }
    }
  end

  defp activation_reply({:ok, _principal, _identity}),
    do: BullX.I18n.t("eventbus.telegram.auth.activation_success")

  defp activation_reply({:error, :invalid_or_expired_code}),
    do: BullX.I18n.t("eventbus.telegram.auth.activation_code_invalid")

  defp activation_reply({:error, :already_bound}),
    do: BullX.I18n.t("eventbus.telegram.auth.already_linked")

  defp activation_reply({:error, :principal_disabled}),
    do: BullX.I18n.t("eventbus.telegram.auth.denied")

  defp activation_reply({:error, _reason}),
    do: BullX.I18n.t("eventbus.telegram.auth.activation_failed")

  defp webauth_reply({:ok, code}, login_url),
    do:
      BullX.I18n.t("eventbus.telegram.auth.webauth_created", %{code: code, login_url: login_url})

  defp webauth_reply({:error, :not_bound}, _login_url),
    do: BullX.I18n.t("eventbus.telegram.auth.webauth_not_bound")

  defp webauth_reply({:error, :not_human}, _login_url),
    do: BullX.I18n.t("eventbus.telegram.auth.webauth_not_bound")

  defp webauth_reply({:error, :principal_disabled}, _login_url),
    do: BullX.I18n.t("eventbus.telegram.auth.denied")

  defp webauth_reply({:error, _reason}, _login_url),
    do: BullX.I18n.t("eventbus.telegram.auth.webauth_failed")
end
