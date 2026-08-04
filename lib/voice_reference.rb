class VoiceReference
  def self.from_url(
    url:, output:, language: nil, downloader: Downloader.new, transcriber: Transcriber.new, reference_filter: :raw
  )
    audio      = downloader.call(url, dir: File.dirname(output))
    transcript = transcriber.call(audio)
    language ||= transcript.fetch(:language)
    selector  = Selector.new(language: language, strict: reference_filter.to_sym == :raw)
    Builder.new(
      transcriber: transcriber, selector: selector, language: language, reference_filter: reference_filter
    ).build(audio_files: [audio], output: output, transcripts: {audio => transcript})
  end
end

require_relative 'voice_reference/candidate'
require_relative 'voice_reference/transcriber'
require_relative 'voice_reference/transcript_quality'
require_relative 'voice_reference/audio_analyzer'
require_relative 'voice_reference/selector'
require_relative 'voice_reference/builder'
require_relative 'voice_reference/downloader'
