require_relative '../zipper'
require_relative 'heading'
require_relative 'paragraph'
require_relative 'image'

module Audiobook
  class Page
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

    def to_wav(dir, idx, **kwargs)
      return nil if items.empty?

      context = prepare_speech_items(dir, idx, **kwargs)
      wavs = items.each_with_index.flat_map do |item, iidx|
        if item.is_a?(Audiobook::Paragraph)
          [item.to_wav]
        else
          kwargs[:stl]&.update item_status(item, iidx, context[:page_idx], context[:page_total], ocr: context[:is_ocr_book])
          wav = item.to_wav(
            dir, "#{idx}_#{iidx}",
            lang: item.language || kwargs[:lang] || 'en',
            stl: kwargs[:stl],
            tts_options: kwargs[:tts_options] || {}
          )
          heading_pause = item.pause_file(dir) if item.respond_to?(:pause_file)
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

    def speech_jobs(dir, idx, lang)
      paragraph  = items.grep(Audiobook::Paragraph).first
      page_idx   = paragraph&.page_idx || number
      page_total = paragraph&.page_total || number

      items.each_with_index.flat_map do |item, iidx|
        if item.is_a?(Audiobook::Paragraph)
          paragraph_jobs(item, lang)
        elsif item.respond_to?(:spoken_text)
          sentence_job(item, File.join(dir, "#{idx}_#{iidx}.wav"), lang, item_status(item, iidx, page_idx, page_total))
        end
      end.compact
    end

    def paragraph_jobs(paragraph, lang)
      paragraph.sentences.each_with_index.flat_map do |sentence, sidx|
        jobs = [sentence_job(sentence, File.join(paragraph.dir, "#{paragraph.idx}_#{sidx}.wav"), lang,
                             paragraph.progress_status("sentence #{sidx + 1}/#{paragraph.sentences.size}", ocr: false))]
        sentence.references.each_with_index do |reference, ridx|
          reference.sentences.each_with_index do |referenced, idx|
            jobs << sentence_job(
              referenced,
              File.join(paragraph.dir, "#{paragraph.idx}_#{sidx}_r#{ridx}_#{idx}.wav"),
              lang,
              paragraph.progress_status("reference #{reference.id}", "sentence #{idx + 1}/#{reference.sentences.size}", ocr: false)
            )
          end
        end
        jobs.compact
      end
    end

    def item_status(item, iidx, page_idx, page_total, ocr: false)
      Audiobook.processing_status(
        "page #{page_idx}/#{page_total}", "item #{iidx + 1}/#{items.size}", item.class.name.demodulize,
        ocr: ocr
      )
    end

    def sentence_job(sentence, out_path, lang, status)
      return if File.exist?(out_path)

      text = sentence.spoken_text
      { text: text, lang: sentence.language || lang, out_path: out_path, status: status, sentence: sentence } unless text.empty?
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
