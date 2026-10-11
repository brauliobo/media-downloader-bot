class Worker
  # Where a job keeps its files, and clearing them afterwards.
  module Workdir
    def workdir &block
      cancelled = false
      @dir = workdir_path || Utils::Tmp.dir('mdb-', tmpdir)
      yield @dir
    rescue Bot::JobCancelled
      cancelled = true
      FileUtils.rm_rf(@dir) unless skip_cleanup
      raise
    ensure
      cleanup_workdir(@dir) unless skip_cleanup || cancelled
    end

    def cleanup_workdir(dir)
      return unless dir && Dir.exist?(dir)
      # Detached subprocess survives parent fork exit; delay lets uploaders release file handles
      pid = Process.spawn('sh', '-c', "sleep 30 && rm -rf #{dir.shellescape}", out: File::NULL, err: File::NULL)
      Process.detach pid
    end

    def cleanup_input(input)
      return if skip_cleanup || !dir

      Array(input.uploads).each { |upload| cleanup_input(upload) }

      root = "#{File.expand_path(dir)}/"
      %i[fn_in fn_out thumb thumbnail_path].filter_map { |name| input.public_send(name) }.uniq.each do |path|
        path = File.expand_path(path)
        FileUtils.rm_f(path) if path.start_with?(root)
      end
    end
  end
end
