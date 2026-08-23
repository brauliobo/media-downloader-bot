require 'faraday'
require 'faraday/multipart'
require 'open3'
require 'tempfile'

require_relative '../zipper'

class VoiceSeparator
  module HTTPBackend
    def separate(path, dir:)
      FileUtils.mkdir_p(dir)
      archive = download(path)
      extract_stems(archive.path, dir)
    ensure
      archive&.close!
    end

    private

    def download(path)
      archive = Tempfile.new(["#{backend_name}-stems-", '.zip'])
      archive.binmode
      Zipper.with_copy_audio(path) do |file|
        status = stream_separate(file, archive)
        raise "voice separation failed: #{status}" unless status.to_s == '200'
      end
      archive.flush
      archive.rewind
      archive
    rescue
      archive&.close!
      raise
    end

    def stream_separate(file, archive)
      timeout = ENV.fetch('HTTP_TIMEOUT', 30 * 60).to_i
      connection = Faraday.new(url: api.to_s) do |faraday|
        faraday.request :multipart
        faraday.options.open_timeout = timeout
        faraday.options.timeout = timeout
        faraday.adapter Faraday.default_adapter
      end
      streamed = false
      response = connection.post('/v1/separate') do |request|
        request.body = {
          file: Faraday::Multipart::FilePart.new(file.path, 'application/octet-stream')
        }
        request.options.on_data = ->(chunk, *) {
          archive.write(chunk)
          streamed = true
        }
      end
      archive.write(response.body) if archive.size.zero? && !streamed && response.body
      response.status
    end

    def extract_stems(archive_path, dir)
      paths = stem_names.to_h { |name| [name, File.join(dir, name)] }
      entries = list_stem_entries(archive_path)
      names = entries.map { |entry| entry.fetch(:name) }
      raise 'voice separation returned unexpected files' unless names.all? { |name| paths.key?(name) } && names.uniq.size == names.size
      raise 'voice separation returned incomplete stems' unless names.sort == stem_names.sort

      entries.each do |entry|
        raise 'voice separation stem is too large' if entry.fetch(:size) > max_stem_bytes
      end

      extract_zip_files(archive_path, dir, stem_names)
      raise 'voice separation returned incomplete stems' unless stem_names.all? { |name| File.file?(paths.fetch(name)) }

      VoiceSeparator::Stems.new(vocals: paths.fetch('vocals.wav'), non_vocals: paths.fetch('no_vocals.wav'))
    end

    def list_stem_entries(archive_path)
      output, status = Open3.capture2({'LANG' => 'C'}, 'unzip', '-lqq', archive_path)
      raise "invalid voice separation response: unzip failed (#{status.exitstatus})" unless status.success?

      output.each_line.filter_map do |line|
        match = line.match(/\A\s*(\d+)\s+\S+\s+\S+\s+(.+?)\s*\z/)
        raise 'invalid voice separation response: unreadable zip listing' unless match

        name = match[2]
        next if name.end_with?('/')
        raise 'voice separation returned unexpected files' if name.include?('/') || name.include?('\\') || name == '..' || name == '.'

        {size: Integer(match[1]), name: name}
      end
    end

    def extract_zip_files(archive_path, dir, names)
      ok = system({'LANG' => 'C'}, 'unzip', '-o', '-j', '-qq', archive_path, *names, '-d', dir)
      raise 'invalid voice separation response: unzip failed' unless ok
    end

    def stem_names
      const_get(:STEM_NAMES)
    end

    def max_stem_bytes
      const_get(:MAX_STEM_BYTES)
    end

    def backend_name
      name.split('::').last.downcase
    end
  end
end
