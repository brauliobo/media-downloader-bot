# Uploads a source format that already fits the bot's size limit instead of transcoding it.
module Streaming
  # Options that change the encoded streams, so the download can't be uploaded as is.
  # Not listed on purpose: ss, to and t (yt-dlp cuts that section while downloading, --download-sections)
  # and audio (an audio-only format is uploaded as is; audio re-encoding is what abrate, acodec, ... ask for).
  ENCODING_OPTS = {
    # re-encode the video stream
    video:     %i[format width quality vf vbrate preserve_resolution mpdecimate nompdecimate maxfr keyframes camera],
    # re-encode or drop the audio stream
    audio:     %i[abrate bitrate acodec noaudio no_audio freq ar ac voice_quality speech_cleanup],
    # edit the timeline: cuts= removes intervals from the middle, which yt-dlp can't do while downloading
    timeline:  %i[speed cuts silences],
    # replace the audio (dub) or burn/mux subtitles into the file
    dub_subs:  %i[dub sub subs subtitle sub_vtt sub_mode sub_lang slang gensubs],
    # produce something other than the video itself
    other:     %i[onlysrt genshorts],
  }.freeze
  ENCODING_KEYS = ENCODING_OPTS.values.flatten.freeze

  module_function

  # On by default for non admins, for admins only with `stream`; never with `nostream` or an encoding option.
  def enabled?(opts, admin:)
    Zipper.size_mb_limit.present? && (!admin || opts.stream.present?) && opts.nostream.blank? &&
      ENCODING_KEYS.none? { |key| opts[key].present? }
  end

  def fits?(path) = ::File.size(path) < Zipper.size_mb_limit * 2**20
end
