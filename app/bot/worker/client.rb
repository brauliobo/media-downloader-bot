require 'drb/drb'
require 'faraday'

module Bot
  module Worker
    # The bot as a worker sees it, reached by DRb or HTTP according to the service's address. While the bot is not there (a
    # deploy restarts it) every call waits for it with a growing pause, so the work in flight goes on and its messages are sent
    # as soon as the bot is back.
    class Client
      include MsgHelpers

      TRANSPORTS  = { 'druby' => DRbTransport, 'http' => HTTPTransport, 'https' => HTTPTransport }.freeze
      UNREACHABLE = [Faraday::ConnectionFailed, DRb::DRbConnError, Errno::ECONNREFUSED].freeze
      RETRIES     = Integer(ENV.fetch('MANAGER_RETRIES', 120))
      PAUSE_MAX   = 30

      def initialize(uri)
        @transport = TRANSPORTS.fetch(URI.parse(uri).scheme) { raise ArgumentError, "Unsupported URI scheme: #{uri}" }.new(uri)
      end

      def send_message(msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params)
        result = call(:send_message, msg: msg, text: text, type: type, parse_mode: parse_mode, delete: delete, delete_both: delete_both, **params)
        result.is_a?(Hash) ? SymMash.new(result) : result
      end

      def send_album(msg, text, uploads:, parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params)
        AlbumProxy.stage(uploads) do |staged|
          messages = call(:send_album, result: :messages, msg: msg, text: text, uploads: staged, parse_mode: parse_mode,
                                       delete: delete, delete_both: delete_both, **params)
          Array(messages).map { |message| SymMash.new(message) }
        end
      end

      def edit_message(msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', **params)
        call(:edit_message, result: :success, msg: msg, id: id, text: text, type: type, parse_mode: parse_mode, **params)
      end

      def delete_message(msg, id, wait: nil) = call(:delete_message, msg: msg, id: id, wait: wait)

      def download_file(file_id_or_info, priority: 32, offset: 0, limit: 0, synchronous: true, dir: nil)
        call(:download_file, result: :path, file_id_or_info: file_id_or_info, priority: priority, offset: offset,
                             limit: limit, synchronous: synchronous, dir: dir)
      end

      def report_error(msg, e, context: nil)
        call(:report_error, msg: msg, e: e.to_s, error_class: e.class.name, context: context)
      end

      def max_caption
        @max_caption ||= call(:max_caption, result: :max_caption)
      rescue
        self.class.max_caption
      end

      def job_cancelled?(id) = call(:job_cancelled, result: :cancelled, id: id)
      def finish_job(id) = call(:finish_job, id: id)
      def queue_name = call(:queue_name, result: :queue)
      def size_mb_limit = call(:size_mb_limit, result: :size_mb_limit)

      private

      # Only an unreachable bot is retried: the call never reached it, so it cannot be done twice.
      def call(method, **kwargs)
        attempts = 0
        begin
          @transport.call(method, **kwargs)
        rescue *UNREACHABLE => e
          raise if (attempts += 1) > RETRIES

          warn "bot unreachable (#{e.class}), retrying #{method} in #{pause = [0.5 * 2**attempts, PAUSE_MAX].min}s"
          sleep pause
          retry
        end
      end
    end
  end
end
