class Manager
  class VideoProcessor < Processor

    def download
      info = msg.video
      unless info
        st.error('No video')
        return
      end

      local_path = bot.download_file(info, dir: dir)
      vopts = SymMash.new(self.opts.deep_dup.presence || {})
      vopts.onlysrt ||= 1

      SymMash.new(
        fn_in: local_path,
        opts:  vopts,
        info:  { title: info.respond_to?(:file_name) ? info.file_name : File.basename(local_path, File.extname(local_path)) },
      )
    end

    def process(*args, **kwargs)
      download
    ensure
      cleanup
    end

  end
end


