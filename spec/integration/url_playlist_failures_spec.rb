require 'spec_helper'
require_relative '../support/integration_helper'

RSpec.describe 'Worker playlist with mixed failures (integration)' do
  include IntegrationHelper

  let(:fixtures) { IntegrationHelper.ensure_fixtures }
  let(:workdir)  { Dir.mktmpdir('mdb-spec-') }
  let(:bot)      { Bot::Spy.new }

  before do
    IntegrationHelper.setup_pipeline_env(workdir)
    @prev_service = Worker.service
    Worker.service = bot
    Worker.tmpdir = workdir
  end

  after do
    Worker.service = @prev_service
    IntegrationHelper.teardown_pipeline_env
    FileUtils.remove_entry(workdir) if Dir.exist?(workdir)
  end

  it 'uploads the two successful items even when one fails to download' do
    IntegrationHelper.stub_yt_dlp_plan(
      'playlist' => [
        {'display_id' => 'v1', 'title' => 'First',  'webpage_url' => 'https://example.com/v1', 'fixture' => fixtures[:mp4]},
        {'display_id' => 'v2', 'title' => 'Broken', 'webpage_url' => 'https://example.com/v2', 'fixture' => fixtures[:mp4]},
        {'display_id' => 'v3', 'title' => 'Third',  'webpage_url' => 'https://example.com/v3', 'fixture' => fixtures[:mp4]},
      ],
      'items' => {
        '1' => {'fixture' => fixtures[:mp4], 'status' => 0},
        '2' => {'status' => 1, 'stderr' => 'simulated download failure for v2'},
        '3' => {'fixture' => fixtures[:mp4], 'status' => 0},
      },
    )

    msg = IntegrationHelper.build_msg(text: 'https://example.com/playlist?list=PL_TEST')
    Worker.new(msg).run

    uploads = bot.sent.select { |s| s.params[:type] || s.params[:video_path] || s.params[:audio_path] || s.params[:document_path] }
    titles  = uploads.flat_map { |u| [u.params[:title], u.params[:caption]] }.compact.join(' ')

    expect(uploads.size).to eq(2), "expected 2 successful uploads, got #{uploads.size}\nsent=#{bot.sent.map(&:to_h)}"
    expect(titles).to include('First')
    expect(titles).to include('Third')
    expect(titles).not_to include('Broken')

    edits = bot.edited.map { |e| e.text.to_s }.join("\n")
    expect(edits).to match(/Broken.*download error/m)
  end
end
