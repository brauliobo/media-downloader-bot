require 'fileutils'
require 'open3'
require 'pathname'

module Ewprs
  class TranslationBatch
    module SourceManagement
      private

      def entries(only: nil)
        paths = Dir[File.join(root, 'HTML/{Discourses,Books}/*.html')].sort
        values = paths.map do |path|
          kind = path.include?('/Discourses/') ? :discourse : :book
          Entry.new(kind: kind, path: path)
        end
        return values unless only

        selected = values.find { |entry| entry.slug == only }
        [selected || raise("EWPRS entry not found: #{only}")]
      end

      def read_document(path)
        bytes = source_bytes(path)
        utf8  = bytes.dup.force_encoding(Encoding::UTF_8)
        return [utf8, Encoding::UTF_8] if utf8.valid_encoding?

        [bytes.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8), Encoding::Windows_1252]
      end

      def source_bytes(path)
        return File.binread(path) unless git_worktree?

        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        output, error, status = Open3.capture3(
          'git', 'show', "#{source_ref}:#{relative}", chdir: root, binmode: true
        )
        raise "cannot read #{relative} from #{source_ref}: #{error.strip}" unless status.success?

        output
      end

      def source_mode(path)
        return File.stat(path).mode & 0o7777 unless git_worktree?

        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        output = git('ls-tree', source_ref, '--', relative)
        mode = output.split.first
        raise "cannot read mode for #{relative} from #{source_ref}" unless mode

        Integer(mode, 8) & 0o7777
      end

      def git_worktree?
        return @git_worktree unless @git_worktree.nil?

        _output, _error, status = Open3.capture3(
          'git', 'rev-parse', '--is-inside-work-tree', chdir: root
        )
        @git_worktree = status.success?
      end

      def write_document(document, rendered)
        bytes = rendered.encode(document.encoding)
        temp  = "#{document.entry.path}.translation.tmp"
        File.binwrite(temp, bytes)
        File.chmod(document.mode, temp)
        File.rename(temp, document.entry.path)
      ensure
        FileUtils.rm_f(temp) if temp && File.exist?(temp)
      end

      def prepare_branch!
        current = git('branch', '--show-current').strip
        return if current == branch

        raise 'EWPRS worktree must be clean before switching branches' unless git('status', '--porcelain').strip.empty?
        raise "expected branch #{source_ref}, got #{current}" unless current == source_ref

        exists = system('git', 'show-ref', '--verify', '--quiet', "refs/heads/#{branch}", chdir: root)
        exists ? git('switch', branch) : git('switch', '-c', branch, source_ref)
      end

      def git(*args)
        output, error, status = Open3.capture3('git', *args, chdir: root)
        raise "git #{args.join(' ')} failed: #{error.strip}" unless status.success?

        output
      end
    end
  end
end
