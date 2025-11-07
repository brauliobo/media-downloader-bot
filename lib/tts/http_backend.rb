require 'uri'
require 'tempfile'
require 'fileutils'
require 'concurrent'

require_relative '../zipper'

class TTS
  module HTTPBackend
    extend ActiveSupport::Concern

    included do
      mattr_accessor :base_url
      mattr_accessor :segment_chars
      mattr_accessor :synth_path
      mattr_accessor :semaphore
    end

    class_methods do
      def configure_backend(base_url:, segment_chars: 500, concurrency: 1, synth_path: '/synthesize')
        self.base_url    = base_url
        self.segment_chars = segment_chars
        self.synth_path  = synth_path
        self.semaphore   = Concurrent::Semaphore.new(concurrency)
      end
    end

    def synthesize(text:, lang:, out_path:, speaker_wav: nil, **kwargs)
      self.semaphore.acquire
      http_synthesize(text: text, lang: lang, out_path: out_path, speaker_wav: speaker_wav, **kwargs)
    ensure
      self.semaphore.release
    end

    private

    def http_synthesize(text:, lang:, out_path:, speaker_wav: nil, **kwargs)
      agent, url = Utils::HTTP.client, "#{self.base_url}#{self.synth_path}"
      clean_text = text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      segments = segment_text(clean_text, self.segment_chars)

      Dir.mktmpdir do |dir|
        wavs = []
        segments.each_with_index do |payload, idx|
          wavs << synth_segment(agent, url, payload, lang, speaker_wav, kwargs, dir, idx + 1)
        end
        assemble_output(wavs, out_path, dir)
      end
    end

      def segment_text(text, limit)
        return [text] if text.size <= limit
        sents = text.split(/(?<=[.!?…:;])\s+/)
        segments = []
        buf = +''
        sents.each do |part|
          if buf.empty?
            buf = part
          elsif (buf.size + 1 + part.size) <= limit
            buf << ' ' << part
          else
            segments << buf
            buf = part
          end
        end
        segments << buf unless buf.empty?
        # Hard split leftovers exceeding limit (no sentence boundaries found)
        final = []
        segments.each do |seg|
          if seg.size <= limit
            final << seg
          else
            seg.scan(/.{1,#{limit}}/m) { |chunk| final << chunk }
          end
        end
        final
      end

    def synth_segment(agent, url, payload, lang, speaker_wav, kwargs, dir, idx)
      wav = File.join(dir, format('%04d.wav', idx))
      spk_wav = speaker_wav || ENV['SPEAKER_WAV']
      has_file = spk_wav && !spk_wav.empty? && File.exist?(spk_wav)
      form = { 'text' => payload, 'language' => lang }
      kwargs.each { |k, v| form[k.to_s] = v.to_s }

      if has_file
        file = File.open(spk_wav)
        begin
          form['audio'] = file
          res = agent.post(url, form)
          raise "TTS failed: #{res.code}" unless res.code == '200'
          File.binwrite(wav, res.body)
        ensure
          file&.close
        end
      else
        res = agent.post(url, form)
        raise "TTS failed: #{res.code}" unless res.code == '200'
        File.binwrite(wav, res.body)
      end
      wav
    end

    def assemble_output(wavs, out_path, dir)
      return FileUtils.cp(wavs.first, out_path) if wavs.one?

      combined = File.join(dir, 'combined.wav')
      Zipper.concat_audio(wavs, combined)
      FileUtils.cp(combined, out_path)
    end
  end
end
