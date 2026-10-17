require 'rails_helper'
require 'socket'
require_relative '../support/spy_bot'

# A worker talking to a real bot service over HTTP while the bot restarts under it: the job it holds survives in the database, its
# messages wait for the bot and go out when it is back.
RSpec.describe Worker::Daemon, 'through a restart of the bot' do
  let(:port)   { TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] } }
  let(:client) { Bot::Worker::Client.new("http://127.0.0.1:#{port}") }
  let(:gate)   { Queue.new }
  let(:midway) { Queue.new }
  let(:sent)   { [] }

  def start_bot
    bot     = Bot::Spy.new
    manager = Manager.new.tap { |instance| instance.instance_variable_set(:@bot, bot) }
    server  = Puma::Server.new(Bot::Worker::HTTPService.create(manager).freeze.app, nil)
    server.add_tcp_listener('127.0.0.1', port)
    server.run
    [manager, bot, server]
  end

  around do |example|
    token = ENV['BOT_HTTP_TOKEN']
    ENV['BOT_HTTP_TOKEN'] = 'secret'
    saved = %i[USR2 TERM INT].to_h { |name| [name, trap(name, 'DEFAULT')] }
    example.run
  ensure
    ENV['BOT_HTTP_TOKEN'] = token
    saved.each { |name, handler| trap(name, handler) }
  end

  before do
    BotJob.dataset.delete
    stub_const("#{described_class}::POLL", 0.05)
    stub_const('Bot::Worker::Client::PAUSE_MAX', 0.05)
    allow(Worker).to receive(:prune_workdirs)
    allow(client).to receive(:warn)
    allow(Worker).to receive(:new) do |msg, service:, **|
      double.tap do |worker|
        allow(worker).to receive(:process) do
          service.send_message(msg, 'before the restart')
          midway << true
          gate.pop
          service.send_message(msg, 'after the restart')
        end
      end
    end
  end

  it 'finishes the job on the new bot, which sees the same queue' do
    first, bot, server = start_bot
    msg = SymMash.new(from: { id: 1 }, chat: { id: 1 }, message_id: 5, text: 'book')
    job = first.jobs.submit(msg)
    daemon = described_class.new(service: client)
    allow(daemon).to receive(:puts)
    thread = Thread.new { daemon.run }
    midway.pop

    server.stop(true)
    gate << true
    sleep 0.3
    second, other_bot, other_server = start_bot

    Timeout.timeout(5) { sleep 0.02 while second.jobs.active?(job[:id]) }
    Process.kill(:USR2, Process.pid)
    expect(thread.join(5)).to be_truthy
    expect(bot.sent.map(&:text)).to eq ['before the restart']
    expect(other_bot.sent.map(&:text)).to eq ['after the restart']
    other_server.stop(true)
  end
end
