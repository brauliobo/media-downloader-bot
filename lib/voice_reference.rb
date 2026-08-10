class VoiceReference
  def self.from_url(
    url:, output:, language: nil, downloader: Downloader.new, transcriber: Transcriber.new, reference_filter: :raw,
    on_status: nil
  )
    on_status&.call('Downloading voice reference')
    audio      = downloader.call(url, dir: File.dirname(output))
    on_status&.call('Transcribing voice reference')
    transcript = transcriber.call(audio)
    language ||= transcript.fetch(:language)
    selector  = Selector.new(language: language, strict: reference_filter.to_sym == :raw)
    builder_options = {
      transcriber: transcriber, selector: selector, language: language, reference_filter: reference_filter
    }
    builder_options[:on_status] = on_status if on_status
    on_status&.call('Selecting voice reference')
    reference = Builder.new(**builder_options).build(
      audio_files: [audio], output: output, transcripts: {audio => transcript}
    )
    on_status&.call('Voice reference ready')
    reference
  end
end

require_relative 'voice_reference/candidate'
require_relative 'voice_reference/transcriber'
require_relative 'voice_reference/transcript_quality'
require_relative 'voice_reference/audio_analyzer'
require_relative 'voice_reference/selector'
require_relative 'voice_reference/builder'
require_relative 'voice_reference/downloader'
