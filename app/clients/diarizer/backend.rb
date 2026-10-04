require 'uri'

class Diarizer
  # Every diarizer backend is the same service behind a different name and port.
  module Backend
    def self.extended(base) = base.singleton_class.send(:attr_accessor, :api)

    def server(env, port) = self.api = URI.parse(ENV.fetch(env, "http://127.0.0.1:#{port}"))

    def diarize(path, speakers: nil) = HTTPBackend.diarize(api, path, speakers: speakers)
  end
end
