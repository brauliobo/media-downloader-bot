require 'digest'
require 'fileutils'
require 'time'

module Audiobook::Ewprs
  class Batch
    include Manifest
    include Delivery

    attr_reader :catalog, :output, :jobs, :published, :failures, :edited

    def initialize(catalog:, output:, jobs: 5, manifest: nil, upload_dir: nil, manager: nil, chat_id: nil, topic: nil,
                   apply: false, edit: false, regenerate: false, edit_run_id: nil, stdout: $stdout, stderr: $stderr)
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
      @edit_run_id            = edit_run_id.to_s.empty? ? nil : edit_run_id.to_s
      @stdout                 = stdout
      @stderr                 = stderr
      @failures               = []
      @edited                 = 0
      @discourse_books        = {}
      @discourse_books_mutex  = Mutex.new
      @published              = load_manifest
    end

    def run(discourses:, books:)
      discourses = edit_entries(discourses) if edit
      books      = edit_entries(books) if edit
      total = discourses.size + books.size
      process_stage(discourses, offset: 0, total: total)
      process_stage(books, offset: discourses.size, total: total)
      summary(discourses, books)
    end

    private

    attr_reader :manager, :chat_id, :topic, :stdout, :stderr, :upload_dir, :edit, :edit_run_id

    def edit_entries(entries)
      entries.select { |entry| published.key?(entry_key(entry)) }
    end

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
