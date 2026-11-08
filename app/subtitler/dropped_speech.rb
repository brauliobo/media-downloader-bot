class Subtitler
  # whisper.cpp can drop the speech after the first sentences of a window and resume at the next one, leaving seconds
  # of speech without a transcript. Each such gap (the voice activity finds speech in it) is transcribed again from its start.
  # It can also loop on a stretch, repeating one phrase for many entries: those are no transcript either, so they are dropped
  # and the stretch is transcribed again the same way.
  class DroppedSpeech
    MIN_GAP     = 3.0
    MIN_SPEECH  = 1.0
    LOOP_RUN    = 3
    # Whisper's own measure of a repeating text: it compresses far better than speech does.
    COMPRESSION = 2.4
    MIN_BYTES   = 60
    Gap        = Data.define(:start, :finish)

    # transcribe gets a Gap and returns the Subtitle of its audio, timed in the whole audio.
    def initialize(subtitle, audio:, &transcribe)
      @subtitle   = subtitle
      @audio      = audio
      @transcribe = transcribe
    end

    def call
      @subtitle.replace_entries!(without_loops(@subtitle.entries)).rebuild_text_from_entries!
      tried = []
      while (gap = next_gap(tried))
        tried << gap.start
        fill(gap)
      end
      @subtitle
    end

    private

    def fill(gap)
      found = without_loops(@transcribe.call(gap).entries.select { |entry| entry.start >= gap.start && entry.finish <= gap.finish + 0.3 })
      @subtitle.replace_entries!((@subtitle.entries + found).sort_by(&:start)).rebuild_text_from_entries!
    end

    def without_loops(entries)
      runs = entries.sort_by(&:start).chunk_while { |a, b| words_of(a) == words_of(b) }
      runs.flat_map { |run| run.size >= LOOP_RUN ? [] : run }.reject { |entry| repeating?(entry.text) }
    end

    def words_of(entry) = entry.text.downcase.gsub(/[^\p{L}\p{N}]/, '')

    def repeating?(text) = text.bytesize >= MIN_BYTES && text.bytesize > COMPRESSION * Zlib.deflate(text).bytesize

    def next_gap(tried)
      @subtitle.entries.sort_by(&:start).each_cons(2).filter_map do |before, after|
        Gap.new(before.finish, after.start) if after.start - before.finish >= MIN_GAP
      end.find { |gap| !tried.include?(gap.start) && speech_in(gap) >= MIN_SPEECH }
    end

    def speech_in(gap)
      speech.sum { |range| [[range.finish, gap.finish].min - [range.start, gap.start].max, 0].max }
    end

    def speech = @speech ||= VoiceActivity.detect(@audio).intervals
  end
end
