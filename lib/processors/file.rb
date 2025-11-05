require_relative 'base'
require 'active_support/core_ext/class/attribute'

module Processors
  class File < Base
    class_attribute :attr


    def download
      info = if attr
        msg.send(attr)
      else
        msg.document
      end

      unless info
        st.error("No #{attr || 'document'}")
        return
      end

      local_path = if !attr && info.respond_to?(:document) && info.document.respond_to?(:id)
        fid = info.document.id
        Worker.worker.download_file(fid, dir: dir)
      else
        Worker.worker.download_file(info, dir: dir)
      end

      file_opts = SymMash.new(self.opts.deep_dup.presence || {})
      title = if info.respond_to?(:file_name)
        info.file_name
      else
        ::File.basename(local_path, ::File.extname(local_path))
      end

      SymMash.new(
        fn_in: local_path,
        opts:  file_opts,
        info:  { title: title },
      )
    end
  end
end


