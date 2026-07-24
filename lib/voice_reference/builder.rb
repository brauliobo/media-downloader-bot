require 'json'

class VoiceReference
  class Builder
    def initialize(transcriber: Transcriber.new, selector: Selector.new, analyzer: AudioAnalyzer.new)
      @transcriber = transcriber
      @selector    = selector
      @analyzer    = analyzer
    end

    def build(audio_files:, output:)
      recordings = Array(audio_files).map do |audio|
        {audio: audio, transcript: transcriber.call(audio)}
      end
      candidate = selector.select(recordings)
      raise 'no voice reference candidate passed quality checks' unless candidate

      analyzer.extract(candidate, output)
      File.write(sidecar(output, '.txt'), "#{candidate.text}\n")
      File.write(sidecar(output, '.json'), JSON.pretty_generate(candidate.to_h))
      candidate
    end

    private

    attr_reader :transcriber, :selector, :analyzer

    def sidecar(output, extension)
      output.sub(/\.[^.]+\z/, extension)
    end
  end
end
