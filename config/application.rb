require_relative 'boot'

require 'rails'
require 'active_model/railtie'
require 'action_controller/railtie'
require 'action_view/railtie'

Bundler.require(*Rails.groups)

# precedence: process env (systemd) > .env.local > .env.user > .env
Dotenv::Rails.files = %w[.env.local .env.user .env]

module MediaDownloaderBot
  class Application < Rails::Application
    config.load_defaults 8.1
    config.generators.system_tests = nil
  end
end
