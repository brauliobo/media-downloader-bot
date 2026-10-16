Sequel::Model.db.extension :pg_json

# One unit of a job, unique by kind and key: pending until a worker claims it, then done or failed. `result` is what the kind
# records about the outcome (for a replay: the options used and the hashtags wanted); the messages sent for it are JobMessages.
class JobItem < Sequel::Model(:job_items)
  STATUSES = %w[pending running done failed].freeze

  plugin :timestamps, update_on_create: true

  many_to_one :job
  one_to_many :messages, class: :JobMessage

  dataset_module do
    STATUSES.each { |status| define_method(status) { where(status: status) } }

    # Takes the oldest pending item of the job, atomically so that concurrent workers never share one.
    def claim(job_id)
      pending = model.where(job_id: job_id, status: 'pending').order(:id).limit(1).for_update.skip_locked.select(:id)
      id      = where(id: pending).returning(:id).update(status: 'running', claimed_at: Time.now, attempts: Sequel[:attempts] + 1, updated_at: Time.now).first&.fetch(:id)
      model[id] if id
    end
  end

  def outcome = result.to_h.deep_symbolize_keys

  # Keeps the messages sent for the item; a message seen again is updated in place.
  def record_messages(messages)
    messages.each do |message|
      JobMessage.dataset.insert_conflict(target: %i[chat_id message_id], update: message.merge(job_item_id: id, updated_at: Time.now)).insert(message.merge(job_item_id: id))
    end
  end

  def to_api = values.merge(result: result.to_h, messages: messages.map(&:to_api))
end
