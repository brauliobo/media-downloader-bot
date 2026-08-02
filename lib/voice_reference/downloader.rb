require 'tmpdir'

require_relative '../downloaders'

class VoiceReference
  class Downloader
    def call(url, dir:)
      download_dir = Dir.mktmpdir('voice-reference-download-', dir)
      options      = SymMash.new(audio: 1)
      context      = Context.new(url: url, opts: options, dir: download_dir, tmp: download_dir)
      input        = SymMash.new(url: url, opts: options)

      Downloaders::YtDlp.new(context).download_one(input)
      input.fn_in
    end
  end
end
