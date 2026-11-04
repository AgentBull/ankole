defmodule Ankole.Plugins.CloudConnectorsAdapter do
  @moduledoc "Ankole-owned tool and event contracts for cloud-backed business platforms."
  @behaviour Ankole.Plugins.Plugin
  alias Ankole.Plugins.CloudConnectorsAdapter.Definitions

  def plugin_id, do: "cloud-connectors-adapter"
  def activation, do: :always
  def display_name, do: %{"default" => "Cloud connectors"}
  def description, do: %{"default" => "Business application tools and event subscriptions."}
  def adapter_declarations, do: Definitions.declarations()
end
