require 'rails_helper'

RSpec.describe 'Api replays', type: :request do
  let(:fake_manager) do
    Class.new do
      def initialize = @jobs = {}
      def replay_jobs = @jobs.values
      def replay_job(id) = @jobs[id]
      def stop_replay(id) = @jobs[id][:state] = 'failed'

      def start_replay(params)
        id = (@jobs.size + 1).to_s
        @jobs[id] = { id: id, state: 'running', chat_id: params['chat_id'].to_i, parallel: (params['parallel'] || 6).to_i, plan: params['plan'] == true }
      end
    end.new
  end
  let(:headers) { { 'Authorization' => 'Bearer secret', 'CONTENT_TYPE' => 'application/json' } }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('BOT_HTTP_TOKEN').and_return('secret')
    Rails.application.config.x.manager = fake_manager
  end

  it 'rejects calls without the token' do
    get '/api/replays'

    expect(response).to have_http_status(:unauthorized)
  end

  it 'starts a replay with the default parallelism and reports it' do
    post '/api/replays', params: { replay: { chat_id: -100 } }.to_json, headers: headers
    id = response.parsed_body['id']

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include('chat_id' => -100, 'parallel' => 6, 'plan' => false)
    get "/api/replays/#{id}", headers: headers
    expect(response.parsed_body).to include('id' => id, 'state' => 'running')
  end

  it 'passes parallel and plan through and lists newest first' do
    post '/api/replays', params: { replay: { chat_id: -1 } }.to_json, headers: headers
    post '/api/replays', params: { replay: { chat_id: -2, parallel: 3, plan: true } }.to_json, headers: headers

    get '/api/replays', headers: headers
    expect(response.parsed_body.map { |job| job.values_at('chat_id', 'parallel', 'plan') }).to eq([[-2, 3, true], [-1, 6, false]])
  end

  it 'answers 404 for an unknown replay' do
    get '/api/replays/nope', headers: headers

    expect(response).to have_http_status(:not_found)
  end

  it 'stops a replay' do
    post '/api/replays', params: { replay: { chat_id: -1 } }.to_json, headers: headers
    id = response.parsed_body['id']

    post "/api/replays/#{id}/stop", headers: headers

    expect(response.parsed_body).to include('id' => id, 'state' => 'failed')
  end
end
