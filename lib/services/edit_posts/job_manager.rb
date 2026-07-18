require 'concurrent-ruby'
require 'fileutils'
require 'securerandom'
require 'time'
require_relative '../edit_posts'

module Services
  class EditPosts
    class JobManager
      def initialize(manager, concurrency: ENV.fetch('EDIT_POST_JOBS', 2).to_i, root: File.join(Dir.pwd, 'log', 'edit_posts_jobs'), runner: Services::EditPosts)
        @manager = manager
        @root    = root
        @runner  = runner
        @jobs    = {}
        @mutex   = Mutex.new
        @pool    = Concurrent::FixedThreadPool.new([concurrency, 1].max)
        FileUtils.mkdir_p(@root)
      end

      def start(args)
        id  = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4)}"
        job = {
          id:         id,
          state:      'queued',
          args:       normalize_args(args),
          log_path:   File.join(@root, "#{id}.log"),
          created_at: Time.now.iso8601
        }
        @mutex.synchronize { @jobs[id] = job }
        @pool.post { run(job) }
        snapshot(job)
      end

      def fetch(id)
        job = @mutex.synchronize { @jobs[id.to_s] }
        snapshot(job) if job
      end

      def list
        @mutex.synchronize { @jobs.values.map { |job| snapshot(job) } }
      end

      def log(id, lines: 100)
        job = @mutex.synchronize { @jobs[id.to_s] }
        return unless job && File.exist?(job[:log_path])

        limit = lines.to_i.clamp(1, 1_000)
        tail  = []
        File.foreach(job[:log_path]) do |line|
          tail << line
          tail.shift if tail.size > limit
        end
        tail.join
      end

      private

      def run(job)
        update(job, state: 'running', started_at: Time.now.iso8601)
        File.open(job[:log_path], 'a') do |log|
          log.sync = true
          @runner.new(job[:args], manager: @manager, output: log).run
        end
        update(job, state: 'completed', finished_at: Time.now.iso8601)
      rescue => error
        File.open(job[:log_path], 'a') { |log| log.puts error.full_message }
        update(job, state: 'failed', error: "#{error.class}: #{error.message}", finished_at: Time.now.iso8601)
      end

      def normalize_args(args)
        return args.map(&:to_s) if args.is_a?(Array)
        return args.map { |key, value| value == true ? key.to_s : "#{key}=#{value}" } if args.is_a?(Hash)

        raise ArgumentError, 'edit post job arguments must be an Array or Hash'
      end

      def update(job, values)
        @mutex.synchronize { job.merge!(values) }
      end

      def snapshot(job)
        job&.dup
      end
    end
  end
end
