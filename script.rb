#!/usr/bin/env ruby

require 'byebug'
require 'active_support/core_ext/hash/conversions'
require 'pp'
require 'optparse'
require 'timeout'
require 'json'

###############################################################################
###############################################################################
#
#
#
#                                 Helper Things
#
#
###############################################################################
###############################################################################


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
      #puts "speedtest stdout: " + stdout
      #puts stdout
      #puts "Error: speedtest stderr: " + stderr
    end

  rescue Timeout::Error => e
    puts "Error: timeout rescue: " + e.message
    Process.kill(-9, pid)
    Process.detach(pid)
  ensure
    #puts "Ensure"
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

  command = 'speedtest-cli --simple --timeout 60 --secure'

  speed = exec_with_timeout( command, 70 )

  if( !speed || speed.empty? )
    puts "Error: running speed test one more time"
    sleep(5)
    speed = exec_with_timeout( command, 70 )
  end
  #puts "returning speed val"
  #pp speed

  speed
end


OptionParser.new do |o|
  o.on('-a') { |b| $find_all = b }
  o.parse!
end

# one level deep, check to see if this network name exists
def network?( networks, name )
  if get_password( networks, name )
    return true
  end

  false
end

def get_password( networks, name )
  if( !networks[ name ].nil? )
    return networks[ name ]
  else
    networks.each do |key, network|
      # is it a network group
      if network.respond_to? :each
        network.each do |network_name,password|
          if network_name == name
            return password
          end
        end
      end
    end
  end
  return false
end




###############################################################################
###############################################################################
#
#
#
#                                 Run Things
#
#
###############################################################################
###############################################################################



###############################################################################
#
#                         get netowrks, process xml
###############################################################################

networks = JSON.parse( File.read('networks.json') )

# get an xml doc of networks
xml_str = `/System/Library/PrivateFrameworks/Apple80211.framework/Versions/A/Resources/airport -s -x`
# from: https://robots.thoughtbot.com/fight-back-utf-8-invalid-byte-sequences
exml = xml_str.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')

# process the hash of networks

hash = Hash.from_xml(exml)

if( !hash || hash['plist'].nil? || hash['plist']['array'].nil? || hash['plist']['array']['dict'].nil? )
  puts "Error: couldn't find any networks"
  exit
end

# do weird things with xml doc - plist etc
# and sort it
results = hash['plist']['array']['dict'].map do |wifi|
  result = {name: wifi['string'][1]}

  result[:rssi] = wifi['integer'].last

  #if( networks[ result[:name] ].nil? )
  if( network?(networks, result[:name] ) )
    result
  else
    nil
  end

end.compact.sort_by!{|result| result[:rssi] }

# print out the networks
puts "Networks:"
puts "\n=======================================================\n"
results.each do |r| 
    printf "%-31s %s\n", r[:name], r[:rssi]
end
puts "\n=======================================================\n"

# get current network
cnetwork = `networksetup -getairportnetwork en0`
current_network = cnetwork.chomp.split(": ")[1]
if( current_network )
  puts "\nLog: Current Network: "+current_network
  ordered_results = results.promote( current_network, :name )
else
  ordered_results = results
end

###############################################################################
#
#                        run speed test
###############################################################################

# number of networks to look at
look_at = 8

speed_results = ordered_results.take(look_at).each_with_index.map do |wifi, idx|

  # TODO:
  # if we've already run a thing that's in this group, skip it
  password = get_password( networks, wifi[:name])
  #password = networks[wifi[:name]]

  if password == false
    pp "Error: couldn't find a password for: " + wifi[:name]
    next
  end

  result = nil

  if( password != nil )
    if( idx == 0 )
      command_result = true
    else

      command = "networksetup -setairportnetwork en0 '#{wifi[:name]}' '#{password}'"
      puts "\nDebug: Joining Network: running: " + command

      begin
        command_result = system(command)
      rescue => e
        pp "Error: network error: " + e
        next
      end

      puts "\nDebug: Joining Network Result: "+command_result.to_s
    end

    if( command_result == true )
      current_network = wifi[:name]
      puts "\nWaiting...... 10 secs and running speed test"
      sleep(10)

      #run the speed test
      speed = run_speed_test

      if( speed.present? )

        speed_results = speed.split("\n").map{ |i| i.split(": ") }.map{ |i| i.map{ |j| j.split(" ")} }

        if( speed_results[0].nil? || speed_results[1].nil? || speed_results[0][1].nil? || speed_results[1][1].nil? ||speed_results[2][1].nil? )
          puts "Error: bad speed results for "+wifi[:name]
          next
        end

        ping = speed_results[0][1][0].to_f
        download_speed = speed_results[1][1][0].to_f
        upload_speed = speed_results[2][1][0].to_f

        wifi[:ping] = ping
        wifi[:download_speed] = download_speed
        wifi[:upload_speed] = upload_speed

        puts "\nLog: " + idx.to_s + " : Network: " + wifi[:name] + ": Speed Result >>> ping: " + ping.to_s + " dl: " + download_speed.to_s + " ul: " + upload_speed.to_s
        result = wifi
        if( $find_all == nil && download_speed > 10 && upload_speed > 2 )
          #stop everything, we found it
          exit
        end
      end

    end
  end

  result
end

###############################################################################
#
#                 if we need to, process speed test results
###############################################################################

#puts "Log: Sorting Results"
speed_results = speed_results.compact
#pp speed_results

if( speed_results.empty? )

  puts "\nError: Fatal: All results are empty. Try running again.\n"
  pp speed_results
else

  #sort
  speed_results.sort_by! { |result| result[:download_speed] }

  best = speed_results.pop

  final_network = best[:name]

  final_password = networks[ best[:name] ]

  if( current_network == final_network )
    puts "\nLog: You're connected to: "+ final_network + "\n"
    exit
  end

  command = "networksetup -setairportnetwork en0 '#{final_network}' '#{final_password}'"
  puts "\nDebug: Joining Network: running: " + command
  #switch netowrks
  begin
    command_result = system(command)
  rescue => e
    pp "Error: network error: " + e
  end

end
