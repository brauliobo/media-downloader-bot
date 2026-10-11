Sequel::Model.db.extension :pg_json

# One message of a source chat on its way to the target of a relay rule: pending until copied, then sent or failed.
class RelayedMessage < Sequel::Model(:relayed_messages)
  STATUSES = %w[pending sent failed].freeze

  plugin :timestamps, update_on_create: true

  many_to_one :relay_rule

  dataset_module do
    STATUSES.each { |status| define_method(status) { where(status: status) } }

    def stale_pending(age) = pending.where(Sequel[:updated_at] < Time.now - age)

    def retryable(max_attempts) = failed.where(Sequel[:attempts] < max_attempts)
  end

  def to_api = values.merge(content: content.to_h, **relay_rule.values.slice(:source_title, :target_title))
end
