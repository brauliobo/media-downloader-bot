module Api
  # The items of the jobs with their outcome and the messages sent for them; failed ones can be retried and the hashtags edited.
  class JobItemsController < BaseController
    def index
      scope = JobItem.eager(:messages).reverse_order(:id).limit(params.fetch(:limit, 100).to_i)
      scope = scope.where(job_id: params[:job_id]) if params[:job_id].present?
      scope = scope.where(status: params[:status]) if params[:status].present?
      render json: scope.map(&:to_api)
    end

    def show = render(json: item.to_api)

    def update = render(json: manager.tracked_edit(item.id, params.require(:job_item).permit(:hashtags).to_h))

    def apply = render(json: manager.tracked_apply(item.id))

    def retry
      render json: { retried: manager.tracked_retry_items([item.id], discard: params[:discard] == 'true') }
    end

    def retry_failed
      ids = JobItem.failed.where(job_id: params.require(:job_id)).select_map(:id)
      render json: { retried: manager.tracked_retry_items(ids) }
    end

    private

    def item = @item ||= JobItem.with_pk!(params[:id])
  end
end
