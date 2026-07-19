require_relative 'boot'

require_relative 'bot/worker/client'
require_relative 'worker'

class WorkerDaemon
  CANCEL_POLL_INTERVAL = 0.25
  CANCEL_GRACE_SECONDS = 5

  def initialize(service_uri = nil)
    @service_uri = service_uri || ENV['BOT_HTTP'] || ENV['BOT_DRB']
    @shutdown = false
  end

  def run
    trap(:TERM) { @shutdown = true }
    trap(:INT) { @shutdown = true }

    if @service_uri.start_with?('http')
      run_http
    else
      run_drb
    end
  end

  private

  def run_http
    http_client = Faraday.new(url: @service_uri, headers: {'Authorization' => "Bearer #{ENV.fetch('BOT_HTTP_TOKEN')}"}) do |conn|
      conn.options.timeout = 0.1
    end
    puts "Worker connected to HTTP service at #{@service_uri}"

    loop do
      break if @shutdown

      begin
        response = http_client.get('/queue/dequeue')
        raise "bot HTTP service returned #{response.status}" unless response.success?
        result = response.body.is_a?(String) ? JSON.parse(response.body) : response.body
        job_data = result['job']
        
        if job_data
          job = {job_data: job_data, worker_uri: result['service_uri'] || @service_uri}
          if @shutdown
            pid = fork { process_message(job) }
            Process.detach(pid)
            exit(0)
          else
            process_message(job)
          end
        end
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed
        sleep 0.1
      rescue => e
        next if @shutdown
        puts "Error dequeuing: #{e.message}"
        sleep 1
      end
    end
  end

  def run_drb
    manager = DRbObject.new_with_uri(@service_uri)
    puts "Worker connected to DRb service at #{@service_uri}"

    loop do
      break if @shutdown && manager.queue_size == 0

      begin
        job_data = manager.dequeue(timeout: 1)
      rescue => e
        next if @shutdown
        puts "Error dequeuing: #{e.message}"
        sleep 1
        next
      end

      next unless job_data

      job = {job_data: job_data, worker_uri: manager.bot_service_uri}
      if @shutdown
        pid = fork { process_message(job) }
        Process.detach(pid)
        exit(0)
      else
        process_message(job)
      end
    end
  end

  def process_message(job)
    job_data   = SymMash.new(job[:job_data])
    worker_uri = job[:worker_uri]
    job_id     = job_data.id
    pid = Kernel.fork do
      Process.setpgrp
      thread = Thread.current
      Signal.trap(:TERM) { thread.raise Bot::JobCancelled }

      DB.disconnect if defined? DB
      service = Bot::Worker::Client.new(worker_uri) if worker_uri
      worker  = Worker.new(SymMash.new(job_data.message), service: service || Worker.service, job_id: job_id)
      worker.process
    rescue Bot::JobCancelled
      exit! 0
    rescue => e
      STDERR.puts "Error processing message: #{e.class}: #{e.message}"
      STDERR.puts e.backtrace.join("\n")
      exit! 1
    end
    establish_process_group(pid)

    service = Bot::Worker::Client.new(worker_uri) if worker_uri
    monitor_job(pid, job_id, service || Worker.service)
  rescue => e
    STDERR.puts "Error processing message: #{e.class}: #{e.message}"
    STDERR.puts e.backtrace.join("\n")
  ensure
    (service || Worker.service)&.finish_job(job_id) if job_id
  end

  def monitor_job(pid, job_id, service)
    cancel_started_at = nil
    leader_reaped     = false

    loop do
      leader_reaped ||= !!Process.waitpid(pid, Process::WNOHANG)
      break if leader_reaped && !cancel_started_at

      if cancel_started_at
        break if leader_reaped && !process_group_alive?(pid)

        if monotonic_time - cancel_started_at >= CANCEL_GRACE_SECONDS
          signal_job(pid, :KILL)
          Process.waitpid(pid) unless leader_reaped
          break
        end
      elsif job_cancelled?(service, job_id)
        cancel_started_at = monotonic_time if signal_job(pid, :TERM)
      end

      sleep CANCEL_POLL_INTERVAL
    end
  rescue Errno::ECHILD
    nil
  end

  def job_cancelled?(service, job_id)
    service.job_cancelled?(job_id)
  rescue StandardError
    false
  end

  def signal_job(pid, signal)
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
