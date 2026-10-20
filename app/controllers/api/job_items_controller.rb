module Api
  # The items of the jobs with their outcome and the messages sent for them; failed ones can be retried and the hashtags edited.
  # A running item is stalled when nothing was edited in its status for STALLED_AFTER: its worker hangs or died with it.
  class JobItemsController < BaseController
    STALLED_AFTER = 10.minutes

    def index
      scope = JobItem.eager(:messages).reverse_order(:id).limit(params.fetch(:limit, 100).to_i)
      scope = scope.where(job_id: params[:job_id]) if params[:job_id].present?
      scope = filtered(scope, params[:status]) if params[:status].present?
      items = with_activity(scope.all)
      render json: (params[:status] == 'stalled' ? items.select { |item| item[:stalled] } : items)
    end

    def show = render(json: item.to_api)

    def update = render(json: manager.tracked_edit(item.id, params.require(:job_item).permit(:hashtags).to_h))

    def apply = render(json: manager.tracked_apply(item.id))

    def retag = render(json: manager.tracked_retag(item.id))

    # The books of the job posted without the hashtags they asked for; they are made in the background.
    def retag_untagged
      ids = JobItem.untagged.where(job_id: params.require(:job_id)).select_map(:id)
      render json: { retagging: manager.tracked_retag_items(ids) }
    end

    def retry
      render json: { retried: manager.tracked_retry_items([item.id], discard: params[:discard] == 'true') }
    end

    def retry_failed
      ids = JobItem.failed.where(job_id: params.require(:job_id)).select_map(:id)
      render json: { retried: manager.tracked_retry_items(ids) }
    end

    private

    def item = @item ||= JobItem.with_pk!(params[:id])

    # `stalled` are the running ones to be judged by their activity, `untagged` the done ones that lost their hashtags.
    def filtered(scope, status)
      return scope.untagged if status == 'untagged'

      scope.where(status: status == 'stalled' ? 'running' : status)
    end

    # `active_at`: the last sign of life of a running item, the last edit of its status or else when it was claimed.
    def with_activity(items)
      beats = BotJob.where(key: items.select { |i| i.status == 'running' }.map(&:key)).to_hash(:key, :updated_at)
      items.map do |i|
        active_at = (beats[i.key] || i.claimed_at if i.status == 'running')
        i.to_api.merge(active_at: active_at, stalled: !!(active_at && active_at < STALLED_AFTER.ago))
      end
    end
  end
end
