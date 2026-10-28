module Audiobook
  module AudioFiles
    # bits/s; 64k is about a fifth of the wav and speech stays clean.
    STORED_BITRATE = ENV.fetch('SENTENCE_OPUS_BITRATE', 64_000).to_i
    # Seconds; the TTS may answer with no audio at all, which Opus cannot keep.
    STORED_MIN_DURATION = 0.02

    module_function

    def pause(seconds, dir, sample_rate: self.sample_rate, extension: '.wav', format: nil, amplitude: nil)
      options = {sample_rate: sample_rate}
      options[:format] = format.to_h.transform_keys(&:to_sym) if format
      options[:extension] = extension unless extension == '.wav'
      options[:amplitude] = amplitude if amplitude.to_f.positive?
      Zipper::Silence.pause(seconds, dir, **options)
    end

    def silence(path, seconds)
      Zipper::Silence.file(path, seconds, sample_rate: sample_rate)
    end

    # A sentence is kept as Opus, a fraction of its wav, which the tmpfs of a book cannot hold: the TTS writes the wav, this stores it
    # (at the speed asked, in the same pass) and drops it. The stored file exists only whole, so one that exists (and has content) is done.
    def compress(wav, speed: nil)
      stored = stored_path(wav)
      Utils::Atomic.write(stored) { |part| Zipper::AudioOps.compress(wav, part, codec: 'libopus', bitrate: STORED_BITRATE, speed: speed, min_duration: STORED_MIN_DURATION) }
      FileUtils.rm_f(wav)
      stored
    end

    def compress_all(wavs, speed) = wavs.map { |wav| compress(wav, speed: speed) }

    def stored_path(wav) = wav.sub(/\.wav\z/, '.opus')

    # Whether the sentence has its audio from an earlier run: a stored file that is empty is a gap to read again, not work done.
    def stored?(wav) = File.size?(stored_path(wav)).to_i.positive?

    # Joins parts, stored or not, into a wav at the sample rate of the book (an Opus part decodes at 48 kHz).
    def join(parts, wav, consumed: [])
      Zipper::AudioOps.join(parts, wav, consumed: consumed, sample_rate: sample_rate)
    end

    def split_speed_options(options)
      options ||= {}
      [options[:audio_speed], options.except(:audio_speed)]
    end

    def sample_rate
      TTS.output_sample_rate
    end
  end
end
