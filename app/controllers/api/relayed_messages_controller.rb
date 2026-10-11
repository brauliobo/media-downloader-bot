module Api
  # Every relay attempt with its status, error and links to the source and destination messages.
  class RelayedMessagesController < BaseController
    def index
      scope = RelayedMessage.reverse_order(:id).limit(params.fetch(:limit, 100).to_i)
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(relay_rule_id: params[:relay_rule_id]) if params[:relay_rule_id].present?
      render json: scope.map(&:to_api)
    end

    def show = render(json: message.to_api)

    def retry
      manager.retry_relay(message.id)
      render json: message.refresh.to_api
    end

    def retry_failed
      render json: { retried: manager.retry_failed_relays }
    end

    private

    def message = @message ||= RelayedMessage.with_pk!(params[:id])
  end
end
