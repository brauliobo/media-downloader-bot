require_relative 'base'
require 'active_support/core_ext/class/attribute'

module Processors
  class File < Base
    class_attribute :attr

    def download
      info = msg.send attr
      return st.error("No #{attr}") unless info

      local_path = if info.respond_to?(:local_path) && ::File.exist?(info.local_path)
        info.local_path
      else
        Worker.service.download_file(info, dir: dir)
      end

      file_opts = SymMash.new(self.opts.deep_dup.presence || {})
      title = if info.respond_to?(:file_name)
        info.file_name
      else
        ::File.basename(local_path, ::File.extname(local_path))
      end

      SymMash.new(fn_in: local_path, opts: file_opts, info: { title: title })
    end

  end
end