class Manager
  class DocumentProcessor < Processor

    def download
      info = msg.document
      raise 'No document' unless info

      local_path = if bot.respond_to?(:td_bot?) && bot.td_bot?
        fid = info.respond_to?(:document) && info.document.respond_to?(:id) ? info.document.id : info.document[:id]
        bot.download_file(fid, dir: dir)
      else
        bot.download_file(info, dir: dir)
      end

      SymMash.new(
        fn_in: local_path,
        info:  {title: info.file_name},
      )
    end

    protected
    def http
      Mechanize.new
    end

  end
end


