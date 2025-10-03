require 'puma'
require 'roda'
require 'limiter'
require_relative '../bot/rate_limiter'

class TlBot
  module Helpers

    extend ActiveSupport::Concern
    include MsgHelpers
    include Bot::RateLimiter

    RETRY_ERRORS = [
      Faraday::ConnectionFailed,
      Faraday::TimeoutError,
      Net::OpenTimeout, Net::WriteTimeout,
    ]

    included do
      class_attribute :bot_name
      class_attribute :error_delete_time
      self.error_delete_time = 30.seconds

      rate_limits global: 20, per_chat: 1

      def self.mock
        define_method :send_message do |msg, text, *args|
          puts text
          SymMash.new result: {message_id: 1}, text: text
        end
        define_method :edit_message do |msg, id, text: nil, **params|
          puts text
        end
        define_method :delete_message do |msg, id, text: nil, **params|
          puts "deleting #{id}"
        end
        define_method :report_error do |msg, e, context: nil|
          raise e
        end
      end
    end

    class WebApp < Roda
       plugin :indifferent_params
       route do |r|
          r.on 'admin_message' do
            r.post do
              ret = $bot.send_message $bot.admin_msg, r.params[:m], **r.params.to_h.symbolize_keys
              ret.to_h.to_json
            end
          end
       end
    end

    def start_webserver socket: "/tmp/#{bot_name}.socket"
      server = Puma::Server.new WebApp.freeze.app, Puma::Events.strings
      server.add_unix_listener socket
      puts "Server listening at #{socket}"
      server.run
      [:INT, :TERM].each { |sig| trap(sig) { server.stop } }
    end

    ADMIN_CHAT_ID  = ENV['ADMIN_CHAT_ID']&.to_i
    REPORT_CHAT_ID = ENV['REPORT_CHAT_ID']&.to_i

    def net_up?
      Net::HTTP.new('www.google.com').head('/').kind_of? Net::HTTPOK
    end
    def wait_net_up
      sleep 1 until net_up?
    end

    def retry_after_seconds(e)
      (e.message[/retry after (\d+)/, 1]&.to_i).presence || begin
        body = JSON.parse(e.response.body) rescue nil
        body && body.dig('parameters', 'retry_after')
      end.to_i
    end

    def tg_text_payload msg, text, parse_mode
      t = parse_text text, parse_mode: parse_mode
      { chat_id: msg.chat.id, text: t, caption: t, parse_mode: parse_mode }
    end

    def edit_message msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', **params
      throttle! msg.chat.id, :low
      api.send "edit_message_#{type}", **tg_text_payload(msg, text, parse_mode), message_id: id, **params

    rescue ::Telegram::Bot::Exceptions::ResponseError => e
      resp = SymMash.new(JSON.parse(e.response.body)) rescue nil
      return if resp&.description&.match(/exactly the same as a current content/)
      if (ra = retry_after_seconds(e)) > 0 then sleep ra; retry end
      raise
    rescue
      # ignore
    end

    class ::Telegram::Bot::Types::Message
      attr_accessor :resp
    end

    def send_message msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params
      _text = text
      throttle! msg.chat.id, :high
      resp  = SymMash.new api.send("send_#{type}", **tg_text_payload(msg, text, parse_mode), reply_to_message_id: msg.message_id, **params).to_h
      resp.text = _text

      delete = delete_both if delete_both
      delete_message msg, resp.message_id, wait: delete if delete
      delete_message msg, msg.message_id, wait: delete_both if delete_both

      resp
    rescue *RETRY_ERRORS
      retry
    rescue ::Telegram::Bot::Exceptions::ResponseError => e
      if (ra = retry_after_seconds(e)) > 0 then sleep ra; retry end
      raise
    rescue => e
      retry if e.message.index 'Internal Server Error'
      binding.pry if ENV['PRY_SEND_MESSAGE']
      raise "#{e.class}: #{e.message}, msg: #{text}"
    end

    def delete_message msg, id, wait: 30.seconds
      Thread.new do
        sleep wait if wait
      ensure
        api.delete_message chat_id: msg.chat.id, message_id: id
      end
    end

    def report_error msg, e, context: nil
      return unless msg

      if e.is_a? StandardError
        error  = ''
        error << "\n\n<b>context</b>: #{he(context).first(100)}" if context
        error << "\n\n<b>error</b>: <pre>#{e.class}: #{he e.message}\n"
        error << "#{he clean_bc(e.backtrace).join "\n"}</pre>"
      else
        error  = e.to_s
      end

      STDERR.puts "error: #{error}"
      send_message msg, error, parse_mode: 'HTML', delete_both: error_delete_time
      admin_report msg, error unless from_admin? msg
    rescue
      send_message msg, he(error), parse_mode: 'HTML', delete_both: error_delete_time
    end

    def clean_bc bc
      @bcl ||= ActiveSupport::BacktraceCleaner.new.tap { |c| c.add_filter { |line| line.gsub "#{Dir.pwd}/", '' } }
      @bcl.clean bc
    end

    def admin_report msg, _error, status: 'error'
      return unless ADMIN_CHAT_ID
      msg_ct = if msg.respond_to? :text then msg.text else msg.data end
      error  = "<b>msg</b>: #{he msg_ct}"
      error << "\n\n<b>#{status}</b>: <pre>#{he _error}</pre>\n"

      send_message admin_msg, error, parse_mode: 'HTML'
    end

    def fake_msg chat_id=nil
      SymMash.new from: {id: nil}, chat: {id: chat_id}, resp: {result: {}, text: ''}
    end
    def admin_msg
      fake_msg ADMIN_CHAT_ID
    end

    def api
      bot.api
    end

    def parse_text text, parse_mode:
      return unless text
      MsgHelpers.limit text
    end

    # Download any Telegram file (audio, video, document) and store it locally.
    def download_file(info, dir: Dir.tmpdir)
      tg_path   = api.get_file(file_id: info.file_id).file_path or raise 'no file_path returned'
      file_name = info.respond_to?(:file_name) && info.file_name.present? ? info.file_name : File.basename(tg_path)
      local     = File.join dir, file_name

      base_url = "https://api.telegram.org/file/bot#{ENV['TL_BOT_TOKEN']}/"
      File.write local, Mechanize.new.get(base_url + tg_path).body
      local
    end

  end
end
