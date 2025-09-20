class Bot
  class PdfProcessor < Processor

    def download
      info = msg.document
      raise 'No document' unless info

      local_path = bot.download_file(info, dir: dir)

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