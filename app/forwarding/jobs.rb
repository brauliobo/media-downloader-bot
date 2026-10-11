module Forwarding
  # Runs forwardings one at a time (Telegram rate limits make parallel runs pointless) and exposes their progress.
  class Jobs < BackgroundJobs
    OPTIONS = %i[source target filter caption leave].freeze

    def initialize(bot_provider, log: Log.new)
      super()
      @bot_provider = bot_provider
      @log          = log
    end

    private

    def execute(job, &progress) = Runner.new(@bot_provider.call, log: @log).run(**job.slice(*OPTIONS), &progress)

    def normalize(params)
      { source: chat_ref(params.fetch(:source)), target: chat_ref(params.fetch(:target)), filter: params[:filter].presence || 'document',
        caption: params[:caption].presence, leave: flag(params[:leave]) }
    end

    def chat_ref(ref) = { chat_id: Integer(ref.fetch(:chat_id)), topic_id: (ref[:topic_id].to_i if ref[:topic_id].to_i.positive?) }
  end
end
