require 'rails_helper'

RSpec.describe 'Api relay', type: :request do
  let(:fake_manager) do
    Class.new do
      attr_reader :retried

      def initialize = @retried = []
      def retry_relay(id) = (@retried << id) && true
      def retry_failed_relays = (@retried << :failed).size
    end.new
  end
  let(:headers) { { 'Authorization' => 'Bearer secret', 'CONTENT_TYPE' => 'application/json' } }
  let(:rule_attrs) { { source_chat_id: -100, source_title: 'Source', target_chat_id: -200, target_topic_id: 7, target_title: 'Target' } }
  let(:rule) { RelayRule.create(rule_attrs) }

  around { |example| RelayRule.db.transaction(rollback: :always, auto_savepoint: true) { example.run } }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('BOT_HTTP_TOKEN').and_return('secret')
    Rails.application.config.x.manager = fake_manager
  end

  def relayed(message_id, **attrs)
    RelayedMessage.create({ relay_rule_id: rule.id, source_chat_id: -100, source_message_id: message_id, target_chat_id: -200 }.merge(attrs))
  end

  it 'rejects calls without the token' do
    get '/api/relay_rules'

    expect(response).to have_http_status(:unauthorized)
  end

  describe 'rules' do
    it 'creates a rule that is enabled and filters documents by default' do
      post '/api/relay_rules', params: { relay_rule: rule_attrs }.to_json, headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to include('source_chat_id' => -100, 'target_topic_id' => 7, 'filter' => 'document', 'enabled' => true)
      expect(RelayRule.count).to eq(1)
    end

    it 'lists, toggles and deletes a rule' do
      rule
      get '/api/relay_rules', headers: headers
      expect(response.parsed_body.map { |r| r['id'] }).to eq([rule.id])

      patch "/api/relay_rules/#{rule.id}", params: { relay_rule: { enabled: false, caption: 'lang=pt' } }.to_json, headers: headers
      expect(response.parsed_body).to include('enabled' => false, 'caption' => 'lang=pt')

      delete "/api/relay_rules/#{rule.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(RelayRule.count).to eq(0)
    end

    it 'answers 404 for an unknown rule' do
      patch '/api/relay_rules/0', params: { relay_rule: { enabled: false } }.to_json, headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'relayed messages' do
    it 'lists newest first with the rule titles and links, filtered by status and rule' do
      relayed(1, status: 'sent', source_link: 'https://t.me/c/1/1', target_link: 'https://t.me/c/2/9')
      relayed(2, status: 'failed', error: 'boom', attempts: 3)

      get '/api/relayed_messages', headers: headers
      expect(response.parsed_body.map { |m| m['source_message_id'] }).to eq([2, 1])
      expect(response.parsed_body.last).to include('source_link' => 'https://t.me/c/1/1', 'target_link' => 'https://t.me/c/2/9', 'source_title' => 'Source', 'target_title' => 'Target')

      get '/api/relayed_messages', params: { status: 'failed' }, headers: headers
      expect(response.parsed_body.map { |m| m.values_at('source_message_id', 'error', 'attempts') }).to eq([[2, 'boom', 3]])

      get '/api/relayed_messages', params: { relay_rule_id: rule.id + 1 }, headers: headers
      expect(response.parsed_body).to eq([])
    end

    it 'limits the list' do
      3.times { |i| relayed(i + 1) }

      get '/api/relayed_messages', params: { limit: 2 }, headers: headers

      expect(response.parsed_body.map { |m| m['source_message_id'] }).to eq([3, 2])
    end

    it 'shows one and answers 404 for an unknown one' do
      get "/api/relayed_messages/#{relayed(1).id}", headers: headers
      expect(response.parsed_body).to include('source_message_id' => 1)

      get '/api/relayed_messages/0', headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it 'retries one message and all failed ones through the manager' do
      message = relayed(1, status: 'failed')

      post "/api/relayed_messages/#{message.id}/retry", headers: headers
      post '/api/relayed_messages/retry_failed', headers: headers

      expect(fake_manager.retried).to eq([message.id, :failed])
      expect(response).to have_http_status(:ok)
    end
  end
end
