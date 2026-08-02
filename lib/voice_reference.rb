class VoiceReference
  def self.from_url(url:, output:, language:, downloader: Downloader.new)
    audio    = downloader.call(url, dir: File.dirname(output))
    selector = Selector.new(language: language)
    Builder.new(selector: selector, language: language).build(audio_files: [audio], output: output)
  end
end

require_relative 'voice_reference/candidate'
require_relative 'voice_reference/transcriber'
require_relative 'voice_reference/audio_analyzer'
require_relative 'voice_reference/selector'
require_relative 'voice_reference/builder'
require_relative 'voice_reference/downloader'
