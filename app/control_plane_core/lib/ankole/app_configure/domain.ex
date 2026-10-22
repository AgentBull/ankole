defmodule Ankole.AppConfigure.Domain do
  @moduledoc "Durable site and tenant configuration values."
  use Ankole.Ash.Domain

  resources do
    resource Ankole.AppConfigure.AppConfig do
      define(:get_app_config, action: :read, get_by: [:scope, :key], not_found_error?: false)
      define(:list_app_configs, action: :read)
      define(:put_app_config, action: :put)
      define(:import_envelope_app_config, action: :import_envelope)
      define(:record_platform_application_app_config, action: :record_platform_application)
      define(:remove_app_config, action: :remove)
    end

    resource Ankole.AppConfigure.SiteConfig do
      define(:get_site_config, action: :read, get_by: [:scope, :key], not_found_error?: false)
      define(:list_site_configs, action: :read)
      define(:put_site_config, action: :put)
      define(:record_platform_application_site_config, action: :record_platform_application)
      define(:remove_site_config, action: :remove)
    end
  end
end
