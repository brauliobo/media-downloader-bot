module Api
  # Rules that copy every incoming message of a source chat/topic to a target chat/topic.
  class RelayRulesController < BaseController
    def index = render(json: RelayRule.order(:id).map(&:values))

    def create
      render json: RelayRule.create(rule_params).values, status: :created
    end

    def update
      render json: rule.update(rule_params).values
    end

    def destroy
      render json: rule.destroy.values
    end

    private

    def rule = @rule ||= RelayRule.with_pk!(params[:id])

    def rule_params
      params.require(:relay_rule).permit(:source_chat_id, :source_topic_id, :source_title, :target_chat_id, :target_topic_id, :target_title,
                                         :filter, :caption, :enabled).to_h
    end
  end
end
