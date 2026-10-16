module Replay
  # The queue of a managed group: a replay job that follows its chat. What is posted there joins it and waits for its slots
  # (`parallel`) instead of running beside it; while the job is paused the messages stay in line.
  module GroupQueue
    # The replay jobs of the chat, newest first.
    def self.jobs(chat_id) = Job.where(kind: 'replay').reverse_order(:id).all.select { |job| job.options[:chat_id] == chat_id }

    def self.job_for(chat_id) = jobs(chat_id).find { |job| job.options[:follow] }
  end
end
