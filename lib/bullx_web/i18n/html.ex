defmodule BullXWeb.I18n.HTML do
  @moduledoc """
  HEEx/EEx translation helpers.

  Imported into every `BullXWeb.html/0`-using module (controllers,
  LiveViews, components). Forwards directly to `BullX.I18n.t/3`;
  no separate HEEx-specific behavior.

  Locale is read from the application-global default — templates do
  NOT need a `locale` assign. RFC 0007 §8.

  """

  @doc "See `BullX.I18n.t/3`."
  @spec t(String.t()) :: String.t()
  def t(key), do: BullX.I18n.t(key, %{}, [])

  @spec t(String.t(), BullX.I18n.bindings()) :: String.t()
  def t(key, bindings), do: BullX.I18n.t(key, bindings, [])

  @spec t(String.t(), BullX.I18n.bindings(), BullX.I18n.opts()) :: String.t()
  def t(key, bindings, opts), do: BullX.I18n.t(key, bindings, opts)

  @doc """
  Returns the active BCP 47 locale for the root `<html lang>` attribute.
  """
  @spec lang() :: String.t()
  def lang do
    BullX.I18n.default_locale()
    |> BullX.I18n.Resolver.language_tag_to_locale()
    |> Atom.to_string()
  end

  @doc """
  Returns the writing direction for the active locale.

  BullX currently ships only LTR locales. This helper is the single
  hook point for the first RTL locale.
  """
  @spec dir() :: String.t()
  def dir, do: "ltr"
end
