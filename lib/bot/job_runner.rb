require_relative 'jobs'

module Bot
  class JobRunner
    CANCEL_POLL_INTERVAL = 0.25
    CANCEL_GRACE_SECONDS = 5

    def initialize(cancelled:, finished:)
      @cancelled = cancelled
      @finished  = finished
    end

    def run(job_id, &work)
      pid = Kernel.fork do
        Process.setpgrp
        thread = Thread.current
        Signal.trap(:TERM) { thread.raise JobCancelled }
        work.call
      rescue JobCancelled
        exit! 0
      rescue => e
        STDERR.puts "Error processing job: #{e.class}: #{e.message}"
        STDERR.puts e.backtrace.join("\n")
        exit! 1
      end
      establish_process_group(pid)
      monitor(pid, job_id)
    ensure
      @finished.call(job_id) if job_id
    end

    private

    def monitor(pid, job_id)
      cancel_started_at = nil
      leader_reaped     = false

      loop do
        leader_reaped ||= !!Process.waitpid(pid, Process::WNOHANG)
        break if leader_reaped && !cancel_started_at

        if cancel_started_at
          break if leader_reaped && !process_group_alive?(pid)

          if monotonic_time - cancel_started_at >= CANCEL_GRACE_SECONDS
            signal(pid, :KILL)
            Process.waitpid(pid) unless leader_reaped
            break
          end
        elsif cancelled?(job_id)
          cancel_started_at = monotonic_time if signal(pid, :TERM)
        end

        sleep CANCEL_POLL_INTERVAL
      end
    rescue Errno::ECHILD
      nil
    end

    def cancelled?(job_id)
      @cancelled.call(job_id)
    rescue StandardError
      false
    end

    def signal(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      false
    end

    def process_group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    end

    def establish_process_group(pid)
      Process.setpgid(pid, pid)
    rescue Errno::EACCES, Errno::ESRCH
      nil
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
