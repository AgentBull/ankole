defmodule AnkoleWeb.OfficeFonts do
  @moduledoc """
  Resolves the directory backing `/fonts/office/` so browser Office Workers and
  the control-plane kernel read the same site font set.
  """

  @default_dir "/usr/share/ankole/fonts"
  @local_dir Path.expand("../../../../var/office-fonts", __DIR__)

  @spec directory() :: String.t()
  def directory do
    configured =
      case System.get_env("ANKOLE_OFFICE_FONTS_DIR") do
        nil -> @default_dir
        raw -> String.trim(raw)
      end

    cond do
      configured != "" and File.exists?(Path.join(configured, "manifest.json")) ->
        configured

      File.exists?(Path.join(@local_dir, "manifest.json")) ->
        @local_dir

      true ->
        Application.app_dir(:ankole, "priv/static/fonts/office")
    end
  end
end
