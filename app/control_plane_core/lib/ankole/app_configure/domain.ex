defmodule Ankole.AppConfigure.Domain do
  @moduledoc "Durable site and tenant configuration values."
  use Ash.Domain

  resources do
    resource(Ankole.AppConfigure.AppConfig)
    resource(Ankole.AppConfigure.SiteConfig)
  end
end
