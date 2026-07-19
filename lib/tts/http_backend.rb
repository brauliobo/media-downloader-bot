require 'uri'
require 'base64'
require 'json'
require 'tempfile'
require 'fileutils'

require_relative '../zipper'

class TTS
  module HTTPBackend
    extend ActiveSupport::Concern

    included do
      mattr_accessor :base_url
      mattr_accessor :segment_chars
      mattr_accessor :segment
      mattr_accessor :synth_path
      mattr_accessor :batch_synth_path
      mattr_accessor :stable_voice_reference
    end

    class_methods do
      def configure_backend(base_url:, segment_chars: 500, synth_path: '/synthesize', batch_synth_path: nil, segment: true, stable_voice_reference: false)
        self.base_url               = base_url
        self.segment_chars          = segment_chars
        self.segment                = segment
        self.synth_path             = synth_path
        self.batch_synth_path       = batch_synth_path
        self.stable_voice_reference = stable_voice_reference
      end
    end

    def supports_stable_voice_reference?
      stable_voice_reference
    end

    def synthesize(text:, lang:, out_path:, speaker_wav: nil, **kwargs)
      http_synthesize(text: text, lang: lang, out_path: out_path, speaker_wav: speaker_wav, **kwargs)
    end

    def synthesize_batch(items:, lang: nil, speaker_wav: nil, **kwargs)
      out_paths = []
      payload = items.map do |item|
        item = item.to_h.symbolize_keys
        out_paths << item.fetch(:out_path)
        {
          text:     item.fetch(:text).to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: ''),
          language: (item[:lang] || lang).to_s,
        }
      end
      form = { 'items' => JSON.dump(payload) }
      kwargs.each { |key, value| form[key.to_s] = value.to_s }

      response = post_form(
        Utils::HTTP.client,
        "#{base_url}#{batch_synth_path}",
        form,
        speaker_wav || ENV['SPEAKER_WAV']
      )
      raise "TTS batch failed: #{response.code}" unless response.code == '200'

      audios = JSON.parse(response.body).fetch('items')
      raise "TTS batch returned #{audios.size} items for #{out_paths.size} requests" unless audios.size == out_paths.size

      audios.each_with_index do |item, idx|
        File.binwrite(out_paths[idx], Base64.decode64(item.fetch('audio')))
      end
      out_paths
    end

    private

    def http_synthesize(text:, lang:, out_path:, speaker_wav: nil, **kwargs)
      agent, url = Utils::HTTP.client, "#{self.base_url}#{self.synth_path}"
      clean_text = text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      segments = self.segment ? segment_text(clean_text, self.segment_chars) : [clean_text]

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
      file_path = spk_wav if spk_wav && !spk_wav.empty? && File.exist?(spk_wav)
      form = { 'text' => payload, 'language' => lang }
      kwargs.each { |k, v| form[k.to_s] = v.to_s }

      res = post_form(agent, url, form, file_path)
      raise "TTS failed: #{res.code}" unless res.code == '200'

      File.binwrite(wav, res.body)
      wav
    end

    def post_form(agent, url, form, file_path)
      return agent.post(url, form) unless file_path

      File.open(file_path) do |file|
        form['audio'] = file
        agent.post(url, form)
      end
    end

    def assemble_output(wavs, out_path, dir)
      return FileUtils.cp(wavs.first, out_path) if wavs.one?

      combined = File.join(dir, 'combined.wav')
      Zipper.concat_audio(wavs, combined)
      FileUtils.cp(combined, out_path)
    end
  end
end
