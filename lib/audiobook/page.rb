require_relative '../zipper'
require_relative 'heading'
require_relative 'paragraph'
require_relative 'image'

module Audiobook
  class Page
    PAUSE = 0

    attr_reader :number, :items

    def initialize(number, items = [])
      @number = number
      @items = items
    end

    def empty?
      items.empty?
    end

    def to_h
      { 'page' => { 'number' => number, 'items' => items.map(&:to_h) } }
    end

    # Generate combined wav for all items on this page
    def to_wav(dir, idx, lang: 'en', stl: nil, para_context: nil, page_context: nil, book_metadata: {}, tts_options: {})
      return nil if items.empty?

      context = prepare_speech_items(
        dir, idx,
        lang: lang,
        stl: stl,
        para_context: para_context,
        page_context: page_context,
        book_metadata: book_metadata,
        tts_options: tts_options
      )
      page_idx = context[:page_idx]
      page_total = context[:page_total]
      is_ocr_book = context[:is_ocr_book]

      batch_synthesize_items(dir, idx, lang, tts_options) if tts_options[:tts_batch_size].to_i > 1

      wavs = items.each_with_index.flat_map do |item, iidx|
        if item.is_a?(Audiobook::Paragraph)
          [item.to_wav]
        else
          operation = item.class.name.split('::').last
          status_parts = ["page #{page_idx}/#{page_total}", "item #{iidx+1}/#{items.size}", operation]
          status_line = "Processing #{status_parts.join(', ')}"
          status_line << " (OCR)" if is_ocr_book
          stl&.update status_line
          heading_pause = item.pause_file(dir) if item.respond_to?(:pause_file)
          wav = item.to_wav(dir, "#{idx}_#{iidx}", lang: lang, stl: stl, tts_options: tts_options)
          [heading_pause, wav].compact
        end
      end.compact

      return nil if wavs.empty?

      combined = File.join(dir, "page_#{idx}.wav")
      Zipper.concat_audio(wavs, combined)
      combined
    end

    def prepare_speech_items(dir, idx, lang: 'en', stl: nil, para_context: nil, page_context: nil, book_metadata: {}, tts_options: {})
      para_count = items.count { |i| i.is_a?(Audiobook::Paragraph) }
      base_para = para_context ? para_context[:current] : 0
      total_paras = para_context ? para_context[:total] : para_count
      page_idx = page_context ? page_context[:current] : number
      page_total = page_context ? page_context[:total] : number
      is_ocr_book = !!book_metadata['fully_ocr']
      para_counter = base_para

      items.each_with_index do |item, iidx|
        if item.respond_to?(:page_idx=)
          item.page_idx = page_idx
          item.page_total = page_total
        end

        if item.is_a?(Audiobook::Paragraph)
          para_counter += 1
          item.para_idx = para_counter
          item.para_total = total_paras
          item.page_num = number
          item.item_idx = iidx + 1
          item.item_total = items.size
          item.lang = lang
          item.stl = stl
          item.dir = dir
          item.idx = "#{idx}_#{iidx}"
          item.is_ocr = is_ocr_book || item.is_a?(Audiobook::Image)
          item.tts_options = tts_options
        end
      end

      { page_idx: page_idx, page_total: page_total, is_ocr_book: is_ocr_book }
    end

    def batch_synthesize_items(dir, idx, lang, tts_options)
      jobs = speech_jobs(dir, idx, lang)
      return if jobs.empty?

      speed, options = AudioFiles.split_speed_options(tts_options)
      TTS.synthesize_batch(items: jobs, **options)
      AudioFiles.speed_all(jobs.map { |job| job[:out_path] }, speed)
    end

    def speech_jobs(dir, idx, lang)
      items.each_with_index.flat_map do |item, iidx|
        if item.is_a?(Audiobook::Paragraph)
          paragraph_jobs(item, lang)
        elsif item.respond_to?(:spoken_text)
          sentence_job(item, File.join(dir, "#{idx}_#{iidx}.wav"), lang)
        end
      end.compact
    end

    def paragraph_jobs(paragraph, lang)
      paragraph.sentences.each_with_index.flat_map do |sent, sidx|
        main = sentence_job(sent, File.join(paragraph.dir, "#{paragraph.idx}_#{sidx}.wav"), lang)
        refs = sent.references.each_with_index.flat_map do |ref, ridx|
          ref.sentences.each_with_index.map do |rs, j|
            sentence_job(rs, File.join(paragraph.dir, "#{paragraph.idx}_#{sidx}_r#{ridx}_#{j}.wav"), lang)
          end
        end
        [main, *refs]
      end
    end

    def sentence_job(sentence, out_path, lang)
      return if File.exist?(out_path)

      spoken = sentence.spoken_text
      return if spoken.empty?

      { text: spoken, lang: lang, out_path: out_path }
    end

    # Extract all sentences from all items for translation
    def all_sentences
      items.flat_map do |item|
        case item
        when Heading
          [item]  # Heading is a Sentence
        when Paragraph, Image
          # Paragraph sentences plus any reference sentences attached to them
          item.sentences.flat_map do |s|
            refs = (s.references || []).flat_map { |r| r.sentences }
            [s, *refs]
          end
        else
          []
        end
      end
    end
  end
end
