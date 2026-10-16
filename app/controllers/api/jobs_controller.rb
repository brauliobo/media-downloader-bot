module Api
  # Resumable jobs (e.g. replays): read from the database, controlled through the running bot's engine.
  class JobsController < BaseController
    def index
      scope = Job.reverse_order(:id).limit(params.fetch(:limit, 50).to_i)
      scope = scope.where(kind: params[:kind]) if params[:kind].present?
      render json: scope.map(&:to_api)
    end

    def show = render(json: job.to_api)

    def create
      render json: manager.tracked_start(**create_params), status: :accepted
    end

    def update
      render json: manager.tracked_update(job.id, **update_params)
    end

    def stop = render(json: manager.tracked_stop(job.id))

    def resume = render(json: manager.tracked_resume(job.id))

    private

    def job = @job ||= Job.with_pk!(params[:id])

    def create_params = params.require(:job).permit(:kind, :parallel, params: {}).to_h.symbolize_keys

    def update_params = params.require(:job).permit(:parallel, params: {}).to_h.symbolize_keys
  end
end
