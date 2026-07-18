require 'spec_helper'
require 'tmpdir'
require_relative '../../lib/services/edit_posts/job_manager'

RSpec.describe Services::EditPosts::JobManager do
  class TestEditPostsRunner
    def initialize(args, manager:, output:)
      @args    = args
      @manager = manager
      @output  = output
    end

    def run
      @output.puts "#{@manager}:#{@args.join(',')}"
    end
  end

  it 'runs submitted jobs and exposes serializable status' do
    Dir.mktmpdir do |root|
      jobs = described_class.new(:manager, concurrency: 2, root: root, runner: TestEditPostsRunner)
      job  = jobs.start(chat: -1001, apply: 1)

      Timeout.timeout(2) { sleep 0.01 until jobs.fetch(job[:id])[:state] == 'completed' }
      result = jobs.fetch(job[:id])

      expect(result).to include(state: 'completed', args: ['chat=-1001', 'apply=1'])
      expect(File.read(result[:log_path])).to include('manager:chat=-1001,apply=1')
      expect(jobs.log(job[:id], lines: 1)).to eq("manager:chat=-1001,apply=1\n")
      expect(jobs.list).to contain_exactly(result)
    end
  end

  it 'runs independent jobs up to the configured concurrency' do
    started = Queue.new
    release = Queue.new
    runner  = Class.new do
      define_method(:initialize) { |_args, manager:, output:| @started, @release = manager }
      define_method(:run) { @started << true; @release.pop }
    end

    Dir.mktmpdir do |root|
      jobs = described_class.new([started, release], concurrency: 2, root: root, runner: runner)
      first  = jobs.start(['chat=-1001'])
      second = jobs.start(['chat=-1002'])

      Timeout.timeout(2) { 2.times { started.pop } }
      expect([jobs.fetch(first[:id])[:state], jobs.fetch(second[:id])[:state]]).to eq(%w[running running])

      2.times { release << true }
      Timeout.timeout(2) do
        sleep 0.01 until [first, second].all? { |job| jobs.fetch(job[:id])[:state] == 'completed' }
      end
    end
  end
end
