require 'fileutils'

module Bot
  module Worker
    # The bot service reads album files from disk, but a worker's own directory goes away with it,
    # so the files are copied to a directory of the service's reach for as long as the send takes: under the temporary root, which
    # the service and its workers share (TMPDIR), even when they run from different trees.
    module AlbumProxy
      ROOT = File.join(Utils::Tmp.root, 'album-proxy')

      module_function

      # Yields each upload as a payload whose file sits in a directory of its own, removed afterwards.
      def stage(uploads)
        FileUtils.mkdir_p(ROOT)
        Utils::Tmp.dir('mdb-album-proxy-', ROOT) do |dir|
          yield Array(uploads).each_with_index.map { |upload, index| copy(payload(upload), dir, index) }
        end
      end

      def payload(upload)
        { fn_out: upload.fn_out.to_s, mime: upload.mime.to_s, type: ({ name: upload.type.name } if upload.type&.name) }.compact
      end

      # Telegram names the upload after the file, so only the directory carries the unique part.
      def copy(payload, dir, index)
        return payload unless File.exist?(payload[:fn_out])

        path = File.join(dir, index.to_s, File.basename(payload[:fn_out]))
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.cp(payload[:fn_out], path)
        payload.merge(fn_out: path)
      end
    end
  end
end
