require 'archive/zip'

module Utils
  module Archive
    module_function

    def validate_zip!(path, max_entries:, max_entry_bytes:, max_total_bytes:, max_ratio:)
      count = total = 0
      ::Archive::Zip.open(path) do |zip|
        zip.each do |entry|
          raise ArgumentError, 'archive has too many entries' if (count += 1) > max_entries
          next unless entry.file?

          size = entry.expected_data_descriptor or raise ArgumentError, 'archive entry has no size metadata'
          raise ArgumentError, 'archive entry is too large' if size.uncompressed_size > max_entry_bytes
          raise ArgumentError, 'archive compression ratio is too high' if size.uncompressed_size.positive? && size.compressed_size * max_ratio < size.uncompressed_size

          bytes = 0
          begin
            loop do
              chunk = entry.file_data.read(8192)
              raise ArgumentError, 'archive entry expands beyond its limit' if (bytes += chunk.bytesize) > max_entry_bytes
              raise ArgumentError, 'archive expands beyond its limit' if (total += chunk.bytesize) > max_total_bytes
            end
          rescue EOFError
          end
        end
      end
    rescue ::Archive::Zip::Error => e
      raise ArgumentError, "invalid archive: #{e.message}"
    end
  end
end
