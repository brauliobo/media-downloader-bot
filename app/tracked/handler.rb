module Tracked
  # What a kind of job knows: which items it has (`seed`), how to run one (`perform`) and, optionally, how to change an
  # outcome after the fact (`apply`). The engine owns scheduling, parallelism, state and resuming.
  class Handler
    PARALLEL = 1

    def parallel = self.class::PARALLEL

    # The job's own settings, cleaned up.
    def normalize(params) = params.to_h.deep_symbolize_keys

    # [{ key:, status: 'pending' | 'done' }] oldest first; items already known to the database are left as they are.
    def seed(job) = raise(NotImplementedError, "#{self.class} must implement seed")

    # Whether the job keeps running with nothing pending, for items added later.
    def standing?(job) = false

    # What an item is about (hash), recorded once as `result[:input]` before it runs so a pending item can be told apart;
    # nil when the kind has nothing to show.
    def describe(item) = nil

    # Called once for an item added after the job started, as soon as it is described: tells whoever sent it that it waits, or
    # returns the result that settles it at once (like `perform` would).
    def queued(item) = nil

    # Runs one claimed item and returns its result hash; raising fails the item.
    def perform(job, item) = raise(NotImplementedError, "#{self.class} must implement perform")

    # The reason the result counts as a failure, nil when it succeeded.
    def error_of(result) = nil

    # Pushes the edited result of a finished item to wherever it was published.
    def apply(item) = raise(NotImplementedError, "#{self.class} cannot apply changes")

    # Makes again the hashtags a finished item lost, and publishes them like `apply`.
    def retag(item) = raise(NotImplementedError, "#{self.class} cannot retag")

    # Removes a message the job sent (a JobMessage) from where it was sent.
    def delete_message(message) = raise(NotImplementedError, "#{self.class} cannot delete messages")
  end
end
