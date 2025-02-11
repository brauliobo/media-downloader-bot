require 'puma'
require 'roda'

class TlBot
  module Helpers

    include MsgHelpers

    RETRY_ERRORS = [
      Faraday::ConnectionFailed,
      Faraday::TimeoutError,
      Net::OpenTimeout, Net::WriteTimeout,
    ]

    extend ActiveSupport::Concern
    included do
      class_attribute :bot_name

      class_attribute :error_delete_time
      self.error_delete_time = 30.seconds

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
      sleep 1 while !net_up?
    end

    def edit_message msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', **params
      text = parse_text text, parse_mode: parse_mode
      api.send "edit_message_#{type}",
        chat_id:    msg.chat.id,
        message_id: id,
        text:       text,
        caption:    text,
        parse_mode: parse_mode,
        **params

    rescue ::Telegram::Bot::Exceptions::ResponseError => e
      resp = SymMash.new JSON.parse e.response.body
      return if resp.description.match(/exactly the same as a current content/)
      raise
    rescue
      # ignore
    end

    class ::Telegram::Bot::Types::Message
      attr_accessor :resp
    end

    def send_message msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params
      _text = text
      text  = parse_text text, parse_mode: parse_mode
      resp  = SymMash.new api.send("send_#{type}",
        reply_to_message_id: msg.message_id,
        chat_id:             msg.chat.id,
        text:                text,
        caption:             text,
        parse_mode:          parse_mode,
        **params).to_h
      resp.text = _text

      delete = delete_both if delete_both
      delete_message msg, resp.message_id, wait: delete if delete
      delete_message msg, msg.message_id, wait: delete_both if delete_both

      resp
    rescue *RETRY_ERRORS
      retry
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
      @bc ||= self.then do
        bcl = ActiveSupport::BacktraceCleaner.new
        bcl.add_filter{ |line| line.gsub "#{Dir.pwd}/", '' }
        bcl
      end.clean bc
    end

    def admin_report msg, _error, status: 'error'
      return if ADMIN_CHAT_ID != msg.chat.id

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

  end
end
