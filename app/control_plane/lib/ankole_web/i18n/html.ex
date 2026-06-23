defmodule AnkoleWeb.I18n.HTML do
  @moduledoc """
  Template translation helpers backed by `Ankole.I18n`.

  These helpers are intentionally thin. The current product model uses the
  installation default locale for server-rendered UI, so templates do not need a
  per-request locale assign to translate common text.
  """

  @doc """
  Translates a template key with no bindings.
  """
  @spec t(String.t()) :: String.t()
  def t(key), do: Ankole.I18n.t(key, %{}, [])

  @doc """
  Translates a template key with MF2 bindings.
  """
  @spec t(String.t(), Ankole.I18n.bindings()) :: String.t()
  def t(key, bindings), do: Ankole.I18n.t(key, bindings, [])

  @doc """
  Translates a template key with bindings and explicit I18n options.

  This keeps templates close to the public `Ankole.I18n.t/3` contract while still
  giving template imports a concise helper name.
  """
  @spec t(String.t(), Ankole.I18n.bindings(), Ankole.I18n.opts()) :: String.t()
  def t(key, bindings, opts), do: Ankole.I18n.t(key, bindings, opts)

  @doc """
  Returns the active BCP 47 locale for the root `<html lang>` attribute.

  The value is resolved back to a loaded Ankole catalog id so HTML reflects what
  the server can actually render.
  """
  @spec lang() :: String.t()
  def lang do
    Ankole.I18n.default_locale()
    |> Ankole.I18n.Resolver.language_tag_to_locale()
  end

  @doc """
  Returns the writing direction for the active locale.

  The currently shipped catalogs are left-to-right. Keeping one helper here gives
  templates a single place to change when an RTL locale is added.
  """
  @spec dir() :: String.t()
  def dir, do: "ltr"
end
