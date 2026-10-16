# A message the bot sent for a job item (a book, an error, ...), kept with its id so it can be listed, deleted or re-captioned later.
# `hashtags` are the ones currently in its caption.
class JobMessage < Sequel::Model(:job_messages)
  plugin :timestamps, update_on_create: true

  many_to_one :job_item

  dataset_module do
    def live = where(deleted_at: nil)
    def failures = where(failed: true)
    def media = exclude(kind: 'Text')
  end

  def deleted! = update(deleted_at: Time.now)

  def to_api = values
end
