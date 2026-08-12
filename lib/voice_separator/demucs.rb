require 'archive/zip'
require 'faraday'
require 'faraday/multipart'
require 'tempfile'
require 'uri'

class VoiceSeparator
  module Demucs
    MAX_STEM_BYTES = ENV.fetch('VOICE_SEPARATOR_MAX_STEM_BYTES', 2 * 1024 * 1024 * 1024).to_i

    mattr_accessor :api
    self.api = URI.parse(ENV.fetch('DEMUCS_SERVER', 'http://127.0.0.1:8084'))

    module_function

    def separate(path, dir:)
      FileUtils.mkdir_p(dir)
      archive = download(path)
      extract_stems(archive.path, dir)
    ensure
      archive&.close!
    end

    def download(path)
      archive = Tempfile.new(['demucs-stems-', '.zip'])
      connection = Faraday.new(url: api.to_s) do |faraday|
        faraday.request :multipart
        faraday.adapter Faraday.default_adapter
      end
      connection.options.timeout = ENV.fetch('HTTP_TIMEOUT', 30 * 60).to_i
      response = connection.post('/v1/separate') do |request|
        request.body = {
          file: Faraday::Multipart::FilePart.new(path, 'application/octet-stream')
        }
        request.options.on_data = ->(chunk, _bytes, _env) { archive.write(chunk) }
      end
      raise "voice separation failed: #{response.status}" unless response.success?

      archive.flush
      archive.rewind
      archive
    rescue
      archive&.close!
      raise
    end
    private_class_method :download

    def extract_stems(archive_path, dir)
      paths = {
        'vocals.wav'    => File.join(dir, 'vocals.wav'),
        'no_vocals.wav' => File.join(dir, 'no_vocals.wav')
      }
      seen = []
      Archive::Zip.open(archive_path) do |zip|
        zip.each do |entry|
          next unless entry.file?

          output = paths[entry.zip_path]
          raise 'voice separation returned unexpected files' unless output && !seen.include?(entry.zip_path)

          size = entry.expected_data_descriptor or raise 'voice separation stem has no size metadata'
          raise 'voice separation stem is too large' if size.uncompressed_size > MAX_STEM_BYTES

          entry.extract(file_path: output)
          seen << entry.zip_path
        end
      end
      raise 'voice separation returned incomplete stems' unless seen.sort == paths.keys.sort

      VoiceSeparator::Stems.new(vocals: paths.fetch('vocals.wav'), non_vocals: paths.fetch('no_vocals.wav'))
    rescue Archive::Zip::Error => e
      raise "invalid voice separation response: #{e.message}"
    end
    private_class_method :extract_stems

    extend self
  end
end
