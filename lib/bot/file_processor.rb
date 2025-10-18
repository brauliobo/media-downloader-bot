class Manager
  class FileProcessor < Processor

    def process
      # Documents (PDF/EPUB): delegate entirely to DocumentProcessor.process
      pdoc = Manager::DocumentProcessor.new(dir:, bot:, msg:, st: self.st)
      if pdoc.pdf_document? || pdoc.epub_document?
        return pdoc.process
      elsif msg.video.present?
        return Manager::VideoProcessor.new(dir:, bot:, msg:, st: self.st).process
      elsif msg.audio.present?
        return Manager::AudioProcessor.new(dir:, bot:, msg:, st: self.st).process
      else
        st.error('Unsupported message type')
        return
      end
    end

  end
end
