module Dubbing
  module VoiceReference
    # One recorded reference per speaker, from the first tier of Candidates that gives a voice with transcribed words.
    class Extractor
      TIERS = %i[strict relaxed turns].freeze

      def initialize(input_path, segments:, sentences:, dir:, max_duration: MAX_DURATION, transcriber: nil,
                     analyzer: ::VoiceReference::AudioAnalyzer.new, cutter: Cutter.new(analyzer: analyzer))
        @input_path  = input_path
        @dir         = dir
        @transcriber = transcriber
        @analyzer    = analyzer
        @sentences   = Array(sentences).sort_by { |sentence| sentence.start.to_f }
        @candidates  = Candidates.new(
          input_path, sentences: @sentences, segments: Array(segments), analyzer: analyzer, cutter: cutter, max_duration: max_duration
        )
      end

      def call
        @sentences.group_by(&:speaker_id).each_with_index.filter_map do |(speaker_id, _), index|
          reference = reference_for(speaker_id, File.join(@dir, format('speaker-%04d', index)))
          [speaker_id, reference] if reference
        end.to_h
      end

      private

      attr_reader :input_path, :transcriber, :analyzer, :candidates

      def reference_for(speaker_id, dir)
        FileUtils.mkdir_p(dir)
        found = false
        # The diarized turns have no text of their own, only a transcriber can give them any.
        TIERS.reject { |tier| tier == :turns && !transcriber }.each do |tier|
          selections = candidates.public_send(tier, speaker_id, dir: dir)
          next if selections.empty?

          found = true
          reference = build(selections, dir)
          return reference if reference
        end
        raise "speaker #{speaker_id} has no usable reference" unless found
      end

      def build(selections, dir)
        clips = selections.each.with_index(1).map { |selection, idx| VoiceReference.extract_span(input_path, selection, dir, idx) }
        path  = File.join(dir, 'speaker.wav')
        Zipper::AudioOps.concat(clips, path)
        level(path, dir)
        text = reference_text(path, selections)
        TTS::Reference.new(path: path, text: text) unless text.empty?
      end

      # Once over the whole reference, not per clip, so the clips stay at the level they have among each other.
      def level(path, dir)
        leveled = File.join(dir, 'speaker.level.wav')
        analyzer.extract_span(audio: path, start: nil, duration: nil, output: leveled, sample_rate: 22_050, filter: :level)
        FileUtils.mv(leveled, path)
      end

      def reference_text(path, selections)
        return selections.map(&:text).reject(&:empty?).join(' ') unless transcriber

        transcriber.call_vocals(path).entries.map { |entry| entry.text.strip }.reject(&:empty?).join(' ')
      end
    end
  end
end
