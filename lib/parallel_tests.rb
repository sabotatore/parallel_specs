class ParallelTests
  # finds all tests and partitions them into groups
  def self.tests_in_groups(root, num)
    tests_with_sizes = find_tests_with_sizes(root)

    groups = []
    current_group = current_size = 0
    tests_with_sizes.each do |test, size|
      # inserts into next group if current is full and we are not in the last group
      if (0.5*size + current_size) > group_size(tests_with_sizes, num) and num > current_group + 1
        current_size = size
        current_group += 1
      else
        current_size += size
      end
      groups[current_group] ||= []
      groups[current_group] << test
    end
    groups.compact
  end

  def self.run_tests(test_files, process_number)
    require_list = test_files.map { |filename| "\"#{filename}\"" }.join(",")
    cmd = "export RAILS_ENV=test ; export TEST_ENV_NUMBER=#{test_env_number(process_number)} ; ruby -Itest -e '[#{require_list}].each {|f| require f }'"
    execute_command(cmd)
  end

  def self.execute_command(cmd)
    f = open("|#{cmd}")
    all = ''
    while out = f.gets(test_result_seperator)
      all+=out
      print out
      STDOUT.flush
    end
    all
  end

  def self.find_results(test_output)
    test_output.split("\n").map {|line|
      line = line.gsub(/\.|F|\*/,'')
      next unless line_is_result?(line)
      line
    }.compact
  end

  def self.failed?(results)
    !! results.detect{|line| line_is_failure?(line)}
  end

  def self.test_env_number(process_number)
    process_number == 0 ? '' : process_number + 1
  end

  protected

  def self.test_result_seperator
    "."
  end

  def self.line_is_result?(line)
    line =~ /\d+ failure/
  end
  
  def self.line_is_failure?(line)
    line =~ /(\d{2,}|[1-9]) (failure|error)/
  end

  def self.group_size(tests_with_sizes, num_groups)
    total_size = tests_with_sizes.inject(0) { |sum, test| sum += test[1] }
    total_size / num_groups.to_f
  end

  def self.find_tests_with_sizes(root)
    tests = find_tests(root).sort

    #TODO get the real root, atm this only works for complete runs when root point to e.g. real_root/spec
    runtime_file = File.join(root,'..','tmp','parallel_profile.log')
    lines = File.read(runtime_file).split("\n") rescue []

    if lines.size * 1.5 > tests.size
      # use recorded test runtime if we got enought data
      times = Hash.new(1)
      lines.each do |line|
        test, time = line.split(":")
        times[test] = time.to_f
      end
      tests.map { |test| [ test, times[test] ] }
    else
      # use file sizes
      tests.map { |test| [ test, File.stat(test).size ] }
    end
  end

  def self.find_tests(root)
    Dir["#{root}**/**/*_test.rb"]
  end

  #Copy of parallel gem, parallel @ V0.2
  #please add patches/specs to the parallel project --> https://github.com/grosser/parallel
  class Parallel
    def self.in_threads(count=2)
      out = []
      threads = []

      count.times do |i|
        threads[i] = Thread.new do
          out[i] = yield(i)
        end
      end

      threads.each{|t| t.join }
      out
    end

    def self.in_processes(count=nil)
      count ||= processor_count

      #start writing results into n pipes
      reads = []
      writes = []
      pids = []
      count.times do |i|
        reads[i], writes[i] = IO.pipe
        pids << Process.fork{ Marshal.dump(yield(i), writes[i]) } #write serialized result
      end

      kill_on_ctrl_c(pids)

      #collect results from pipes simultanously
      #otherwise pipes get stuck when to much is written (buffer full)
      out = []
      collectors = []
      count.times do |i|
        collectors << Thread.new do
          writes[i].close

          out[i]=""
          while text = reads[i].gets
            out[i] += text
          end

          reads[i].close
        end
      end

      collectors.each{|c|c.join}

      out.map{|x| Marshal.load(x)} #deserialize
    end

    def self.processor_count
      case RUBY_PLATFORM
      when /darwin/
        `hwprefs cpu_count`.to_i
      when /linux/
        `cat /proc/cpuinfo | grep processor | wc -l`.to_i
      end
    end

    private

    #handle user interrup (Ctrl+c)
    def self.kill_on_ctrl_c(pids)
      Signal.trap 'SIGINT' do
        STDERR.puts "Parallel execution interrupted, exiting ..."
        pids.each { |pid| Process.kill("KILL", pid) }
        exit 1
      end
    end
  end
end