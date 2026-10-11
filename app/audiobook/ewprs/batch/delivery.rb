module Audiobook::Ewprs
  class Batch
    # A generated audiobook is sent to the chat, and its message edited as the stages advance.
    module Delivery
      private

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
          title:          entry.title,
          chat_id:        chat_id,
          forum_topic_id: topic[:forum_topic_id],
          message_id:     response.message_id,
          remote_id:      response.remote_id,
          duration:       seconds,
          bytes:          File.size(result[:audio]),
          audio_sha256:   result[:audio_sha256]
        )
        record[:edit_run_id] = edit_run_id if edit_run_id
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
    end
  end
end
