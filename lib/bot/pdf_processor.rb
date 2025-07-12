class Bot
  class PdfProcessor < Processor

    def download
      info = msg.document
      raise 'No PDF' unless info&.mime_type == 'application/pdf' || info&.file_name&.end_with?('.pdf')

      file  = SymMash.new api.get_file file_id: info.file_id
      fn_in = file.result.file_path
      page  = http.get "https://api.telegram.org/file/bot#{ENV['TOKEN']}/#{fn_in}"

      fn_out = "#{dir}/#{info.file_name || 'input.pdf'}"
      File.write fn_out, page.body

      SymMash.new(
        fn_in: fn_out,
        info:  {title: info.file_name},
      )
    end

    protected
    def http
      Mechanize.new
    end

  end
end 