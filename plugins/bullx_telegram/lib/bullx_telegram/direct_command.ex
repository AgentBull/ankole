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

  defp run(%Source{} = source, %{name: "root_init"} = command, opts) do
    case BullX.AuthZ.ensure_root_init_open() do
      :ok -> run_root_init_open(source, command, opts)
      {:error, :root_init_closed} -> {:ok, %{"command_name" => "root_init", "status" => "ignored"}}
    end
  end

  defp run(%Source{} = source, %{name: "webauth", chat_type: chat_type} = command, opts)
       when chat_type != "private" do
    reply_text(
      command,
      source,
      BullX.I18n.t("im_gateway.telegram.auth.direct_command_dm_only"),
      "webauth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "webauth"} = command, opts)
       when source.web_login_disabled? do
    reply_text(
      command,
      source,
      BullX.I18n.t("im_gateway.telegram.auth.webauth_disabled"),
      "webauth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "webauth"} = command, opts) do
    text =
      source
      |> maybe_ensure_command_actor(command)
      |> issue_login_auth_code("telegram", source.id, command.actor.id)
      |> webauth_reply(BullX.Principals.web_login_url())

    reply_text(command, source, text, "webauth", opts)
  end

  defp run(%Source{} = source, command, opts) do
    reply_text(
      command,
      source,
      BullX.I18n.t("im_gateway.telegram.errors.unsupported_message"),
      command.name,
      opts
    )
  end

  defp run_root_init_open(%Source{} = source, %{chat_type: chat_type} = command, opts)
       when chat_type != "private" do
    reply_text(
      command,
      source,
      BullX.I18n.t("im_gateway.telegram.auth.direct_command_dm_only"),
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
      "adapter" => "telegram",
      "channel_id" => source.id,
      "external_id" => command.actor.id,
      "trusted_realm_by_default" => true,
      "profile" => Map.get(command.actor, :profile, %{}),
      "metadata" => %{
        "chat_id" => command.chat_id,
        "chat_type" => command.chat_type,
        "thread_id" => command.thread_id
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
    do: BullX.I18n.t("im_gateway.telegram.auth.root_init_success")

  defp root_init_reply({:error, :invalid_or_expired_code}),
    do: BullX.I18n.t("im_gateway.telegram.auth.activation_code_invalid")

  defp root_init_reply({:error, :principal_disabled}),
    do: BullX.I18n.t("im_gateway.telegram.auth.denied")

  defp root_init_reply({:error, _reason}),
    do: BullX.I18n.t("im_gateway.telegram.auth.root_init_failed")

  defp webauth_reply({:ok, code}, login_url),
    do:
      BullX.I18n.t("im_gateway.telegram.auth.webauth_created", %{code: code, login_url: login_url})

  defp webauth_reply({:error, :not_bound}, _login_url),
    do: BullX.I18n.t("im_gateway.telegram.auth.webauth_not_bound")

  defp webauth_reply({:error, :identity_unverified}, _login_url),
    do: BullX.I18n.t("im_gateway.telegram.auth.webauth_not_bound")

  defp webauth_reply({:error, :not_human}, _login_url),
    do: BullX.I18n.t("im_gateway.telegram.auth.webauth_not_bound")

  defp webauth_reply({:error, :principal_disabled}, _login_url),
    do: BullX.I18n.t("im_gateway.telegram.auth.denied")

  defp webauth_reply({:error, _reason}, _login_url),
    do: BullX.I18n.t("im_gateway.telegram.auth.webauth_failed")
end
