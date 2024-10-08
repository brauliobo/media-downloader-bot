class Bot
  class FileProcessor < Processor

    def download 
      info   = msg.video || msg.audio
      file   = SymMash.new api.get_file file_id: info.file_id
      fn_in  = file.result.file_path
      page   = http.get "https://api.telegram.org/file/bot#{ENV['TOKEN']}/#{fn_in}"

      fn_out = "#{dir}/input.#{File.extname fn_in}"
      File.write fn_out, page.body

      SymMash.new(
        fn_in: fn_out,
        info: {
          title: info.file_name,
        },
      )
    end

  end
end
