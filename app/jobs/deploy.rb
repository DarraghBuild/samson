Net::SSH::Connection::Session.class_eval do
  alias :old_loop :loop
  # Non-blocking loop, Net::SSH doesn't
  # let us pass through when using start
  def loop(wait = 0, &block)
    old_loop(wait, &block)
  end
end

class Deploy < Resque::Job
  def self.queue
    :deployment
  end

  def self.perform(id)
    new(id).work
  end

  def initialize(id)
    @job = JobHistory.find(id)
  end

  def work
    @job.run!

    Net::SSH.start("admin04.pod1", "sdavidovitz") do |ssh|
      ssh.shell do |sh|
        [
          "cd #{@job.project.name.parameterize("_")}",
          "git fetch -ap",
          "git reset --hard #{@job.sha}",
          "bundle --deployment",
          "capsu #{@job.environment} deploy TAG=#{@job.sha}"
        ].each do |command|
          if !exec!(sh, command)
            publish_messages("Failed to execute \"#{command}\"")
            @job.failed!

            return
          end
        end
      end
    end

    @job.success!
  end

  def exec!(shell, command)
    retval = true

    process = shell.execute(command)

    process.on_output do |ch, data|
      publish_messages(data)
    end

    process.on_error_output do |ch, type, data|
      publish_messages(data, "**ERR")
    end

    process.manager.channel.on_process do
      @job.save if @job.changed?

      if message = redis.get("#{@job.channel}:input")
        process.send_data("#{message}\n")
        redis.del("#{@job.channel}:input")
      end
    end

    shell.wait!
    process.exit_status == 0
  end

  def publish_messages(data, prefix = "")
    messages = data.split(/\r?\n|\r/).
      map(&:lstrip).reject(&:blank?)

    if prefix.present?
      messages.map! do |msg|
        "#{prefix}#{msg}"
      end
    end

    messages.each do |message|
      @job.log += "#{message}\n"
      redis.publish(@job.channel, message)
      Rails.logger.info(message)
    end
  end

  def redis
    @redis ||= Resque.redis.redis
  end
end
