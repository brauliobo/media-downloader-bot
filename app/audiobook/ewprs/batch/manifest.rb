module Audiobook::Ewprs
  class Batch
    # What has been done is written down as it happens, so a rerun starts after the last entry that finished.
    module Manifest
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

      def checkpointed?(entry)
        return false unless @apply && published.key?(entry_key(entry))
        previous = published[entry_key(entry)]
        return true unless @edit
        return previous[:operation] == 'edit' && previous[:edit_run_id] == edit_run_id if edit_run_id
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
    end
  end
end
