require 'rails_helper'
require_relative '../../support/forwarding_bot'

RSpec.describe 'Api chats and forwardings', type: :request do
  let(:chat_id) { -9_000_000_001 }
  let(:chats)   { [{ id: chat_id, title: 'Biblioteca', type: 'Supergroup' }, { id: 5, title: 'Someone', type: 'Private' }] }
  let(:bot)     { ForwardingBot.new(message_ids: [1, 2], chats: chats, topics: [{ id: 7, name: 'General' }]) }
  let(:headers) { { 'Authorization' => 'Bearer secret', 'CONTENT_TYPE' => 'application/json' } }
  let(:dir)     { Dir.mktmpdir }
  let(:log)     { Forwarding::Log.new(path: File.join(dir, 'forwarded.jsonl')) }
  let(:manager) do
    Manager.new.tap do |m|
      m.instance_variable_set(:@bot, bot)
      m.instance_variable_set(:@forwarding, Forwarding::Jobs.new(-> { bot }, log: log))
    end
  end

  after { FileUtils.remove_entry(dir) }

  around { |example| ChatSetting.db.transaction(rollback: :always, auto_savepoint: true) { example.run } }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('BOT_HTTP_TOKEN').and_return('secret')
    Rails.application.config.x.manager = manager
  end

  it 'rejects calls without the token' do
    get '/api/chats'

    expect(response).to have_http_status(:unauthorized)
  end

  it 'lists chats with whether the bot responds there, and toggles it' do
    patch "/api/chats/#{chat_id}", params: { respond: true, title: 'Biblioteca' }.to_json, headers: headers
    expect(response.parsed_body).to eq('id' => chat_id, 'respond' => true, 'options' => '')

    get '/api/chats', headers: headers
    expect(response.parsed_body.map { |chat| chat.values_at('title', 'respond') }).to eq([['Biblioteca', true], ['Someone', false]])

    patch "/api/chats/#{chat_id}", params: { respond: false }.to_json, headers: headers
    expect(ChatSetting.respond?(chat_id)).to be(false)
  end

  it 'saves the default options of a chat without touching respond, and lists them' do
    patch "/api/chats/#{chat_id}", params: { respond: true }.to_json, headers: headers
    patch "/api/chats/#{chat_id}", params: { options: 'lang=pt hashtags' }.to_json, headers: headers
    expect(response.parsed_body).to eq('id' => chat_id, 'respond' => true, 'options' => 'lang=pt hashtags')

    get '/api/chats', headers: headers
    expect(response.parsed_body.map { |chat| chat.values_at('respond', 'options') }).to eq([[true, 'lang=pt hashtags'], [false, '']])
  end

  it 'lists forum topics' do
    get "/api/chats/#{chat_id}/topics", headers: headers

    expect(response.parsed_body).to eq([{ 'id' => 7, 'name' => 'General' }])
  end

  it 'starts a forwarding and reports it' do
    post '/api/forwardings', params: { forwarding: { source: { chat_id: -100 }, target: { chat_id: chat_id }, caption: 'lang=pt' } }.to_json, headers: headers
    id = response.parsed_body['id']

    expect(response).to have_http_status(:accepted)
    Timeout.timeout(2) { sleep 0.01 until manager.forwarding_job(id)[:state] == 'completed' }
    get "/api/forwardings/#{id}", headers: headers
    expect(response.parsed_body).to include('state' => 'completed', 'sent' => 2)
  end
end
