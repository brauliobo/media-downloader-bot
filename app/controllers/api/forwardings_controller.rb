module Api
  class ForwardingsController < BaseController
    def index = render(json: manager.forwarding_jobs.reverse)

    def show
      job = manager.forwarding_job(params[:id])
      job ? render(json: job) : head(:not_found)
    end

    def create
      render json: manager.start_forwarding(forwarding_params), status: :accepted
    end

    private

    def forwarding_params
      params.require(:forwarding).permit(:filter, :caption, :leave, source: %i[chat_id topic_id], target: %i[chat_id topic_id]).to_h
    end
  end
end
