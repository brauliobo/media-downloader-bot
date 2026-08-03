require 'digest'
require 'fileutils'
require 'time'

require_relative '../book'
require_relative '../chapter'
require_relative '../runner'
require_relative '../../job_pool'
require_relative '../../jsonl_store'
require_relative '../../prober'
require_relative '../../zipper'

module Audiobook::Ewprs
  class Batch
    attr_reader :catalog, :output, :jobs, :published, :failures, :edited

    def initialize(catalog:, output:, jobs: 5, manifest: nil, upload_dir: nil, manager: nil, chat_id: nil, topic: nil,
                   apply: false, edit: false, regenerate: false, stdout: $stdout, stderr: $stderr)
      raise ArgumentError, 'jobs must be positive' unless jobs.to_i.positive?

      @catalog                = catalog
      @output                 = File.expand_path(output)
      manifest_path           = File.expand_path(manifest || File.join(@output, 'published.jsonl'))
      @manifest               = JsonlStore.new(manifest_path)
      @failure_log            = JsonlStore.new(File.join(@output, 'failures.jsonl'))
      @upload_dir             = File.expand_path(upload_dir) if upload_dir
      @jobs                   = jobs.to_i
      @manager                = manager
      @chat_id                = chat_id
      @topic                  = topic
      @apply                  = apply
      @edit                   = edit
      @regenerate             = regenerate
      @stdout                 = stdout
      @stderr                 = stderr
      @failures               = []
      @edited                 = 0
      @discourse_books        = {}
      @discourse_books_mutex  = Mutex.new
      @published              = load_manifest
    end

    def run(discourses:, books:)
      total = discourses.size + books.size
      process_stage(discourses, offset: 0, total: total)
      process_stage(books, offset: discourses.size, total: total)
      summary(discourses, books)
    end

    def record(entry, message_id:, remote_id: nil)
      append_record(
        at:         Time.now.utc.iso8601,
        kind:       entry.kind,
        slug:       entry.slug,
        title:      entry.title,
        message_id: message_id.to_i,
        remote_id:  remote_id
      )
    end

    private

    attr_reader :manager, :chat_id, :topic, :stdout, :stderr, :upload_dir

    def process_stage(entries, offset:, total:)
      return if entries.empty?

      current = nil
      checkpoints = entries.map { |entry| checkpointed?(entry) }
      perform = lambda do |entry, index|
        prepare_entry(entry) unless checkpoints[index]
      end
      JobPool.new(jobs: jobs).ordered_each(entries, perform: perform) do |entry, result, index|
        current  = entry
        position = offset + index + 1
        if checkpoints[index]
          stdout.puts "#{position}/#{total} checkpointed: #{entry.title}"
          next
        end

        if @edit
          edit_entry(entry, result, position, total)
        else
          stdout.puts generation_message(entry, result, position, total)
          upload_entry(entry, result[:audio], result[:chapter_count], position, total) if @apply
        end
      end
    rescue => error
      entry    = error.is_a?(JobPool::TaskError) ? error.item : current
      original = error.is_a?(JobPool::TaskError) ? error.original : error
      stage = @edit ? 'edit' : (@apply ? 'generate_or_upload' : 'generate')
      record_failure(stage, entry, original)
      raise original
    end

    def prepare_entry(entry)
      return generate_entry(entry, force: @regenerate) unless @edit

      published.fetch(entry_key(entry))
      result = @regenerate ? generate_entry(entry, force: true) : existing_entry(entry)
      result.merge(audio_sha256: audio_sha256(result[:audio]))
    end

    def generate_entry(entry, force: false)
      if entry.kind == :book
        audio, chapter_count = generate_book(entry, force: force)
        {audio: audio, chapter_count: chapter_count}
      else
        {audio: generate_discourse(entry, force: force), chapter_count: nil}
      end
    end

    def existing_entry(entry)
      audio = audio_path(entry)
      raise "audiobook audio not found: #{audio}" unless File.size?(audio)

      chapter_count = catalog.chapter_discourses(entry).size if entry.kind == :book
      {audio: audio, chapter_count: chapter_count}
    end

    def generate_discourse(entry, force: false)
      base  = File.join(output, entry.slug)
      audio = audio_path(entry)
      return audio if !force && File.size?(audio)

      options = catalog.parse_options(entry)
      book    = discourse_book(entry, options)
      raise "no speakable content: #{entry.path}" if book.items.empty?

      book.write("#{base}.yml")
      Audiobook::Runner.new(book, nil, options).process_to_audio(audio)
    end

    def generate_book(entry, force: false)
      audio             = audio_path(entry)
      chapter_entries   = catalog.chapter_discourses(entry)
      raise 'no mapped discourse chapters' if chapter_entries.empty?

      if force || !File.size?(audio)
        chapters = chapter_entries.map { |chapter| audiobook_chapter(chapter) }
        Audiobook::Chapter.join(chapters, audio)
      end
      [audio, chapter_entries.size]
    end

    def audiobook_chapter(entry)
      audio = generate_discourse(entry)
      book  = cached_discourse_book(entry) || discourse_book(entry, catalog.parse_options(entry))
      Audiobook::Chapter.new(
        title: entry.title,
        audio: audio,
        sections: book.items.grep(Audiobook::Section)
      )
    end

    def discourse_book(entry, options)
      cached_discourse_book(entry) || begin
        book = Audiobook::Book.from_input(entry.path, opts: options)
        @discourse_books_mutex.synchronize { @discourse_books[entry_key(entry)] ||= book }
      end
    end

    def cached_discourse_book(entry)
      @discourse_books_mutex.synchronize { @discourse_books[entry_key(entry)] }
    end

    def upload_entry(entry, audio, chapter_count, position, total)
      seconds      = Prober.for(audio).format.duration.to_f.round
      upload_audio = stage_upload(audio)
      result       = manager.upload_generated_media(
        chat_id: chat_id, forum_topic_id: topic[:forum_topic_id], text: caption(entry, seconds, chapter_count),
        type: :audio, parse_mode: nil, audio_path: upload_audio, duration: seconds,
        title: entry.title, performer: 'P. R. Sarkar', copy: false
      )
      raise 'upload returned no message ID' unless result[:message_id].to_i.positive?
      raise 'upload returned no remote file ID' if result[:remote_id].to_s.empty?

      record = {
        at:             Time.now.utc.iso8601,
        kind:           entry.kind,
        slug:           entry.slug,
        title:          entry.title,
        chat_id:        chat_id,
        forum_topic_id: topic[:forum_topic_id],
        message_id:     result[:message_id],
        remote_id:      result[:remote_id],
        duration:       seconds,
        bytes:          File.size(audio)
      }
      append_record(record)
      stdout.puts JSON.generate(progress: "#{position}/#{total}", checkpointed: record)
    ensure
      FileUtils.rm_f(upload_audio) if upload_audio && upload_audio != audio
    end

    def edit_entry(entry, result, position, total)
      previous     = published.fetch(entry_key(entry))
      message_id   = previous.fetch(:message_id).to_i
      seconds      = Prober.for(result[:audio]).format.duration.to_f.round
      upload_audio = stage_upload(result[:audio])
      response     = SymMash.new(manager.edit_generated_message(
        chat_id: chat_id, message_id: message_id, text: caption(entry, seconds, result[:chapter_count]),
        type: :audio, parse_mode: nil, audio_path: upload_audio, duration: seconds,
        title: entry.title, performer: 'P. R. Sarkar', copy: false
      ))
      raise 'edit returned no message ID' unless response.message_id.to_i.positive?
      raise 'edit returned no remote file ID' if response.remote_id.to_s.empty?

      record = previous.merge(
        at:             Time.now.utc.iso8601,
        operation:      'edit',
        chat_id:        chat_id,
        forum_topic_id: topic[:forum_topic_id],
        message_id:     response.message_id,
        remote_id:      response.remote_id,
        duration:       seconds,
        bytes:          File.size(result[:audio]),
        audio_sha256:   result[:audio_sha256]
      )
      append_record(record)
      @edited += 1
      stdout.puts JSON.generate(progress: "#{position}/#{total}", edited: record)
    ensure
      FileUtils.rm_f(upload_audio) if upload_audio && upload_audio != result&.dig(:audio)
    end

    def stage_upload(audio)
      return audio unless upload_dir

      FileUtils.mkdir_p(upload_dir)
      staged = File.join(upload_dir, File.basename(audio))
      return audio if staged == audio

      FileUtils.cp(audio, staged)
      staged
    end

    def caption(entry, _seconds, chapter_count)
      locale = catalog.language
      scope  = 'audiobook.ewprs.caption'
      text   = lambda do |key, **options|
        I18n.t(key, locale: locale, scope: scope, raise: true, **options)
      end
      [
        entry.title,
        'P. R. Sarkar',
        text.call(:type, kind: text.call("kinds.#{entry.kind}")),
        (text.call(:date_place, value: entry.info) if entry.info.present?),
        (text.call(:published_in, value: entry.sources.join('; ')) if entry.sources.present?),
        (text.call(:chapters, count: chapter_count, total: entry.chapters.size) if entry.kind == :book),
        text.call(:language, language: text.call("languages.#{locale}"))
      ].compact.join("\n")
    end

    def generation_message(entry, result, position, total)
      details = if entry.kind == :book
        " (#{result[:chapter_count]}/#{entry.chapters.size} chapters)"
      else
        ''
      end
      "#{position}/#{total} generated #{entry.kind}: #{entry.title}#{details}"
    end

    def audio_path(entry)
      prefix = entry.kind == :book ? 'book-' : ''
      File.join(output, "#{prefix}#{entry.slug}.m4a")
    end

    def checkpointed?(entry)
      return false unless @apply && published.key?(entry_key(entry))
      previous = published[entry_key(entry)]
      return true unless @edit
      return true if previous[:operation] == 'edit'

      expected = previous[:audio_sha256]
      audio    = audio_path(entry)
      expected.present? && File.size?(audio) && expected == audio_sha256(audio)
    end

    def audio_sha256(audio)
      Digest::SHA256.file(audio).hexdigest
    end

    def entry_key(entry)
      "#{entry.kind}:#{entry.slug}"
    end

    def load_manifest
      @manifest.each_with_object({}) do |record, records|
        records["#{record.fetch(:kind)}:#{record.fetch(:slug)}"] = record
      end
    end

    def append_record(record)
      @manifest.append(record)
      published["#{record.fetch(:kind)}:#{record.fetch(:slug)}"] = record
      record
    end

    def record_failure(stage, entry, error)
      failure = {
        at:    Time.now.utc.iso8601,
        stage: stage,
        kind:  entry.kind,
        slug:  entry.slug,
        title: entry.title,
        error: "#{error.class}: #{error.message}"
      }
      failures << failure
      @failure_log.append(failure)
      stderr.puts JSON.generate(failure)
    end

    def summary(discourses, books)
      {
        chat:                  @apply ? {id: chat_id} : nil,
        topic:                 topic,
        generated_discourses: discourses.count { |entry| File.size?(audio_path(entry)) },
        generated_books:      books.count { |entry| File.size?(audio_path(entry)) },
        published:             published.size,
        edited:                edited,
        failures:              failures.size
      }
    end
  end
end
