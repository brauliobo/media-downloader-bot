module Api
  # The messages sent for job items, by chat and message id, so they can be found and removed later.
  class JobMessagesController < BaseController
    def index
      scope = JobMessage.reverse_order(:id).limit(params.fetch(:limit, 100).to_i)
      scope = scope.where(job_item_id: params[:job_item_id]) if params[:job_item_id].present?
      scope = scope.where(failed: true) if params[:failed] == 'true'
      scope = scope.live unless params[:deleted] == 'true'
      render json: scope.map(&:to_api)
    end

    def destroy = render(json: manager.tracked_delete_message(JobMessage.with_pk!(params[:id]).id))
  end
end
