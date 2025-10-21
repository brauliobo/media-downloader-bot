require_relative 'base'

module Processors
  class File < Base
    def process
      pdoc = Processors::Document.new(dir:, bot:, msg:, st: self.st)
      if pdoc.pdf_document? || pdoc.epub_document?
        return pdoc.process
      elsif msg.video.present?
        return Processors::Video.new(dir:, bot:, msg:, st: self.st).process
      elsif msg.audio.present?
        return Processors::Audio.new(dir:, bot:, msg:, st: self.st).process
      else
        st.error('Unsupported message type')
        return
      end
    end
  end
end


