defmodule BullXDiscord.LocaleTest do
  use ExUnit.Case, async: true

  @keys [
    "gateway.discord.auth.activation_required",
    "gateway.discord.auth.activation_success",
    "gateway.discord.auth.activation_code_invalid",
    "gateway.discord.auth.activation_failed",
    "gateway.discord.auth.already_linked",
    "gateway.discord.auth.web_auth_created",
    "gateway.discord.auth.web_auth_not_bound",
    "gateway.discord.auth.web_auth_disabled",
    "gateway.discord.auth.web_auth_failed",
    "gateway.discord.auth.login_not_bound",
    "gateway.discord.auth.denied",
    "gateway.discord.auth.direct_command_dm_only",
    "gateway.discord.ping.pong",
    "gateway.discord.ask.accepted",
    "gateway.discord.delivery.fallback_text",
    "gateway.discord.delivery.stream_generating",
    "gateway.discord.delivery.stream_failed",
    "gateway.discord.delivery.stream_cancelled",
    "gateway.discord.errors.unsupported_message",
    "gateway.discord.errors.profile_unavailable",
    "gateway.discord.errors.thread_create_failed"
  ]

  test "all Discord adapter keys exist in bundled locales" do
    for locale <- [:"en-US", :"zh-Hans-CN"], key <- @keys do
      assert {:ok, text} =
               BullX.I18n.translate(key, %{code: "CODE", login_url: "https://bullx.test"},
                 locale: locale
               )

      refute text == key
    end
  end
end
