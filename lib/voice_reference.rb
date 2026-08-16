require 'fileutils'
require 'tmpdir'

class VoiceReference
  def self.from_files(
    audio_files:, output:, language: 'en', transcriber: Transcriber.new, reference_filter: :raw, strict: nil,
    on_status: nil
  )
    sources        = Array(audio_files)
    unique_sources = sources.uniq
    vocals         = {}

    on_status&.call('Transcribing voice reference')
    Dir.mktmpdir('voice-reference-sources-') do |dir|
      unique_sources.each_with_index do |source, index|
        source_dir = File.join(dir, index.to_s)
        FileUtils.mkdir_p(source_dir)
        stems = VoiceSeparator.separate(source, dir: source_dir)
        vocals[source] = stems.vocals
        File.delete(stems.non_vocals)
      end

      transcripts = unique_sources.to_h do |source|
        transcript = transcriber.call(vocals.fetch(source), cache_key: source, separate_voice: false)
        raise TypeError, 'transcript must be a Subtitler::Subtitle' unless transcript.is_a?(Subtitler::Subtitle)

        [source, transcript]
      end
      language ||= transcripts.fetch(sources.first).language if sources.any?
      selector = Selector.new(
        language: language,
        strict: strict.nil? ? reference_filter.to_sym == :raw : strict
      )
      builder_options = {
        transcriber: transcriber, selector: selector, language: language, reference_filter: reference_filter
      }
      builder_options[:on_status] = on_status if on_status
      on_status&.call('Selecting voice reference')
      reference = Builder.new(**builder_options).build(
        audio_files: sources.map { |source| vocals.fetch(source) }, source_files: sources,
        output: output, transcripts: transcripts
      )
      on_status&.call('Voice reference ready')
      reference
    end
  end

  def self.from_url(
    url:, output:, language: nil, downloader: Downloader.new, transcriber: Transcriber.new, reference_filter: :raw,
    on_status: nil
  )
    on_status&.call('Downloading voice reference')
    audio = downloader.call(url, dir: File.dirname(output))
    from_files(
      audio_files: [audio], output: output, language: language, transcriber: transcriber,
      reference_filter: reference_filter, on_status: on_status
    )
  end
end

require_relative 'voice_separator'
require_relative 'voice_reference/candidate'
require_relative 'voice_reference/transcriber'
require_relative 'voice_reference/transcript_quality'
require_relative 'voice_reference/audio_analyzer'
require_relative 'voice_reference/selector'
require_relative 'voice_reference/builder'
require_relative 'voice_reference/downloader'
