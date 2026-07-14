defmodule Ankole.Plugins.LarkAdapter.CardKit.I18n do
  @moduledoc false

  alias Ankole.I18n, as: AnkoleI18n

  @provider_locales %{
    "zh_cn" => "zh-Hans-CN",
    "en_us" => "en-US"
  }

  @spec text(String.t(), map()) :: map()
  def text(key, bindings \\ %{}) do
    i18n_content =
      Map.new(@provider_locales, fn {provider_locale, ankole_locale} ->
        {provider_locale,
         AnkoleI18n.t("signals_gateway.cardkit.#{key}", bindings, locale: ankole_locale)}
      end)

    %{
      "content" => AnkoleI18n.t("signals_gateway.cardkit.#{key}", bindings),
      "i18n_content" => i18n_content
    }
  end

  @spec plain_text(String.t(), map()) :: map()
  def plain_text(key, bindings \\ %{}) do
    Map.put(text(key, bindings), "tag", "plain_text")
  end
end
