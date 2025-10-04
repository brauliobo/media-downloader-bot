require 'net/http/post/multipart'
require 'tempfile'
require 'iso-639'
require 'active_support/core_ext/module/attribute_accessors'

require_relative '../zipper'

class Subtitler
  module WhisperCpp

    mattr_accessor :api
    self.api = URI.parse ENV['WHISPER_CPP_SERVER']

    # Transcribe an audio file using whisper.cpp.
    # Params:
    #   path        – path to audio file
    #   format:     – whisper.cpp response_format (default: 'verbose_json')
    #   merge_words – when true (default) contiguous tokens without a leading
    #                 space are merged into a single word and their timings
    #                 are combined (start of first, end of last). This fixes
    #                 whisper.cpp artefact where a single Portuguese word is
    #                 emitted as two tokens (e.g. " test" + "ando").
    #   **extra     – passed directly to whisper.cpp
    def transcribe path, format: 'verbose_json', merge_words: true, **extra
      @http ||= Net::HTTP.new(api.host, api.port).tap do |http|
        http.read_timeout = 1.hour.to_i
        http.use_ssl = api.scheme == 'https'
      end

      wav  = Zipper.audio_to_wav path
      file = UploadIO.new wav, 'audio/wav', File.basename(wav)
      params = {
        file:             file,
        temperature:      '0.0',
        temperature_inc:  '0.2',
        response_format:  format,
        **extra
      }

      req = Net::HTTP::Post::Multipart.new '/inference', params
      res = @http.request req
      out = res.body

      out = SymMash.new JSON.parse(out) if format.to_s.index('json')

      # Accept both ISO codes ("es", "spa") and English names ("Spanish")
      if out.is_a?(Hash) && out.language
        raw = out.language.to_s.strip
        entry = ISO_639.find_by_code(raw) || ISO_639.find_by_english_name(raw.capitalize)
        lang = entry&.alpha2
      end

      merge_split_words!(out) if merge_words && out.respond_to?(:segments)

      SymMash.new output: out, lang: lang

    ensure
      File.unlink wav if wav && File.exist?(wav)
    end

    # Convert verbose_json into SRT with inline per-word timings.
    # When normalize: true (default), adjacent short segments are merged to produce
    # typical movie-style subtitles (max ~2 lines / similar length).
    # Backward-compat: legacy stdsub overrides normalize when provided.
    def srt_convert verbose_json, normalize: true, word_tags: true, stdsub: nil
      mash = SymMash.new verbose_json
      use_norm = stdsub.nil? ? normalize : stdsub
      merge_segments_for_stdsub!(mash) if use_norm

      ts = ->(t){ h, rem = t.divmod(3600); m, s = rem.divmod(60); "%02d:%02d:%02d,%03d" % [h, m, s.to_i, (s.modulo(1)*1000).round] }

      out = +""
      mash.segments&.each_with_index do |seg, idx|
        start = ts.call(seg.start)
        finish = ts.call(seg.end)

        words = seg.words || []
        line = if words.empty?
          seg.text.to_s.strip
        else
          words.each_with_index.map do |w,i|
            word    = w.word.to_s.strip
            w_start = ts.call(w.start)
            if word_tags
              i.zero? ? word : "<#{w_start}>#{word}"
            else
              word
            end
          end.join(' ')
        end

        out << "#{idx+1}\n"
        out << "#{start} --> #{finish}\n"
        out << "#{line}\n\n"
      end

      out
    end

    # Convert whisper.cpp verbose_json output to WEBVTT with inline per-word timings.
    # Accepts either a Hash (already parsed) or a JSON string.
    # Returns the VTT as a single string.
    # When normalize: true (default), merges adjacent short segments to typical movie style.
    # Backward-compat: legacy stdsub overrides normalize when provided.
    def vtt_convert verbose_json, normalize: true, word_tags: true, stdsub: nil
      mash = SymMash.new verbose_json
      use_norm = stdsub.nil? ? normalize : stdsub
      merge_segments_for_stdsub!(mash) if use_norm

      ts = ->(t){ h, rem = t.divmod(3600); m, s = rem.divmod(60); "%02d:%02d:%06.3f" % [h, m, s] }

      vtt = +"WEBVTT\n\n"
      (mash.segments || []).each do |seg|
        start  = ts.call(seg.start)
        finish = ts.call(seg.end)

        words = seg.words || []
        line = if words.empty?
          seg.text.to_s.strip
        else
          words.each_with_index.map do |w,idx|
            word     = w.word.to_s.strip
            w_start  = ts.call(w.start)
            if word_tags
              idx.zero? ? word : "<#{w_start}>#{word}"
            else
              word
            end
          end.join(' ')
        end

        vtt << "#{start} --> #{finish}\n"
        vtt << "#{line}\n\n"
      end

      vtt
    end

    # Translate all segment texts (and their word entries) of a whisper.cpp
    # verbose_json structure using the global Translator backend.
    # Params:
    #   verbose_json – Hash, SymMash or JSON String returned by whisper.cpp
    #   from:        – source ISO-639-1 language (e.g. 'en')
    #   to:          – target ISO-639-1 language (e.g. 'pt')
    # Returns the same structure (SymMash) but with translated strings.
    def translate verbose_json, from:, to:
      mash = SymMash.new verbose_json

      segments = mash.segments || []
      texts = segments.map(&:text)
      translations = texts.each_slice(Translator::BATCH_SIZE).with_object([]) do |slice, acc|
        acc.concat Array.wrap(Translator.translate slice, from: from, to: to)
      end

      segments.each_with_index do |seg, idx|
        ttext = translations[idx].to_s
        seg.text = ttext

        # Tokenize and attach trailing punctuation to previous token
        raw_tokens = ttext.scan(/\p{L}+[\p{L}\p{M}'’\-]*|\d+|[^\p{L}\d\s]+/)
        translated_words = []
        raw_tokens.each do |tok|
          if tok.match?(/\A[^\p{L}\d\s]+\z/) && translated_words.any?
            translated_words[-1] << tok
          else
            translated_words << tok
          end
        end

        # Fuzzy per-word replacement: keep timings, swap words.
        src_n = seg.words.size
        trg_n = translated_words.size

        if src_n == trg_n
          seg.words.each_with_index { |w,i| w.word = translated_words[i] }
        elsif trg_n < src_n
          # Fewer translated tokens – assign unique token to each timestamp; leftover words get empty string
          seg.words.each_with_index do |w,i|
            w.word = i < trg_n ? translated_words[i] : ""
          end
        else # trg_n > src_n
          # More translated tokens – pack several into one slot
          seg.words.each_with_index do |w,i|
            s_idx = ((i    ) * trg_n) / src_n
            e_idx = (((i+1) * trg_n) / src_n) - 1
            slice = translated_words[s_idx..e_idx]
            w.word = slice.join(' ')
          end
        end

        # Remove empty word placeholders to avoid visual artefacts
        seg.words.reject! { |w| w.word.to_s.strip.empty? }
      end

      mash
    end

    private

    # Merge tokens that belong to the same word (current token doesn't start
    # with whitespace). Updates word text, timing, and segment text.
    def merge_split_words! mash
      (mash.segments || []).each do |seg|
        merged = []
        orig_words = seg.words || []
        had_words = orig_words.any?
        orig_words.each do |w|
          raw = w.word.to_s
          if merged.empty? || raw.start_with?(' ')
            merged << w
          else
            prev = merged.last
            # Avoid merging across sentence boundaries (prev token ends with . ? or !)
            if prev.word.to_s.strip.match?(/[.!?]$/)
              merged << w
            else
              prev.word = "#{prev.word}#{raw}"
              prev.end  = w.end
            end
          end
        end
        seg.words = merged
        seg.text  = merged.map { |tw| tw.word.to_s.strip }.join(' ') if had_words
      end
      # Fix cross-segment splits: move leading non-space tokens of next segment to previous if appropriate
      segs = mash.segments || []
      (1...segs.size).each do |i|
        prev = segs[i-1]
        cur  = segs[i]
        next if (prev.words || []).empty? || (cur.words || []).empty?
        while cur.words.first && !cur.words.first.word.to_s.start_with?(' ') && !prev.words.last.word.to_s.strip.match?(/[.!?]$/)
          w = cur.words.shift
          last = prev.words.last
          last.word = "#{last.word}#{w.word}"
          last.end  = w.end
        end
        prev.text = (prev.words || []).map { |tw| tw.word.to_s.strip }.join(' ')
        cur.text  = (cur.words  || []).map { |tw| tw.word.to_s.strip }.join(' ')
      end
      mash
    end

    # Merge adjacent segments to build standard two-line movie subtitles.
    # Merges when the silence gap ≤ gap_threshold and total text length ≤ max_chars.
    def merge_segments_for_stdsub! mash, max_chars: 84, gap_threshold: 1.0
      segments = mash.segments || []
      return mash if segments.empty?

      merged = []
      current = segments.first
      segments.drop(1).each do |seg|
        gap = seg.start.to_f - current.end.to_f
        combined_len = current.text.to_s.length + 1 + seg.text.to_s.length
        if gap <= gap_threshold && combined_len <= max_chars
          current.text = "#{current.text} #{seg.text}"
          current.end  = seg.end
          current.words ||= []
          current.words.concat(seg.words || [])
        else
          merged << current
          current = seg
        end
      end
      merged << current unless merged.last.equal?(current) rescue merged.push(current)
      mash.segments = merged
      mash
    end

  end
end
