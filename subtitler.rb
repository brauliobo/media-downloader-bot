module Subtitler

  MODEL = ENV['WHISPER_MODEL']
  mattr_accessor :model
  Thread.new do
    self.model = Whisper::Model.new MODEL
  end

  def self.transcribe file
    transcript = model.transcribe_from_file file, format: 'srt'
  end

end

