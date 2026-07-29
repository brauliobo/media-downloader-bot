require 'json'
require 'open3'
require 'tempfile'

require_relative 'whisper_cpp'

class Subtitler
  module TranscribeCpp
    include WhisperCpp

    mattr_accessor :cli, :model, :language, :backend, :device, :threads, :ffmpeg
    self.cli      = ENV['TRANSCRIBE_CPP_CLI']
    self.model    = ENV['TRANSCRIBE_CPP_MODEL']
    self.language = ENV.fetch('TRANSCRIBE_CPP_LANGUAGE', 'en')
    self.backend  = ENV.fetch('TRANSCRIBE_CPP_BACKEND', 'auto')
    self.device   = ENV['TRANSCRIBE_CPP_DEVICE']
    self.threads  = ENV['TRANSCRIBE_CPP_THREADS']
    self.ffmpeg   = ENV.fetch('TRANSCRIBE_CPP_FFMPEG', 'ffmpeg')

    def transcribe(path, format: 'verbose_json', merge_words: true, language: self.language, **)
      raise ArgumentError, "unsupported transcribe.cpp format: #{format}" unless format.to_s.include?('json')
      raise 'TRANSCRIBE_CPP_CLI is not configured' if cli.blank?
      raise 'TRANSCRIBE_CPP_MODEL is not configured' if model.blank?

      output = normalize_result(run_cli(path, language: language))
      SymMash.new(output: output, lang: Subtitler.normalize_lang(output[:language]))
    end

    private

    def run_cli(path, language:)
      wav = Tempfile.new(['transcribe-cpp-', '.wav'])
      result = Tempfile.new(['transcribe-cpp-', '.json'])
      wav.close
      result.close

      _, ffmpeg_error, ffmpeg_status = Open3.capture3(
        ffmpeg, '-y', '-i', path.to_s, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wav.path
      )
      raise "ffmpeg failed: #{ffmpeg_error}" unless ffmpeg_status.success?

      command = [
        cli, '--quiet', '--model', model, '--language', language.to_s,
        '--timestamps', 'word', '--backend', backend, '--output-json', result.path
      ]
      command.concat(['--device', device.to_s]) if device.present?
      command.concat(['--threads', threads.to_s]) if threads.present?
      command << wav.path

      _, transcribe_error, transcribe_status = Open3.capture3(*command)
      raise "transcribe.cpp failed: #{transcribe_error}" unless transcribe_status.success?

      JSON.parse(File.read(result.path))
    ensure
      wav&.close!
      result&.close!
    end

    def normalize_result(raw)
      {
        language: raw.fetch('language'),
        text: raw.fetch('text'),
        segments: raw.fetch('segments').map do |segment|
          {
            start: segment.fetch('t0_ms') / 1000.0,
            end: segment.fetch('t1_ms') / 1000.0,
            text: segment.fetch('text'),
            words: segment.fetch('words').map do |word|
              {
                word: word.fetch('text'),
                start: word.fetch('t0_ms') / 1000.0,
                end: word.fetch('t1_ms') / 1000.0
              }
            end
          }
        end
      }
    end
  end
end
