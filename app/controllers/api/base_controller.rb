module Api
  # JSON API over the running bot's manager; every call needs the same BOT_HTTP_TOKEN as the bot HTTP service.
  class BaseController < ActionController::API
    before_action :authorize!
    rescue_from(Sequel::NoMatchingRow) { head :not_found }

    private

    def manager = Rails.application.config.x.manager

    def authorize!
      token = ENV['BOT_HTTP_TOKEN'].to_s
      given = request.authorization.to_s.delete_prefix('Bearer ')
      head :unauthorized if token.empty? || !ActiveSupport::SecurityUtils.secure_compare(given, token)
    end
  end
end
