#!/usr/bin/ruby

#nfc-list uses libnfc 1.5.1 (r1175)
#Connected to NFC device: ACS ACR 38U-CCID 00 00 / ACR122U102 - PN532 v1.4 (0x07)
#1 ISO14443A passive target(s) found:
#    ATQA (SENS_RES): 00  44  
#       UID (NFCID1): 04  ed  ab  d9  a1  25  80  
#      SAK (SEL_RES): 00  
#

require 'yaml'

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


scansFile = nil
visitsFile = nil
visits = YAML.load_file('visits.yaml')
if visits.nil? or visits == false
    visits = {}
end

while true
	begin
		scansFile = File.open("scans.log", "a")
		visitsFile = File.open("visits.log", "a")
		
		while true
            list = `nfc-list`
            matches = list.match(/UID.*: (.*)$/)
            if matches
                time = Time.now
                uid = matches[1].gsub(/ /,"")
                scansFile.write("#{uid}\t#{time}\n")
                scansFile.flush
                user = LCConfig.config["users"][uid]
                name = ""
                nickname = ""
                if user
                    puts "Visit from #{user["name"]}"
                    if user["mapme_at_code"]
                        puts "Should check into mapme.at"
                        puts `dig DoESLiverpool.#{Time.now.to_i}.#{user["mapme_at_code"]}.dns.mapme.at > /dev/null 2> /dev/null`
                    end
                    name = user["name"]
                    nickname = user["nickname"]
                    nickname = name if nickname.nil?
                end
                
                if visits[uid]
                    puts "#{uid} Left"
                    visitsFile.write("#{uid}\t#{visits[uid]["arrived_at"]}\t#{time}\t#{name}\n")
                    visitsFile.flush
                    blah = `espeak -v en "Thank you, goodbye #{nickname}" 1> /dev/null 2>&1`
                    #blah = `play thanks-goodbye.aiff > /dev/null 2> /dev/null`
                    visits[uid] = nil
                else
                    puts "#{uid} Arrived"
                    visits[uid] = { "arrived_at" => Time.now }
                    if user and user["ringtone"]
                        cmd = "play #{user["ringtone"]}"
                        puts "ringtone: #{cmd}"
                        blah = `#{cmd}`
                    elsif nickname.nil? or nickname == ''
                        blah = `espeak -v en "Thank you, welcome to duss Liverpool #{nickname}. Please talk to John and be inducted." 1> /dev/null 2>&1`
                    else
                        blah = `espeak -v en "Thank you, welcome to duss Liverpool #{nickname}" 1> /dev/null 2>&1`
                    end
                    #blah = `play thanks-welcome.aiff > /dev/null 2> /dev/null`
                end
                File.open("visits.yaml", "w") do |out|

                   YAML.dump(visits, out)

                end
            end
		end
    rescue SystemExit
        exit
    rescue Exception => e
        puts "Oops #{e.inspect}"
    end
    scansFile.close if scansFile
    visitsFile.close if visitsFile

    sleep 60
end
