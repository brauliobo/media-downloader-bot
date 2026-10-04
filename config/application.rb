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
    # domains live directly in app/<domain>: app itself is the root so the folder is the namespace, and only the
    # Rails conventional dirs stay nested roots (the default app/* glob would turn each domain into its own root)
    config.paths['app'].glob = '{controllers,helpers,models}'
    config.autoload_paths << Rails.root.join('app')
    config.eager_load_paths << Rails.root.join('app')
    config.generators.system_tests = nil
  end
end
