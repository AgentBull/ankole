defmodule Discord.DirectCommand do
  @moduledoc false

  alias Discord.Source

  @dedupe_ttl_seconds 90_000

  @spec handle(Source.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def handle(%Source{} = source, %{event_id: event_id} = command, opts \\ []) do
    key = "discord:#{source.id}:direct_command:#{event_id}"
    ttl = @dedupe_ttl_seconds

    case BullX.Cache.put_new(key, %{"status" => "processing"}, ttl) do
      :inserted ->
        run_and_cache(source, command, key, ttl, opts)

      :exists ->
        cached_duplicate(key)

      {:error, reason} ->
        {:error, Discord.Error.map(reason)}
    end
  end

  defp cached_duplicate(key) do
    case BullX.Cache.get(key) do
      {:ok, result} -> {:ok, Map.put(result, "duplicate", true)}
      {:error, :not_found} -> {:ok, %{"status" => "processing", "duplicate" => true}}
      {:error, reason} -> {:error, Discord.Error.map(reason)}
    end
  end

  defp run_and_cache(%Source{} = source, command, key, ttl, opts) do
    case run(source, command, opts) do
      {:ok, result} ->
        with :ok <- BullX.Cache.put(key, result, ttl) do
          {:ok, result}
        end

      {:error, reason} ->
        _ignored = BullX.Cache.delete(key)
        {:error, reason}
    end
  end

  @spec reply_text(map(), Source.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def reply_text(command, %Source{} = source, text, command_name, opts \\ []) do
    with {:ok, result} <- Discord.Outbound.reply_text(command, source, text, opts) do
      {:ok, Map.merge(result, %{"command_name" => command_name})}
    end
  end

  defp run(%Source{} = source, %{name: "root_init"} = command, opts) do
    case BullX.AuthZ.ensure_root_init_open() do
      :ok ->
        run_root_init_open(source, command, opts)

      {:error, :root_init_closed} ->
        {:ok, %{"command_name" => "root_init", "status" => "ignored"}}
    end
  end

  defp run(%Source{} = source, %{name: "status"} = command, opts) do
    reply_text(
      command,
      source,
      BullX.IMGateway.CommandResponses.status_text(opts),
      "status",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "command"} = command, opts) do
    reply_text(
      command,
      source,
      BullX.IMGateway.CommandResponses.command_list_text(opts),
      "command",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "webauth", guild_id: guild_id} = command, opts)
       when is_binary(guild_id) and guild_id != "" do
    reply_text(
      command,
      source,
      BullX.I18n.t("im_gateway.discord.auth.direct_command_dm_only"),
      "webauth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "webauth"} = command, opts) do
    text =
      source
      |> maybe_ensure_command_actor(command)
      |> issue_login_auth_code("discord", source.id, command.actor.id)
      |> webauth_reply(BullX.Principals.web_login_url())

    reply_text(command, source, text, "webauth", opts)
  end

  defp run(%Source{} = source, command, opts) do
    reply_text(
      command,
      source,
      BullX.I18n.t("im_gateway.discord.errors.unsupported_message"),
      command.name,
      opts
    )
  end

  defp run_root_init_open(%Source{} = source, %{guild_id: guild_id} = command, opts)
       when is_binary(guild_id) and guild_id != "" do
    reply_text(
      command,
      source,
      BullX.I18n.t("im_gateway.discord.auth.direct_command_dm_only"),
      "root_init",
      opts
    )
  end

  defp run_root_init_open(%Source{} = source, %{args: args} = command, opts) do
    text =
      args
      |> to_string()
      |> String.trim()
      |> BullX.Principals.root_init_with_bootstrap_code(root_init_account_input(source, command))
      |> root_init_reply()

    reply_text(command, source, text, "root_init", opts)
  end

  defp root_init_account_input(%Source{} = source, command) do
    %{
      "adapter" => "discord",
      "channel_id" => source.id,
      "external_id" => command.actor.id,
      "trusted_realm_by_default" => true,
      "profile" => Map.get(command.actor, :profile, %{}),
      "metadata" => %{
        "guild_id" => command.guild_id,
        "discord_channel_id" => command.channel_id
      }
    }
  end

  defp command_account_input(%Source{} = source, command) do
    source
    |> root_init_account_input(command)
    |> Map.put("trusted_realm_by_default", source.trusted_realm_by_default)
  end

  defp maybe_ensure_command_actor(%Source{trusted_realm_by_default: true} = source, command) do
    case BullX.Principals.ensure_human_from_channel_actor(command_account_input(source, command)) do
      {:ok, _principal, _identity} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_ensure_command_actor(%Source{}, _command), do: :ok

  defp issue_login_auth_code(:ok, adapter, source_id, external_id) do
    BullX.Principals.issue_login_auth_code(adapter, source_id, external_id)
  end

  defp issue_login_auth_code({:error, reason}, _adapter, _source_id, _external_id),
    do: {:error, reason}

  defp root_init_reply({:ok, _principal, _identity}),
    do: BullX.I18n.t("im_gateway.discord.auth.root_init_success")

  defp root_init_reply({:error, :invalid_or_expired_code}),
    do: BullX.I18n.t("im_gateway.discord.auth.activation_code_invalid")

  defp root_init_reply({:error, :principal_disabled}),
    do: BullX.I18n.t("im_gateway.discord.auth.denied")

  defp root_init_reply({:error, _reason}),
    do: BullX.I18n.t("im_gateway.discord.auth.root_init_failed")

  defp webauth_reply({:ok, code}, login_url),
    do:
      BullX.I18n.t("im_gateway.discord.auth.webauth_created", %{code: code, login_url: login_url})

  defp webauth_reply({:error, :not_bound}, _login_url),
    do: BullX.I18n.t("im_gateway.discord.auth.webauth_not_bound")

  defp webauth_reply({:error, :identity_unverified}, _login_url),
    do: BullX.I18n.t("im_gateway.discord.auth.webauth_not_bound")

  defp webauth_reply({:error, :not_human}, _login_url),
    do: BullX.I18n.t("im_gateway.discord.auth.webauth_not_bound")

  defp webauth_reply({:error, :principal_disabled}, _login_url),
    do: BullX.I18n.t("im_gateway.discord.auth.denied")

  defp webauth_reply({:error, _reason}, _login_url),
    do: BullX.I18n.t("im_gateway.discord.auth.webauth_failed")
end
