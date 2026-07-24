require 'json'
require 'time'

require_relative 'book'
require_relative 'runner'
require_relative '../job_pool'
require_relative '../prober'
require_relative '../zipper'

module Audiobook
  class EwprsBatch
    attr_reader :catalog, :output, :jobs, :published, :failures

    def initialize(catalog:, output:, jobs: 5, manifest: nil, manager: nil, chat_id: nil, topic: nil, apply: false,
                   stdout: $stdout, stderr: $stderr)
      raise ArgumentError, 'jobs must be positive' unless jobs.to_i.positive?

      @catalog       = catalog
      @output        = File.expand_path(output)
      @manifest_path = File.expand_path(manifest || File.join(@output, 'published.jsonl'))
      @jobs          = jobs.to_i
      @manager       = manager
      @chat_id       = chat_id
      @topic         = topic
      @apply         = apply
      @stdout        = stdout
      @stderr        = stderr
      @failures      = []
      @published     = load_manifest
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

    attr_reader :manager, :chat_id, :topic, :stdout, :stderr

    def process_stage(entries, offset:, total:)
      return if entries.empty?

      current = nil
      checkpoints = entries.map { |entry| checkpointed?(entry) }
      work = entries.each_with_index.map do |entry, index|
        [entry, index]
      end
      JobPool.new(jobs: jobs).ordered_map(work) do |entry, index|
        result = begin
          generate_entry(entry) unless checkpoints[index]
        rescue => error
          {error: error}
        end
        {entry: entry, index: index, result: result}
      end.each do |item|
        entry    = item[:entry]
        index    = item[:index]
        result   = item[:result]
        current  = entry
        position = offset + index + 1
        if checkpoints[index]
          stdout.puts "#{position}/#{total} checkpointed: #{entry.title}"
          next
        end

        raise result[:error] if result[:error]

        stdout.puts generation_message(entry, result, position, total)
        upload_entry(entry, result[:audio], result[:chapter_count], position, total) if @apply
      end
    rescue => error
      record_failure(@apply ? 'generate_or_upload' : 'generate', current, error)
      raise
    end

    def generate_entry(entry)
      if entry.kind == :book
        audio, chapter_count = generate_book(entry)
        {audio: audio, chapter_count: chapter_count}
      else
        {audio: generate_discourse(entry), chapter_count: nil}
      end
    end

    def generate_discourse(entry)
      base  = File.join(output, entry.slug)
      audio = audio_path(entry)
      return audio if File.size?(audio)

      options = catalog.parse_options(entry)
      book    = Audiobook::Book.from_input(entry.path, opts: options)
      raise "no speakable content: #{entry.path}" if book.items.empty?

      book.write("#{base}.yml")
      Audiobook::Runner.new(book, nil, options).process_to_audio(audio)
    end

    def generate_book(entry)
      audio    = audio_path(entry)
      chapters = catalog.chapter_discourses(entry)
      raise 'no mapped discourse chapters' if chapters.empty?

      unless File.size?(audio)
        inputs = chapters.map { |chapter| generate_discourse(chapter) }
        Zipper.concat_audio(inputs, audio)
      end
      [audio, chapters.size]
    end

    def upload_entry(entry, audio, chapter_count, position, total)
      seconds = Prober.for(audio).format.duration.to_f.round
      result  = manager.upload_generated_media(
        chat_id: chat_id, forum_topic_id: topic[:forum_topic_id], text: caption(entry, seconds, chapter_count),
        type: :audio, parse_mode: nil, audio_path: audio, duration: seconds,
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
    end

    def caption(entry, seconds, chapter_count)
      minutes, secs = seconds.divmod(60)
      [
        entry.title,
        'P. R. Sarkar',
        "Type: #{entry.kind.to_s.capitalize}",
        ("Date/place: #{entry.info}" if entry.info.present?),
        ("Published in: #{entry.sources.join('; ')}" if entry.sources.present?),
        ("Chapters: #{chapter_count}/#{entry.chapters.size}" if entry.kind == :book),
        'Language: English',
        format('Duration: %d:%02d', minutes, secs)
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
      @apply && published.key?(entry_key(entry))
    end

    def entry_key(entry)
      "#{entry.kind}:#{entry.slug}"
    end

    def manifest_path
      @manifest_path
    end

    def load_manifest
      return {} unless File.exist?(manifest_path)

      File.foreach(manifest_path).each_with_object({}) do |line, records|
        next if line.strip.empty?

        record = JSON.parse(line, symbolize_names: true)
        records["#{record.fetch(:kind)}:#{record.fetch(:slug)}"] = record
      end
    end

    def append_record(record)
      File.open(manifest_path, 'a') do |file|
        file.puts JSON.generate(record)
        file.flush
        file.fsync
      end
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
      File.open(File.join(output, 'failures.jsonl'), 'a') do |file|
        file.puts JSON.generate(failure)
        file.flush
        file.fsync
      end
      stderr.puts JSON.generate(failure)
    end

    def summary(discourses, books)
      {
        chat:                  @apply ? {id: chat_id} : nil,
        topic:                 topic,
        generated_discourses: discourses.count { |entry| File.size?(audio_path(entry)) },
        generated_books:      books.count { |entry| File.size?(audio_path(entry)) },
        published:             published.size,
        failures:              failures.size
      }
    end
  end
end
