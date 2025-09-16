require 'mechanize'
require 'tempfile'
require 'fileutils'
require_relative '../zipper'

class TTS
  module CoquiTTS
    PORT = (ENV['PORT'] || 10230).to_i
    BASE_URL = "http://127.0.0.1:#{PORT}".freeze
    SYNTH_PATH = '/synthesize'.freeze
    MAX_TOKENS = 400
    CHUNK_CHARS = 500

    def synthesize(text:, lang:, out_path:, speaker_wav: nil, **kwargs)
      agent, url = Mechanize.new, "#{BASE_URL}#{SYNTH_PATH}"
      clean_text = text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')

      # Build safe chunks first by sentences, then by words for long sentences
      sents = clean_text.split(/(?<=[\.!?…])\s+/)
      chunks, buf = [], ''
      sents.each do |s|
        if (buf.empty? ? s.length : buf.length + 1 + s.length) > CHUNK_CHARS
          chunks << buf unless buf.empty?
          buf = s
          if s.length > CHUNK_CHARS
            words, wbuf = s.split(/\s+/), ''
            words.each do |w|
              if (wbuf.empty? ? w.length : wbuf.length + 1 + w.length) > CHUNK_CHARS
                chunks << wbuf unless wbuf.empty?
                wbuf = w
              else
                wbuf = wbuf.empty? ? w : "#{wbuf} #{w}"
              end
            end
            chunks << wbuf unless wbuf.empty?
            buf = ''
          end
        else
          buf = buf.empty? ? s : "#{buf} #{s}"
        end
      end
      chunks << buf unless buf.empty?

      # If everything was small, keep single chunk
      chunks = [clean_text] if chunks.empty?

      Dir.mktmpdir do |dir|
        wavs = []

        synth = lambda do |payload, index|
          form = { 'text' => payload, 'language' => lang }
          spk_wav = speaker_wav || ENV['SPEAKER_WAV']
          file = (File.open(spk_wav) if spk_wav && !spk_wav.empty? && File.exist?(spk_wav))
          form['audio'] = file if file
          kwargs.each { |k, v| form[k.to_s] = v.to_s }
          begin
            res = agent.post(url, form)
            raise "TTS failed: #{res.code}" unless res.code == '200'
            wav = File.join(dir, format('%04d.wav', index))
            File.binwrite(wav, res.body)
            wavs << wav
          rescue Mechanize::ResponseCodeError => e
            body = e.page&.body.to_s
            if e.response_code.to_s == '500' && body.include?('maximum of 400 tokens') && payload.length > 50
              mid = payload.length / 2
              left  = payload[0...mid].rstrip
              right = payload[mid..-1].lstrip
              synth.call(left, index)
              synth.call(right, index + 1)
            else
              raise "TTS failed with #{e.response_code}: #{body}"
            end
          ensure
            file&.close
          end
        end

        idx = 1
        chunks.each do |c|
          synth.call(c, idx)
          idx = wavs.size + 1
        end

        if wavs.size == 1
          FileUtils.cp(wavs.first, out_path)
        else
          combined = File.join(dir, 'combined.wav')
          Zipper.concat_audio(wavs, combined)
          FileUtils.cp(combined, out_path)
        end
      end
    rescue Mechanize::ResponseCodeError => e
      puts "[ERROR] TTS Server Error: #{e.response_code}"
      puts "[ERROR] Response Body: #{e.page&.body}"
      puts "[ERROR] Text length: #{clean_text.length}"
      puts "[ERROR] Text sample: '#{clean_text[0..200]}...'"
      raise "TTS failed with #{e.response_code}: #{e.page&.body}"
    rescue => e
      puts "[ERROR] TTS Request Error: #{e.class}: #{e.message}"
      puts "[ERROR] Text length: #{clean_text.length}"
      puts "[ERROR] Text sample: '#{clean_text[0..200]}...'"
      raise e
    end
  end

end
