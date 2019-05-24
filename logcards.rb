#!/usr/bin/ruby

#nfc-list uses libnfc 1.5.1 (r1175)
#Connected to NFC device: ACS ACR 38U-CCID 00 00 / ACR122U102 - PN532 v1.4 (0x07)
#1 ISO14443A passive target(s) found:
#    ATQA (SENS_RES): 00  44  
#       UID (NFCID1): 04  ed  ab  d9  a1  25  80  
#      SAK (SEL_RES): 00  
#

require 'rubygems'

require 'bundler/setup'
require 'yaml'
require 'net/http'
require 'json'
require 'uri'
require 'net/ssh'
require 'dnsruby'
require 'tzinfo'
require 'slack-ruby-client'

#YAML::ENGINE.yamler = 'syck'

class LCConfig
  def self.load
    @@config = YAML.load_file("#{File.dirname(File.expand_path($0))}/config.yaml")
    @@tz = nil
    @@slack_configured = false
    if @@config["settings"] and @@config["settings"]["timezone"]
      @@tz = TZInfo::Timezone.get(@@config["settings"]["timezone"])
    end
    if @@config["settings"] and @@config["settings"]["slack-api-token"]
      token = @@config["settings"]["slack-api-token"]
      Slack.configure do |config|
        config.token = token
        @@slack_configured = true
      end
    end
  end

  def self.door_open_minimum
    min = LCConfig.env["door_open_minimum"]
    if min.nil? and LCConfig.config["settings"]
      min = LCConfig.config["settings"]["door_open_minimum"]
    end
    min = min.to_f
    if min.nil? || min == 0
      min = 0.1
    end
    min
  end

  def self.config
    @@config
  end

  def self.slack_configured
    @@slack_configured
  end

  def self.tz
    @@tz
  end

  def self.env
    @@config["environments"][ENV['DOORBOT_ENV']]
  end

  $connection_error = nil

  def self.kindle_ssh
    kindle = LCConfig.env["kindle"]
    ssh = nil
    if kindle
      if !$connection_error
        puts "Trying to ssh into the kindle"
        begin
          ssh = Net::SSH.start(kindle['ip'], kindle['user'], :password => kindle['password'], :port => kindle['port'], :timeout => kindle['timeout'])
          puts "Connection complete"
        rescue Errno::EHOSTUNREACH => e
          puts "Can't reach Kindle..."
          # This is usually because the Kindle has mounted as a USB disk
          # Try unmounting it
          `umount /media/Kindle`
          `udisks --eject /dev/sda`
          raise e
        end
      end
    end
    return ssh
  rescue Timeout::Error => e
    $connection_error = true
    puts "Oops #{e.inspect}"
    puts "Please check the config for the kindle and check you can ssh into the kindle"
  rescue SocketError => e
    $connection_error = true
    puts "Oops #{e.inspect}"
    puts "Please check the config for the kindle and check you can ssh into the kindle"
  rescue Net::SSH::AuthenticationFailed => e
    $connection_error = true
    puts "Oops #{e.inspect}"
    puts "Please check the config for the kindle and check you can ssh into the kindle"
  rescue Net::SSH::Exception => e
    $connection_error = true
    puts "Oops #{e.inspect}"
    puts "Please check the config for the kindle and check you can ssh into the kindle"
  end

  def self.setup_signal
    Signal.trap("HUP") do
      begin
        LCConfig.load
        puts LCConfig.config.inspect
      rescue Exception => e
        puts "erk: #{e.inspect}"
      end
    end
  end
end
puts "Config Pre Load"
LCConfig.load
puts "After load. Config Correct!"
#puts LCConfig.config.inspect
LCConfig.setup_signal
VISITS_YAML = 'visits.yaml'
DAY_VISITS_YAML = 'day_visits.yaml'
UNLOGGED_VISITS_YAML = 'unlogged_visits.yaml'

def setSSH(state, ssh)
  if ssh
    close_image = LCConfig.env["kindle"]["close"]
    open_image = LCConfig.env["kindle"]["open"]
    if state == 1
      ssh.exec!("eips -g #{open_image}")
    end
    if state == 0
      ssh.exec!('eips -c')
      ssh.exec!("eips -g #{close_image}")
    end
  end
rescue Exception => e
  puts "SSH failed #{e}"
end



def setDoorState(state, ssh)
  `echo #{state} > /sys/class/gpio/gpio25/value`
  setSSH(state, ssh)
end

def saveUnloggedVisits
  File.open(UNLOGGED_VISITS_YAML, "w") do |out|
    YAML.dump($unloggedFile, out)
  end
end

def announce(message)
  puts message

  return unless LCConfig.slack_configured

  client = Slack::Web::Client.new
  client.chat_postMessage(channel: '#doorbots-announce', text: message, as_user: true)
  puts "-> SLACK"
end

puts "DoorBot: #{ENV["DOORBOT_ENV"]}"

if LCConfig.env.nil?
  puts "Error! Must specify a valid doorbot environment."
  exit
end

scansFile = nil
hotdesksFile = nil
visitsFile = nil
$testUID = nil
if File.file?(VISITS_YAML)
  visits = YAML.load_file(VISITS_YAML)
end
if visits.nil? or visits == false
  visits = {}
end
if File.file?(DAY_VISITS_YAML)
  dayVisits = YAML.load_file(DAY_VISITS_YAML)
end
if dayVisits.nil? or dayVisits == false
  dayVisits = {}
end
if File.file?(UNLOGGED_VISITS_YAML)
  $unloggedFile = YAML.load_file(UNLOGGED_VISITS_YAML)
end
if $unloggedFile.nil? or $unloggedFile == false
  $unloggedFile = {}
  $unloggedFile['user']= {}
end

Signal.trap("SIGUSR1") do
   $testUID = ''
end
test_pipe_filename = "/tmp/logcards-test.pipe"
if ENV['DOORBOT_TEST'] == 'test'
  `rm -f #{test_pipe_filename}`
  `mkfifo #{test_pipe_filename}`
  test_input = open(test_pipe_filename, "r")
else
  test_input = nil
end

while true
  begin
    if `mount | grep /media/Kindle` != ""
      print "Kindle is mounted. Unmounting"
      puts `umount /media/Kindle`
      if `mount | grep /media/Kindle` != ""
        print "Kindle is still mounted. Trying secondary unmount"
        puts `udisks --eject /dev/sda`
      end
      if `mount | grep /media/Kindle` != ""
        print "Kindle is still mounted so disabling the kindle ssh"
        $connection_error = true
      end
    end
    if !$connection_error
      ssh = LCConfig.kindle_ssh
      if ssh
        puts "Trying to ssh in to the kindle"
        puts "Connection Successful"
        setSSH(0, ssh)
      end
    end
    puts "Welcome to Doorbot"
    scansFile = File.open("scans.log", "a")
    hotdesksFile = File.open("hotdesks.log", "a")
    visitsFile = File.open("visits.log", "a")
    if test_input and ( test_input.eof? || test_input.closed? )
      if ! test_input.closed?
        test_input.close
      end
      test_input = open(test_pipe_filename, "r")
    end
    
    while true
      if test_input
        begin
          list = test_input.readline
        rescue EOFError
          list = ''
        end
      else
        list = `./#{LCConfig.env["rcapp"]}`
      end

      uid = list.chomp
      #uid = matches[1].gsub(/ /,"") if matches
      if uid.empty? and $testUID
        uid = $testUID
        $testUID = nil
      end
      if ! uid.empty?
        time = Time.now.utc
        if LCConfig.tz
          time = LCConfig.tz.utc_to_local(time)
        end
        today = Date.today.to_s
        scansFile.write("#{uid}\t#{time}\n")
        scansFile.flush
        user = LCConfig.config["users"][uid]
        seen = []
        puts "tag #{uid} at #{time}"
        while user and user["primary"]
          seen << uid
          uid = user["primary"]
          if seen.index(uid)
            puts "OMG RECURSION!!"
            blah = `espeak -v en "Recursion error!" --stdout | aplay`
            uid = ""
            user = nil
            break
          end
          user = LCConfig.config["users"][uid]
          puts "- has primary: #{uid}"
        end
      end
      if ! uid.empty?
        name = ""
        nickname = ""
        if user
          access = user["access"] || []
          announce("Visit from #{user["name"]} (#{access.join(", ")}) from #{ENV['DOORBOT_ENV']}")
          name = user["name"]
          nickname = user["nickname"]
          nickname = name if nickname.nil?
        else
          announce("#{uid} was unrecognised")
          blah = `espeak -v en "Thank you, welcome to duss Liverpool #{nickname}. Please talk to an organiser to be inducted." --stdout | aplay`
          next
        end
        
        access = user["access"] || []
        door_opened_at = nil
        access_required = LCConfig.env['access'] || []
        if LCConfig.env.has_key?('access') && ( access_required.length == 0 || ( access_required & access ).length > 0 )
          setDoorState(1, ssh)
          door_opened_at = Time.now
        end
        last_day = dayVisits[uid]
        if last_day != today
          dayVisits[uid] = today
          if LCConfig.env['loghotdesk'] and user and user["hotdesker"] == true and time.hour < 17
            days_used = 1
            #if time.hour >= 17
            #  days_used = 0.25
            #els
            if time.hour >= 13
              days_used = 0.5
            end
            hotdesksFile.write("#{time}\t#{uid}\t#{user["name"]}\t#{days_used}\n")
            hotdesksFile.flush
            puts "Log hot desk visit by #{user["name"]}!"
            # First save it in the unlogged file
            if $unloggedFile['user'][user['name']]
              days_used = days_used + $unloggedFile['user'][user['name']].to_i
            end
            $unloggedFile['user'][user['name']] = days_used
            saveUnloggedVisits()
         end
          File.open(DAY_VISITS_YAML, "w") do |out|
            YAML.dump(dayVisits,out)
          end
        end

        last_visit = visits[uid]
        if last_visit and (last_visit["arrived_at"].yday != time.yday || last_visit["arrived_at"].year != time.year)
          visitsFile.write("#{uid}\t#{last_visit["arrived_at"]}\t#{time}\t#{name}\n")
          visitsFile.flush
          last_visit = nil
        end
        p = fork do
          if last_visit
            puts "#{uid} Left"
            visitsFile.write("#{uid}\t#{last_visit["arrived_at"]}\t#{time}\t#{name}\n")
            visitsFile.flush
            blah = `espeak -v en "Thank you, goodbye #{nickname}" --stdout | aplay`
            #blah = `aplay thanks-goodbye.aiff > /dev/null 2> /dev/null`
            visits[uid] = nil
          else
            special_sound = nil
            day_sounds = nil
            if LCConfig.config["sounds"]
              day_sounds = LCConfig.config["sounds"]["#{time.month}-#{time.day}"]
            end
            if day_sounds
              special_sound = day_sounds.sample
            end
            puts "#{uid} Arrived"
            visits[uid] = { "arrived_at" => time }
            if special_sound
              cmd = "aplay wav/#{special_sound}"
              puts "ringtone: #{cmd}"
              blah = `#{cmd}`
            elsif user and user["ringtone"]
              cmd = "aplay wav/#{user["ringtone"]}"
              puts "ringtone: #{cmd}"
              blah = `#{cmd}`
            else
              blah = `espeak -v en "Thank you, welcome to duss Liverpool #{nickname}" --stdout | aplay`
            end
            #blah = `aplay thanks-welcome.aiff > /dev/null 2> /dev/null`
          end
          File.open(VISITS_YAML, "w") do |out|
            YAML.dump(visits, out)
          end
        end
	Process.detach(p) # So we don't leave that process as a zombie
        if door_opened_at
          opened_for = ( Time.now - door_opened_at )
          while opened_for < LCConfig.door_open_minimum
            interval = 0.05
            puts "Sleeping for an extra #{interval}s"
            sleep interval
            opened_for += interval
          end
          setDoorState(0, ssh)
        end
        if user and user["mapme_at_code"]
          m = fork do
            puts "Should check into mapme.at"
            host = "DoESLiverpool.#{Time.now.to_i}.#{user["mapme_at_code"]}.dns.mapme.at"
            Dnsruby::DNS.open {|dns|
              puts dns.getresource(host, "TXT")
            }

            #puts `dig DoESLiverpool.#{Time.now.to_i}.#{user["mapme_at_code"]}.dns.mapme.at > /dev/null 2> /dev/null`
          end
	  Process.detach(m) # So we don't leave that process as a zombie
        end

        sleep 2
      end

      if $unloggedFile['user'].count > 0
        puts "Logging unlogged users"
        # Using keys so that the fact that we're modifying the hash doesn't matter
        $unloggedFile['user'].keys.each do |name|
          uri = URI.parse("https://docs.google.com/forms/d/1eW3ebkEZcoQ7AvsLoZmL5Ju7eQbw8xABXQm3ggPJ-v4/formResponse?entry.1000001=#{URI.escape(name)}&entry.1000002=#{$unloggedFile['user'][name]}&entry.1000002.other_option_response=&submit=Submit")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl =true
          un_request = Net::HTTP::Get.new(uri.request_uri)
          un_response = http.request(un_request)
          if un_response.code == "200"
            puts "User #{name} has been logged"
            $unloggedFile['user'].delete(name)
            saveUnloggedVisits()
          else
            puts "Logging user #{name} gave: #{un_response.code} #{un_response.message}"
          end
        end
      end

      if ssh
        ssh.loop
      end
    end
  rescue SystemExit
    setDoorState(0, ssh)
    puts 'OOPS'
    exit
  rescue Exception => e
    setDoorState(0, ssh)
    puts "Oops #{e.inspect}"
  end

  scansFile.close if scansFile
  hotdesksFile.close if hotdesksFile
  visitsFile.close if visitsFile

  sleep 5
end

