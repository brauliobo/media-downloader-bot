class FFmpeg
  module Builder
    # The encoders a format asks for, with their quality and speed settings.
    module Encoding
      def encode_video format, cuda:, quality:, preset: nil
        encoder = VIDEO_ENCODERS.fetch format.to_sym
        mode    = cuda ? :cuda : :cpu
        codec   = encoder[:"codec_#{mode}"] || encoder.fetch(:codec_cpu)
        qmode   = encoder[:"quality_#{mode}"] || encoder[:quality_cpu]
        preset ||= encoder[:"preset_#{mode}"]

        self.cuda encode: cuda
        self.codec codec, stream: :video
        self.quality quality, mode: qmode if qmode && !quality.nil?
        self.preset preset if preset
        return self unless cuda

        tune encoder[:tune_cuda] if encoder[:tune_cuda]
        multipass encoder[:multipass_cuda] if encoder[:multipass_cuda]
        adaptive_quantization if encoder[:aq_cuda]
        lookahead encoder[:lookahead_cuda] if encoder[:lookahead_cuda]
        bitrate encoder[:bitrate_cuda], stream: :video, unit: :bit if encoder.key? :bitrate_cuda
        self
      end

      def encode_audio format, bitrate:
        encoder = AUDIO_ENCODERS.fetch format.to_sym
        use_fdk = format.to_sym == :aac && @fdk_aac

        channels encoder[:channels] if encoder[:channels]
        sample_rate encoder[:sample_rate] if encoder[:sample_rate]
        codec(use_fdk ? encoder.fetch(:codec_fdk) : encoder.fetch(:codec), stream: :audio)
        codec_profile encoder.fetch(:profile_fdk), stream: :audio if use_fdk
        average_bitrate if encoder[:abr]
        variable_bitrate encoder[:vbr] if encoder[:vbr]
        self.bitrate bitrate, stream: :audio
      end

      def quality value, mode: :auto
        set_semantic_operation [:quality], kind: :quality, value: value, mode: mode.to_sym
      end

      def preset value
        set_operation [:preset], '-preset', value
      end

      def tune value
        set_operation [:tune], '-tune', value
      end

      def multipass value
        set_operation [:multipass], '-multipass', value
      end

      def adaptive_quantization spatial: true, temporal: true
        set_operation [:spatial_aq], '-spatial-aq', boolean_value(spatial)
        set_operation [:temporal_aq], '-temporal-aq', boolean_value(temporal)
        self
      end

      def lookahead value
        set_operation [:lookahead], '-rc-lookahead', value
      end
    end
  end
end
