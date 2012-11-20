#!/usr/bin/ruby

#nfc-list uses libnfc 1.5.1 (r1175)
#Connected to NFC device: ACS ACR 38U-CCID 00 00 / ACR122U102 - PN532 v1.4 (0x07)
#1 ISO14443A passive target(s) found:
#    ATQA (SENS_RES): 00  44  
#       UID (NFCID1): 04  ed  ab  d9  a1  25  80  
#      SAK (SEL_RES): 00  
#

require 'rubygems'
require 'yaml'
require 'net/http'
require 'dnsruby'

#YAML::ENGINE.yamler = 'syck'

class LCConfig
    def self.load
        @@config = YAML.load_file('config.yaml')
    end

    def self.config
        @@config
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

scansFile = nil
visitsFile = nil
$testUID = nil
visits = YAML.load_file('visits.yaml')
if visits.nil? or visits == false
    visits = {}
end
dayVisits = YAML.load_file('day_visits.yaml')
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
                time = Time.now
                today = Date.today.to_s
                scansFile.write("#{uid}\t#{time}\n")
                scansFile.flush
                user = LCConfig.config["users"][uid]
                while user and user["primary"]
                    uid = user["primary"]
                    user = LCConfig.config["users"][uid]
                end
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
                if access.index("full") || ENV['DOORBOT_ENV'] == 'doorbot2'
                    setDoorState(1)
                    close_door = true
                end
                last_day = dayVisits[uid]
                if last_day != today
                    dayVisits[uid] = today
                    if ENV['DOORBOT_ENV'] == 'doorbot1' and user and user["hotdesker"] == true and time.hour < 17
                        puts "Log hot desk visit by #{user["name"]}!"
                        puts `curl -v 'https://docs.google.com/spreadsheet/formResponse?formkey=dEVjX0I4VkoxdngtM2hpclROOXFSRWc6MQ&ifq' --max-redirs 0 -d 'entry.1.single=#{URI.escape(user["name"])}&entry.2.group=#{(time.hour < 13 ? '1' : '0.5')}&entry.2.group.other_option=&pageNumber=0&backupCache=&submit=Submit'`
                        if false
                            #res = Net::HTTP.post_form(uri, 'entry.1.single' => user["name"], 'entry.2.group' => '1' )
                            uri = URI('https://docs.google.com/spreadsheet/viewform?formkey=dEVjX0I4VkoxdngtM2hpclROOXFSRWc6MQ')
                            http = Net::HTTP.new(uri.host, uri.port)
                            http.use_ssl = true
                            req = Net::HTTP::Get.new(uri.path)
                            res = http.request(req)

                            uri = URI('https://docs.google.com/spreadsheet/formResponse?formkey=dEVjX0I4VkoxdngtM2hpclROOXFSRWc6MQ&ifq')
                            http = Net::HTTP.new(uri.host, uri.port)
                            http.use_ssl = true
                            req = Net::HTTP::Post.new(uri.path)
                            req['Referer'] = 'https://docs.google.com/spreadsheet/viewform?formkey=dEVjX0I4VkoxdngtM2hpclROOXFSRWc6MQ'
                            req['User-Agent'] = 'User-Agent:Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_4) AppleWebKit/534.57.2 (KHTML, like Gecko) Version/5.1.7 Safari/534.57.2'
                            req['Content-Type'] = 'application/x-www-form-urlencoded'
                            req.set_form_data(
                                'entry.1.single' => user["name"], 
                                'entry.2.group' => (time.hour < 13 ? '1' : '0.5'),
                                'pageNumber' => '0',
                                'backupCache' => '',
                                'submit' => 'Submit',
                                'entry.2.group.other_option' => '')

                            #puts "req=#{req.body}"
                            res = http.request(req)
                        #rescue Exception => e
                        #    puts "HTTP POST failed with #{e}"
                        end
                        puts res ? res.body : "result is nil!"
                    end
                    File.open("day_visits.yaml", "w") do |out|
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
                        blah = `#{cmd}`
                    else
                        blah = `espeak -v en "Thank you, welcome to duss Liverpool #{nickname}" 1> /dev/null 2>&1`
                    end
                    #blah = `play thanks-welcome.aiff > /dev/null 2> /dev/null`
                end
                File.open("visits.yaml", "w") do |out|

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
    #rescue Exception => e
    #    setDoorState(0)
    #    puts "Oops #{e.inspect}"
    end
    scansFile.close if scansFile
    visitsFile.close if visitsFile

    sleep 5
end
