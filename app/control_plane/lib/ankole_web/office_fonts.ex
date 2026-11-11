defmodule AnkoleWeb.OfficeFonts do
  @moduledoc """
  Resolves the directory backing `/fonts/office/` so browser Office Workers and
  the control-plane kernel read the same site font set.
  """

  @default_dir "/usr/share/ankole/fonts"

  @spec directory() :: String.t()
  def directory do
    configured =
      case System.get_env("ANKOLE_OFFICE_FONTS_DIR") do
        nil -> @default_dir
        raw -> String.trim(raw)
      end

    if configured != "" and File.exists?(Path.join(configured, "manifest.json")) do
      configured
    else
      Application.app_dir(:ankole, "priv/static/fonts/office")
    end
  end
end
