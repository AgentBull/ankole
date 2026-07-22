defmodule Ankole.Brain.SourceConnector do
  @moduledoc """
  Contract between an external document source and Brain source synchronization.

  A connector reports availability, returns the current revision, and exports
  one current Markdown document. Polling, comparison, chunking, replacement,
  and withdrawal stay in the control plane.
  """

  @type source_ref :: %{
          required(:connector_id) => String.t(),
          required(:locator) => String.t()
        }

  @type availability :: :available | :deleted | :access_lost
  @type export :: %{
          required(:title) => String.t(),
          required(:markdown) => String.t(),
          optional(:url) => String.t() | nil
        }

  @callback availability(source_ref()) :: {:ok, availability()} | {:error, term()}
  @callback revision(source_ref()) :: {:ok, String.t()} | {:error, term()}
  @callback export(source_ref()) :: {:ok, export()} | {:error, term()}
end
