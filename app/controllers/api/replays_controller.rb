module Api
  # Feeds the messages already copied into a group back to the bot as if they were freshly received.
  class ReplaysController < BaseController
    def index = render(json: manager.replay_jobs.reverse)

    def show
      job = manager.replay_job(params[:id])
      job ? render(json: job) : head(:not_found)
    end

    def create
      render json: manager.start_replay(replay_params), status: :accepted
    end

    def stop
      manager.stop_replay(params[:id])
      show
    end

    private

    def replay_params = params.require(:replay).permit(:chat_id, :parallel, :plan, :recover).to_h
  end
end
