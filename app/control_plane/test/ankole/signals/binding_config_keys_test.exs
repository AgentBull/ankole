defmodule Ankole.Signals.BindingConfigKeysTest do
  use ExUnit.Case, async: true

  test "adapter keys preserve their stored prefixes and digest bytes" do
    suffix = "8fb28a94faa465882a3901241de150f6b1b5d5bfac487f8ede93f902cfcd7135"

    for {adapter, prefix} <- [
          {Ankole.Plugins.DiscordAdapter.Config, "signals.discord.bindings"},
          {Ankole.Plugins.EmailAdapter.Config, "signals.email.bindings"},
          {Ankole.Plugins.LarkAdapter.Config, "signals.lark.binding_configs"},
          {Ankole.Plugins.LineAdapter.Config, "signals.line.bindings"},
          {Ankole.Plugins.Microsoft365Adapter.Config, "signals.teams.bindings"},
          {Ankole.Plugins.SlackAdapter.Config, "signals.slack.bindings"},
          {Ankole.Plugins.TelegramAdapter.Config, "signals.telegram.bindings"},
          {Ankole.Plugins.WhatsAppAdapter.Config, "signals.whatsapp.bindings"}
        ] do
      assert adapter.binding_config_key("agent", "binding") == prefix <> "." <> suffix
    end
  end
end
