require_relative 'spy_bot'
require 'fileutils'
require 'json'

module IntegrationHelper
  FIXTURES_DIR = File.expand_path('../fixtures/media', __dir__)
  STUB_BIN_DIR = File.expand_path('bin', __dir__)

  module_function

  # Generates tiny media fixtures via ffmpeg the first time they're needed.
  def ensure_fixtures
    FileUtils.mkdir_p(FIXTURES_DIR)
    mp4 = File.join(FIXTURES_DIR, 'silent-1s.mp4')
    opus = File.join(FIXTURES_DIR, 'silent-1s.opus')
    m4a = File.join(FIXTURES_DIR, 'silent-1s.m4a')

    unless File.exist?(mp4)
      system('ffmpeg', '-v', 'quiet', '-y', '-f', 'lavfi', '-i', 'color=c=black:s=128x96:d=1:r=15',
             '-f', 'lavfi', '-i', 'anullsrc=r=16000:cl=mono', '-shortest',
             '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
             '-c:a', 'aac', '-b:a', '16k', mp4) || raise('failed to build mp4 fixture')
    end

    unless File.exist?(opus)
      system('ffmpeg', '-v', 'quiet', '-y', '-f', 'lavfi', '-i', 'anullsrc=r=16000:cl=mono',
             '-t', '1', '-c:a', 'libopus', '-b:a', '16k', opus) || raise('failed to build opus fixture')
    end

    unless File.exist?(m4a)
      system('ffmpeg', '-v', 'quiet', '-y', '-f', 'lavfi', '-i', 'anullsrc=r=16000:cl=mono',
             '-t', '1', '-c:a', 'aac', '-b:a', '16k', m4a) || raise('failed to build m4a fixture')
    end

    {mp4: mp4, opus: opus, m4a: m4a}
  end

  # Sequential, hermetic environment for an integration spec.
  def setup_pipeline_env(workdir)
    @pipeline_state = {
      env:    %w[THREADS API_THREADS TMPDIR SKIP_META PATH YTDLP_STUB_PLAN].to_h { |name| [name, ENV[name]] },
      worker: {
        tmpdir:       Worker.tmpdir,
        workdir_path: Worker.workdir_path,
        skip_cleanup: Worker.skip_cleanup,
      },
    }

    ENV['THREADS'] = '1'
    ENV['API_THREADS'] = '1'
    ENV['TMPDIR'] = workdir
    ENV['SKIP_META'] = '1'
    ENV['PATH'] = "#{STUB_BIN_DIR}:#{ENV['PATH']}"
    Worker.tmpdir = workdir
    Worker.workdir_path = workdir
    Worker.skip_cleanup = true
  end

  def teardown_pipeline_env
    @pipeline_state[:env].each do |name, value|
      if value.nil?
        ENV.delete name
      else
        ENV[name] = value
      end
    end

    Worker.tmpdir       = @pipeline_state[:worker][:tmpdir]
    Worker.workdir_path = @pipeline_state[:worker][:workdir_path]
    Worker.skip_cleanup = @pipeline_state[:worker][:skip_cleanup]
    @pipeline_state = nil
  end

  # Writes a yt-dlp stub plan to ENV. The stub script reads this on each invocation.
  # plan: {
  #   playlist: [ {display_id:, title:, webpage_url:, fixture:} ... ],
  #   item_results: { <pos:1> => {fixture:, status:0|1, stderr:''} ... }
  # }
  def stub_yt_dlp_plan(plan)
    ENV['YTDLP_STUB_PLAN'] = JSON.dump(plan)
  end

  def build_msg(text:, from_id: 1, chat_id: 1)
    SymMash.new(
      message_id: 1,
      from:       {id: from_id, username: 'tester'},
      chat:       {id: chat_id},
      text:       text,
      resp:       SymMash.new(result: {message_id: 100}, message_id: 100, text: ''),
    )
  end
end
