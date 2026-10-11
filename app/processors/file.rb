module Processors
  class File < Base
    class_attribute :attr

    def download
      info = msg.send attr
      return st.error("No #{attr}") unless info

      local_path = ::File.exist?(info.local_path.to_s) ? info.local_path : service.download_file(info, dir: tmp)

      file_opts = SymMash.new(self.opts.deep_dup.presence || {})
      title = info.file_name || ::File.basename(local_path, ::File.extname(local_path))

      SymMash.new(fn_in: local_path, opts: file_opts, info: { title: title })
    end

  end
end
