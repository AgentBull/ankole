defmodule Discord.DirectCommand do
  @moduledoc false

  alias Discord.Source

  @spec handle(Source.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def handle(%Source{} = source, %{event_id: event_id} = command, opts \\ []) do
    key = "discord:#{source.id}:direct_command:#{event_id}"

    case BullX.Cache.get(key) do
      {:ok, result} ->
        {:ok, Map.put(result, "duplicate", true)}

      {:error, :not_found} ->
        with {:ok, result} <- run(source, command, opts),
             :ok <- BullX.Cache.put(key, result, source.message_context_ttl_seconds) do
          {:ok, result}
        end

      {:error, reason} ->
        {:error, Discord.Error.map(reason)}
    end
  end

  @spec reply_text(map(), Source.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def reply_text(command, %Source{} = source, text, command_name, opts \\ []) do
    with {:ok, result} <- Discord.Outbound.reply_text(command, source, text, opts) do
      {:ok, Map.merge(result, %{"command_name" => command_name})}
    end
  end

  defp run(%Source{} = source, %{name: "preauth", guild_id: guild_id} = command, opts)
       when is_binary(guild_id) and guild_id != "" do
    reply_text(
      command,
      source,
      BullX.I18n.t("eventbus.discord.auth.direct_command_dm_only"),
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

  defp run(%Source{} = source, %{name: "webauth", guild_id: guild_id} = command, opts)
       when is_binary(guild_id) and guild_id != "" do
    reply_text(
      command,
      source,
      BullX.I18n.t("eventbus.discord.auth.direct_command_dm_only"),
      "webauth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "webauth"} = command, opts) do
    text =
      "discord"
      |> BullX.Principals.issue_login_auth_code(source.id, command.actor.id)
      |> webauth_reply(BullX.Principals.web_login_url())

    reply_text(command, source, text, "webauth", opts)
  end

  defp run(%Source{} = source, command, opts) do
    reply_text(
      command,
      source,
      BullX.I18n.t("eventbus.discord.errors.unsupported_message"),
      command.name,
      opts
    )
  end

  defp account_input(%Source{} = source, command) do
    %{
      "adapter" => "discord",
      "channel_id" => source.id,
      "external_id" => command.actor.id,
      "profile" => Map.get(command.actor, :profile, %{}),
      "metadata" => %{
        "guild_id" => command.guild_id,
        "discord_channel_id" => command.channel_id
      }
    }
  end

  defp activation_reply({:ok, _principal, _identity}),
    do: BullX.I18n.t("eventbus.discord.auth.activation_success")

  defp activation_reply({:error, :invalid_or_expired_code}),
    do: BullX.I18n.t("eventbus.discord.auth.activation_code_invalid")

  defp activation_reply({:error, :already_bound}),
    do: BullX.I18n.t("eventbus.discord.auth.already_linked")

  defp activation_reply({:error, :principal_disabled}),
    do: BullX.I18n.t("eventbus.discord.auth.denied")

  defp activation_reply({:error, _reason}),
    do: BullX.I18n.t("eventbus.discord.auth.activation_failed")

  defp webauth_reply({:ok, code}, login_url),
    do: BullX.I18n.t("eventbus.discord.auth.webauth_created", %{code: code, login_url: login_url})

  defp webauth_reply({:error, :not_bound}, _login_url),
    do: BullX.I18n.t("eventbus.discord.auth.webauth_not_bound")

  defp webauth_reply({:error, :not_human}, _login_url),
    do: BullX.I18n.t("eventbus.discord.auth.webauth_not_bound")

  defp webauth_reply({:error, :principal_disabled}, _login_url),
    do: BullX.I18n.t("eventbus.discord.auth.denied")

  defp webauth_reply({:error, _reason}, _login_url),
    do: BullX.I18n.t("eventbus.discord.auth.webauth_failed")
end
