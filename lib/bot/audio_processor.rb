class Manager
  class AudioProcessor < Processor

    def download
      info = msg.audio
      unless info
        st.error('No audio')
        return
      end

      local_path = bot.download_file(info, dir: dir)
      aopts = SymMash.new(self.opts.deep_dup.presence || {})
      aopts.onlysrt ||= 1

      SymMash.new(
        fn_in: local_path,
        opts:  aopts,
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


