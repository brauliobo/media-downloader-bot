module Dubbing
  module VoiceReference
    # Word timings from the transcript land inside the speech, so cutting on them clips the first and last sound.
    # A cut moves outward only, never into the sentence, to the quietest moment of the silence around it.
    class Cutter
      SAMPLE_RATE = 16_000
      FRAME       = 0.01
      FRAME_SIZE  = (SAMPLE_RATE * FRAME).to_i
      FLOOR_DB    = -120.0
      # Frames within TIE_DB of the quietest are equally quiet; the one nearest the sentence wins.
      TIE_DB      = 3.0
      # A cut this far under the speech level sits in silence.
      CLEAN_DB    = 12.0

      def initialize(analyzer: ::VoiceReference::AudioAnalyzer.new)
        @analyzer = analyzer
      end

      # The selection with its cuts moved, and whether both landed in silence.
      def call(audio, selection, dir:)
        origin = selection.start - selection.before
        levels = frame_levels(audio, origin, selection.before + selection.duration + selection.after, dir)
        first  = index(selection.before, levels)
        last   = index(selection.before + selection.duration, levels)
        return selection.with(clean: false) unless first && last && first < last

        from = quietest(levels, (0..first).to_a.reverse)
        to   = quietest(levels, (last...levels.size).to_a)
        cut(selection, origin, [from, to], [first, last], clean: clean?(levels, from, to, levels[first..last]))
      end

      private

      attr_reader :analyzer

      def index(offset, levels)
        (offset / FRAME).round.clamp(0, levels.size - 1) if levels.size > 2
      end

      # The first of the candidates, scanned outward from the sentence, that is as quiet as the quietest.
      def quietest(levels, candidates)
        floor = candidates.map { |idx| levels[idx] }.min
        candidates.find { |idx| levels[idx] <= floor + TIE_DB }
      end

      def clean?(levels, from, to, speech)
        limit = Utils::Stats.percentile(speech, 0.9) - CLEAN_DB
        [levels[from], levels[to]].all? { |level| level <= limit }
      end

      def cut(selection, origin, moved, boundary, clean:)
        start  = moved.first == boundary.first ? selection.start : origin + (moved.first + 0.5) * FRAME
        finish = moved.last == boundary.last ? selection.start + selection.duration : origin + (moved.last + 0.5) * FRAME
        selection.with(start: start, duration: finish - start, before: 0.0, after: 0.0, clean: clean)
      end

      def frame_levels(audio, start, duration, dir)
        path = File.join(dir, format('cut-%.3f.wav', start))
        analyzer.extract_span(audio: audio, start: start, duration: duration, output: path, sample_rate: SAMPLE_RATE)
        samples(path).each_slice(FRAME_SIZE).filter_map { |frame| level(frame) if frame.size == FRAME_SIZE }
      ensure
        FileUtils.rm_f(path)
      end

      def level(frame)
        rms = Math.sqrt(frame.sum { |sample| sample * sample } / frame.size) / 32_768.0
        rms.zero? ? FLOOR_DB : [20 * Math.log10(rms), FLOOR_DB].max
      end

      # 16-bit mono PCM of a WAV file, past whatever chunks come before its data.
      def samples(path)
        wav = File.binread(path)
        pos = 12
        while pos + 8 <= wav.bytesize
          id, size = wav.byteslice(pos, 8).unpack('a4V')
          return wav.byteslice(pos + 8, size).unpack('s<*') if id == 'data'

          pos += 8 + size + (size & 1)
        end
        []
      end
    end
  end
end
