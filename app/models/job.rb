Sequel::Model.db.extension :pg_json

# A resumable run of some kind of work (e.g. replay): what it has to do lives in its job_items, so a restart or a stop
# only pauses it. `params` are the kind's own settings; `parallel` is how many items may be in flight and can change while it runs.
class Job < Sequel::Model(:jobs)
  STATES = %w[queued running stopping stopped completed failed].freeze

  plugin :timestamps, update_on_create: true

  one_to_many :items, class: :JobItem

  dataset_module do
    def unfinished = where(state: %w[queued running stopping])
  end

  def options = params.to_h.deep_symbolize_keys

  def counts = JobItem.where(job_id: id).group_and_count(:status).to_h { |row| [row[:status], row[:count]] }

  def to_api = values.merge(params: params.to_h, counts: counts)
end
