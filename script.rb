#!/usr/bin/env ruby

require 'byebug'
require 'active_support/core_ext/hash/conversions'
require 'pp'
require 'optparse'
require 'timeout'
require 'yaml'

# from: http://stackoverflow.com/questions/12714186/reposition-an-element-to-the-front-of-an-array-in-ruby
class Array
  def promote(promoted_element, key)
    return self unless (found_index = self.find_index{ |r| r[key] == promoted_element } )
    unshift(delete_at(found_index))
  end
end

# from: http://stackoverflow.com/questions/8292031/ruby-timeouts-and-system-commands
def exec_with_timeout(cmd, timeout)
  begin
    # stdout, stderr pipes
    rout, wout = IO.pipe
    rerr, werr = IO.pipe
    stdout, stderr = nil

    pid = Process.spawn(cmd, pgroup: true, :out => wout, :err => werr)

    Timeout.timeout(timeout) do
      Process.waitpid(pid)

      # close write ends so we can read from them
      wout.close
      werr.close

      stdout = rout.readlines.join
      stderr = rerr.readlines.join
    end

  rescue Timeout::Error
    Process.kill(-9, pid)
    Process.detach(pid)
  ensure
    wout.close unless wout.closed?
    werr.close unless werr.closed?
    # dispose the read ends of the pipes
    rout.close
    rerr.close
  end
  stdout
end

def run_speed_test
  speed = ''

  command = 'speedtest-cli --simple --timeout 60'

  speed = exec_with_timeout( command, 180 )

  if( speed.empty? )
    puts "running speed test one more time"
    sleep(5)
    speed = exec_with_timeout( command, 180 )
  end

  speed
end


OptionParser.new do |o|
  o.on('-a') { |b| $find_all = b }
  o.parse!
end

# number of networks to look at
look_at = 8

networks = YAML.load_file('networks.yml')

xml_str = `/System/Library/PrivateFrameworks/Apple80211.framework/Versions/A/Resources/airport -s -x`
# from: https://robots.thoughtbot.com/fight-back-utf-8-invalid-byte-sequences
exml = xml_str.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')

hash = Hash.from_xml(exml)

if( hash['plist'].nil? || hash['plist']['array'].nil? || hash['plist']['array']['dict'].nil? )
  puts "coouldnt find any networks"
  exit
end

puts "networks we found:"
puts "==============================="

results = hash['plist']['array']['dict'].map do |wifi|
  result = {name: wifi['string'][1]}

  result[:rssi] = wifi['integer'].last

  if( networks[ result[:name] ].nil? )
    nil
  else

    result
  end


end.compact.sort_by!{|result| result[:rssi] }

results.each do |r| 
    printf "%-31s %s\n", r[:name], r[:rssi]
end

# get current network
cnetwork = `networksetup -getairportnetwork en0`
current_network = cnetwork.chomp.split(": ")[1]
if( current_network )
  puts "\ncurrent network: "+current_network
  ordered_results = results.promote( current_network, :name )
else
  ordered_results = results
end

speed_results = ordered_results.take(look_at).each_with_index.map do |wifi, idx|
#speed_results = ordered_results.select{ |g| g[:name] == 'Freeware 1_5GHz' }.map do |wifi|

  password = networks[wifi[:name]]
  result = nil

  if( password != nil )
    if( idx == 0 )
      command_result = true
    else

      command = "networksetup -setairportnetwork en0 '#{wifi[:name]}' '#{password}'"
      puts "\nrunning: " + command

      begin
        command_result = system(command)
      rescue => e
        puts "network error"
        pp e
        next
      end

      puts "\njoin net result: "+command_result.to_s


    end

    if( command_result == true )
      current_network = wifi[:name]
      puts "\nwaiting 10 secs and running speed test"
      sleep(10)

      #run the speed test
      speed = run_speed_test

      if( speed.present? )

        speed_results = speed.split("\n").map{ |i| i.split(": ") }.map{ |i| i.map{ |j| j.split(" ")} }

        if( speed_results[0].nil? || speed_results[1].nil? || speed_results[0][1].nil? || speed_results[1][1].nil? ||speed_results[2][1].nil? )
          puts "bad speed results for "+wifi[:name]
          next
        end

        ping = speed_results[0][1][0].to_f
        download_speed = speed_results[1][1][0].to_f
        upload_speed = speed_results[2][1][0].to_f

        wifi[:ping] = ping
        wifi[:download_speed] = download_speed
        wifi[:upload_speed] = upload_speed

        puts "\n" + wifi[:name] + " >>> ping: " + ping.to_s + " dl: " + download_speed.to_s + " ul: " + upload_speed.to_s
        result = wifi
        if( $find_all == nil && download_speed > 10 && upload_speed > 5 )
          #stop everything, we found it
          exit
        end
      end

    end
  end

  result
end

puts "sorting results"
#sort
speed_results.sort_by!{ |result| result[:download_speed] }

if( speed_results.empty? )

  puts "nothing good found!!!!"
  pp speed_results
else
  best = speed_results.pop

  final_network = best[:name]

  final_password = networks[ best[:name] ]

  if( current_network == final_network )
    puts "youre connected to "+ final_network
    exit
  end

  command = "networksetup -setairportnetwork en0 '#{final_network}' '#{final_password}'"
  puts "\nrunning: " + command
  #switch netowrks
  begin
    command_result = system(command)
  rescue => e
    puts "network error"
    pp e
  end

end
