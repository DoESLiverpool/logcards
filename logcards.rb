#!/usr/bin/ruby

#nfc-list uses libnfc 1.5.1 (r1175)
#Connected to NFC device: ACS ACR 38U-CCID 00 00 / ACR122U102 - PN532 v1.4 (0x07)
#1 ISO14443A passive target(s) found:
#    ATQA (SENS_RES): 00  44  
#       UID (NFCID1): 04  ed  ab  d9  a1  25  80  
#      SAK (SEL_RES): 00  
#

require 'yaml'
require 'net/http'

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
dayVisits = YAML.load_file('day_visits.yaml')
if dayVisits.nil? or dayVisits == false
    dayVisits = {}
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
                today = Date.today.to_s
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
                
                last_day = dayVisits[uid]
                if last_day != today
                    dayVisits[uid] = today
                    if user and user["hotdesker"] == true and time.hour < 17
                        puts "Log hot desk visit by #{user["name"]}!"
                        puts `curl -v 'https://docs.google.com/spreadsheet/formResponse?formkey=dEVjX0I4VkoxdngtM2hpclROOXFSRWc6MQ&ifq' --max-redirs 0 -d 'entry.1.single=#{URI.escape(user["name"])}&entry.2.group=1&entry.2.group.other_option=&pageNumber=0&backupCache=&submit=Submit'`
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
                    puts "#{uid} Arrived"
                    visits[uid] = { "arrived_at" => time }
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
