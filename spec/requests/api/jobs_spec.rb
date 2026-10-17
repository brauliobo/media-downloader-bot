require 'rails_helper'

RSpec.describe 'Api jobs', type: :request do
  let(:fake_manager) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def tracked_start(**args) = (@calls << [:start, args]) && { id: 1 }
      def tracked_update(id, **args) = (@calls << [:update, id, args]) && { id: id }
      def tracked_stop(id) = (@calls << [:stop, id]) && { id: id }
      def tracked_resume(id) = (@calls << [:resume, id]) && { id: id }
      def tracked_edit(id, result) = (@calls << [:edit, id, result]) && { id: id }
      def tracked_apply(id) = (@calls << [:apply, id]) && { id: id }
      def tracked_retry_items(ids, discard: false) = (@calls << [:retry, ids, discard]) && ids.size
      def tracked_delete_message(id) = (@calls << [:delete, id]) && { id: id }
    end.new
  end
  let(:headers) { { 'Authorization' => 'Bearer secret', 'CONTENT_TYPE' => 'application/json' } }
  let!(:job)    { Job.create(kind: 'replay', parallel: 4, params: { chat_id: -200 }) }
  let!(:item)   { JobItem.create(job_id: job.id, kind: 'replay', key: '-200:1', status: 'failed') }
  let!(:ok)     { JobItem.create(job_id: job.id, kind: 'replay', key: '-200:2', status: 'done') }
  let!(:message) { JobMessage.create(job_item_id: item.id, chat_id: -200, message_id: 7, kind: 'Text', failed: true, text: 'failed') }

  around { |example| Job.db.transaction(rollback: :always, auto_savepoint: true) { example.run } }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('BOT_HTTP_TOKEN').and_return('secret')
    Rails.application.config.x.manager = fake_manager
  end

  it 'finds the running items that made no progress for a while' do
    quiet = JobItem.create(job_id: job.id, kind: 'replay', key: '-200:3', status: 'running', claimed_at: Time.now - 3600)
    busy  = JobItem.create(job_id: job.id, kind: 'replay', key: '-200:4', status: 'running', claimed_at: Time.now - 3600)
    BotJob.dataset.insert(id: 'busy', queue: 'tdbot', key: '-200:4', state: 'running', message: Sequel.pg_jsonb({}), updated_at: Time.now - 60)

    get "/api/job_items?job_id=#{job.id}&status=running", headers: headers
    expect(response.parsed_body.to_h { |i| [i['id'], i['stalled']] }).to eq(quiet.id => true, busy.id => false)

    get "/api/job_items?job_id=#{job.id}&status=stalled", headers: headers
    expect(response.parsed_body.map { |i| i['id'] }).to eq([quiet.id])
  ensure
    BotJob.where(id: 'busy').delete
  end

  it 'rejects calls without the token' do
    get '/api/jobs'

    expect(response).to have_http_status(:unauthorized)
  end

  it 'lists the jobs with their counts and params' do
    get '/api/jobs', headers: headers

    expect(response.parsed_body.first).to include('id' => job.id, 'kind' => 'replay', 'parallel' => 4, 'params' => { 'chat_id' => -200 }, 'counts' => { 'failed' => 1, 'done' => 1 })
  end

  it 'starts, updates, stops and resumes a job through the manager' do
    post '/api/jobs', params: { job: { kind: 'replay', parallel: 7, params: { chat_id: -200, retry_failed: true } } }.to_json, headers: headers
    patch "/api/jobs/#{job.id}", params: { job: { parallel: 9 } }.to_json, headers: headers
    post "/api/jobs/#{job.id}/stop", headers: headers
    post "/api/jobs/#{job.id}/resume", headers: headers

    expect(response).to have_http_status(:ok)
    expect(fake_manager.calls).to eq([[:start, { kind: 'replay', parallel: 7, params: { 'chat_id' => -200, 'retry_failed' => true } }],
                                      [:update, job.id, { parallel: 9 }], [:stop, job.id], [:resume, job.id]])
  end

  it 'lists the items of a job with their messages, filtered by status' do
    get '/api/job_items', params: { job_id: job.id, status: 'failed' }, headers: headers

    expect(response.parsed_body.map { |i| i['key'] }).to eq(['-200:1'])
    expect(response.parsed_body.first['messages'].first).to include('message_id' => 7, 'failed' => true)
  end

  it 'edits the hashtags, applies them and retries items' do
    patch "/api/job_items/#{item.id}", params: { job_item: { hashtags: '#Novo' } }.to_json, headers: headers
    post "/api/job_items/#{item.id}/apply", headers: headers
    post "/api/job_items/#{item.id}/retry", headers: headers
    post "/api/job_items/#{item.id}/retry?discard=true", headers: headers
    post "/api/job_items/retry_failed?job_id=#{job.id}", headers: headers

    expect(response.parsed_body).to eq('retried' => 1)
    expect(fake_manager.calls).to eq([[:edit, item.id, { 'hashtags' => '#Novo' }], [:apply, item.id], [:retry, [item.id], false], [:retry, [item.id], true], [:retry, [item.id], false]])
  end

  it 'lists the live messages and deletes one through the manager' do
    get '/api/job_messages', params: { job_item_id: item.id }, headers: headers
    expect(response.parsed_body.map { |m| m['message_id'] }).to eq([7])

    delete "/api/job_messages/#{message.id}", headers: headers
    expect(fake_manager.calls).to eq([[:delete, message.id]])
  end

  it 'answers 404 for an unknown job' do
    get '/api/jobs/0', headers: headers

    expect(response).to have_http_status(:not_found)
  end
end
