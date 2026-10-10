class Diarizer
  BACKEND = const_get(ENV['DIARIZER'] || 'PyannoteCommunity1')

  def self.diarize(path, speakers: nil)
    BACKEND.diarize(path, speakers: speakers)
  end

  def self.assign_speakers!(subtitle, speaker_segments, sentence_level: false)
    segments = Array(speaker_segments)
    raise 'diarization returned no speaker segments' if segments.empty?

    entries = if sentence_level
      subtitle.sentence_entries.map do |entry|
        entry.assign_speaker!(best_segment(entry.start, entry.finish, segments).speaker_id)
      end
    else
      subtitle.entries.flat_map do |entry|
        if entry.words.empty?
          entry.deep_copy.assign_speaker!(best_segment(entry.start, entry.finish, segments).speaker_id)
        else
          entry.words.chunk_while do |left, right|
            best_segment(left.start, left.finish, segments).speaker_id ==
              best_segment(right.start, right.finish, segments).speaker_id
          end.map do |words|
            build_speaker_entry(entry, words, segments)
          end
        end
      end
    end
    subtitle.replace_entries!(entries).rebuild_text_from_entries!
  end

  def self.best_segment(start_time, finish_time, segments)
    segments.max_by do |candidate|
      overlap_start  = [start_time.to_f, candidate.start].max
      overlap_finish = [finish_time.to_f, candidate.finish].min
      overlap        = [overlap_finish - overlap_start, 0.0].max
      distance       = [candidate.start - finish_time.to_f, start_time.to_f - candidate.finish, 0.0].max

      [overlap, -distance, candidate.start, -candidate.finish]
    end
  end
  private_class_method :best_segment

  def self.build_speaker_entry(source, words, segments)
    copies       = words.map(&:deep_copy)
    source_words = source.source_words.select do |word|
      word.finish > copies.first.start && word.start < copies.last.finish
    end.map(&:deep_copy)
    source_text = if source_words.empty?
      source.source_text
    else
      source_words.map { |word| word.text.strip }.reject(&:empty?).join(' ')
    end

    Subtitler::Subtitle::Entry.new(
      start:        copies.first.start,
      finish:       copies.last.finish,
      text:         copies.map { |word| word.text.strip }.reject(&:empty?).join(' '),
      words:        copies,
      speaker_id:   best_segment(copies.first.start, copies.first.finish, segments).speaker_id,
      cue_id:       source.cue_id,
      source_text:  source_text,
      source_words: source_words,
      metadata:     source.metadata
    )
  end
  private_class_method :build_speaker_entry
end
