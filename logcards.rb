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
require 'dnsruby'
require 'tzinfo'

#YAML::ENGINE.yamler = 'syck'

class LCConfig
    def self.load
        @@config = YAML.load_file('config.yaml')
        @@tz = nil
        if @@config["settings"] and @@config["settings"]["timezone"]
          @@tz = TZInfo::Timezone.get(@@config["settings"]["timezone"])
        end
    end

    def self.config
        @@config
    end

    def self.tz
        @@tz
    end

    def self.env
      @@config["environments"][ENV['DOORBOT_ENV']]
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


LCConfig.load
puts LCConfig.config.inspect
LCConfig.setup_signal

special_sounds = {
    '10-31' => [
        'halloween/cackle3.wav',
        'halloween/creakdoor2.wav',
        'halloween/ghost5.wav',
        'halloween/howling1.wav',
        'halloween/thunder12.wav'
    ]
}

def setDoorState(state)
    `echo #{state} > /sys/class/gpio/gpio25/value`
end

puts "DoorBot: #{ENV["DOORBOT_ENV"]}"

if LCConfig.env.nil?
  puts "Error! Must specify a valid doorbot environment."
  exit
end

VISITS_YAML = 'visits.yaml'
DAY_VISITS_YAML = 'day_visits.yaml'

scansFile = nil
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
    scansFile = File.open("scans.log", "a")
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
              list = `./rcapp`
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
                        blah = `espeak -v en "Recursion error!"`
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
                    puts "Visit from #{user["name"]}"
                    name = user["name"]
                    nickname = user["nickname"]
                    nickname = name if nickname.nil?
                else
                    puts "#{uid} was unrecognised"
                    blah = `espeak -v en "Thank you, welcome to duss Liverpool #{nickname}. Please talk to John and be inducted." 1> /dev/null 2>&1`
                    next
                end
                
                access = user["access"] || []
                close_door = false
                access_required = LCConfig.env['access'] || []
                if LCConfig.env.has_key?('access') && ( access_required.length == 0 || ( access_required & access ).length > 0 )
                    setDoorState(1)
                    close_door = true
                end
                last_day = dayVisits[uid]
                if last_day != today
                    dayVisits[uid] = today
                    if LCConfig.env['loghotdesk'] and user and user["hotdesker"] == true and time.hour < 21
                        days_used = 1
                        if time.hour >= 17
                          days_used = 0.25
                        elsif time.hour >= 13
                          days_used = 0.5
                        end
                        puts "Log hot desk visit by #{user["name"]}!"
                        puts `curl -v 'https://docs.google.com/spreadsheet/formResponse?formkey=dEVjX0I4VkoxdngtM2hpclROOXFSRWc6MQ&ifq' --max-redirs 0 -d 'entry.1.single=#{URI.escape(user["name"])}&entry.2.group=#{days_used}&entry.2.group.other_option=&pageNumber=0&backupCache=&submit=Submit'`
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
                if last_visit
                    puts "#{uid} Left"
                    visitsFile.write("#{uid}\t#{last_visit["arrived_at"]}\t#{time}\t#{name}\n")
                    visitsFile.flush
                    blah = `espeak -v en "Thank you, goodbye #{nickname}" 1> /dev/null 2>&1`
                    #blah = `play thanks-goodbye.aiff > /dev/null 2> /dev/null`
                    visits[uid] = nil
                else
                    special_sound = nil
                    day_sounds = special_sounds["#{time.month}-#{time.day}"]
                    if day_sounds
                        special_sound = day_sounds.sample
                    end
                    puts "#{uid} Arrived"
                    visits[uid] = { "arrived_at" => time }
                    if special_sound
                        cmd = "play #{special_sound}"
                        puts "ringtone: #{cmd}"
                        blah = `#{cmd}`
                    elsif user and user["ringtone"]
                        cmd = "play wav/#{user["ringtone"]}"
                        puts "ringtone: #{cmd}"
                        begin
                          blah = `#{cmd}`
                        rescue Exception
                          sleep 4
                        end
                    else
                        blah = `espeak -v en "Thank you, welcome to duss Liverpool #{nickname}" 1> /dev/null 2>&1`
                    end
                    #blah = `play thanks-welcome.aiff > /dev/null 2> /dev/null`
                end
                File.open(VISITS_YAML, "w") do |out|

                   YAML.dump(visits, out)

                end
                if close_door
                    setDoorState(0)
                end
                if user and user["mapme_at_code"]
                    puts "Should check into mapme.at"
                    host = "DoESLiverpool.#{Time.now.to_i}.#{user["mapme_at_code"]}.dns.mapme.at"
                    Dnsruby::DNS.open {|dns|
                        puts dns.getresource(host, "TXT")
                    }

                    #puts `dig DoESLiverpool.#{Time.now.to_i}.#{user["mapme_at_code"]}.dns.mapme.at > /dev/null 2> /dev/null`
                end
            end
    end
    rescue SystemExit
        setDoorState(0)
        exit
    rescue Exception => e
        setDoorState(0)
        puts "Oops #{e.inspect}"
    end
    scansFile.close if scansFile
    visitsFile.close if visitsFile

    sleep 5
end
