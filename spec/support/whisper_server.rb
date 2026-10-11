require_relative 'media_files'

# The whisper HTTP service: answers every inference with the transcription it was given and remembers the request,
# with the audio file as the service receives it (its first bytes).
module WhisperServer
  include MediaFiles

  class Fake
    attr_reader :requests
    attr_accessor :transcription

    def initialize = @requests = []

    def post(url, params)
      requests << {url: url, **params.merge(file: File.binread(params[:file].path, 4))}
      http_response(JSON.generate(transcription))
    end
  end

  def whisper_server
    @whisper_server ||= Fake.new.tap do |server|
      allow(Utils::HTTP).to receive(:post) { |url, params| server.post(url, params) }
    end
  end

  # What the service transcribes, whatever the audio.
  def whisper_says(**transcription) = whisper_server.transcription = transcription
end
