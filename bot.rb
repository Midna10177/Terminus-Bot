#!/usr/bin/ruby

#
#    Terminus-Bot: An IRC bot to solve all of the problems with IRC bots.
#    Copyright (C) 2010  Terminus-Bot Development Team
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Affero General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Affero General Public License for more details.
#
#    You should have received a copy of the GNU Affero General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

require 'socket'
require 'logger'
require 'thread'
require 'timeout'
require 'strscan'
require 'fileutils'

class TerminusBot

  attr_reader :configClass, :modules, :network, :modConfig, :config, :channels, :modHelp, :admins
  attr_writer :admins

  # Create a new instance of Terminus-Bot. This will initialize
  # a few data structures, though most of the real work happens
  # when run() is called.
  # @param [Config] configClass The Config class object that contains the bot's settings.
  def initialize(configClass)

    @config = configClass.config
    @configClass = configClass
    @channels = Hash.new
    @admins = Hash.new

  end

  # Send a raw string directly to the IRC server. This bypasses
  # throttling, so it should not be called directly.
  # @param [String] msg The data to send to the IRC server.
  # @example Join a channel
  # raw("JOIN #terminus-bot")
  # @example Kick someone with the kick reason "spammer"
  # raw("KICK haxor :spammer")
  def raw(msg)
    $socket.puts(msg)
  end

  # Start the bot! Initialize the thread pool, load modules, and connect.
  def run
    $log.debug("pool") { "Thread pool init started." }
    @incomingQueue = Queue.new
    
    @threads = Array.new(5) {
      Thread.new {
        $log.debug("pool") { "Thread started." }
        while true
          request = @incomingQueue.pop

          begin
            Timeout::timeout(45){ messageReceived(request) }
          rescue Timeout::Error => e
            $log.warn("pool") { "Request timed out: #{request}" }
          rescue => e
            $log.warn("pool") { "Request failed: #{e}" }
          end
        end
      }
    }

    $scheduler = Scheduler.new(configClass)
    $scheduler.start
    @configClass = configClass

    $log.debug('initialize') { 'Loading modules.' }

    @modConfig = ModuleConfiguration.new
    @modHelp = ModuleHelp.new

    @modules = Array.new()
    Dir.foreach("modules") { |f|
      unless f =~ /^\.+$/
        line = 0
        begin
          modName = f.match(/([^\.]+)/)[1]
          mod = IO.read("./modules/#{f}")
          mod = "class Mod_#{modName} \n #{mod} \n end \n Mod_#{modName}.new"
          @modules << eval(mod, nil, f, line)
        rescue => e
          $log.error('initialize') { "I was unable to load the module #{f}: #{e}" }
          puts e.backtrace
        end
      end
    }

    $scheduler.add("Configuration Auto-Save", Proc.new { @configClass.saveConfig }, 300, true)

    @network = Network.new
    $socket = TCPSocket.open(@config["Address"], @config["Port"])
    raw "NICK " + @config["Nick"]
    raw "USER #{@config["UserName"]} 0 * #{@config["RealName"]}"

    $scheduler.add("Keep-Alive Pinger", Proc.new { sendRaw("PING #{Time.now.to_i}") }, 360, true)

    # Some servers don't send PING and end up disconnecting us!
    # So let's talk to them, just in case. 4 minutes seems good.
    until $socket.eof? do
      msg = $socket.gets.chomp

      # Go ahead and handle server PING first!
      # We don't want to get a ping timeout because
      # the queue is full.
      if msg =~ /^PING (:.*)$/
        raw "PONG #{$1}"
        next
      end

      # Throw it in the pool!
      @incomingQueue << msg

    end   

    $log.info('exit') { "Socket closed, starting exit procedure." }

    fireHooks("bot_exiting")
    @configClass.saveConfig
    
    $log.info('exit') { "Removing lock file .lock" }
    File.delete ".lock"

    $log.info('exit') { "Exit procedures complete. Exiting!" }
    $log.close

    exit
  end

  # This is for the thread pool workers to call when they get a message.
  # @param [String] msg A raw string from the IRC server.
  def messageReceived(msg)
    msg = msg.match(/^:?(.*)$/)[1]
    msgArr = msg.split(' ')

    # We'll start with this. If we find out we're wrong, change it.
    type = SERVER_MSG

    case msgArr[1]
      when "PRIVMSG"
        type = (msg =~ /#{1.chr}[^ ]+ ?.*#{1.chr}/ ? CTCP_REQUEST : PRIVMSG)

      when "NOTICE"
        type = (msg =~ /#{1.chr}[^ ]+ ?.*#{1.chr}/ ? CTCP_REPLY : NOTICE)

      # And now, on to the numerical codes.
      # I don't have all of these on here, but it would
      # be trivial to add more. What I do have here is
      # mostly for logging and debugging, anyway.
      when "004"
        @network.currentServer = msgArr[3]
        @network.serverSoftware = msgArr[4]
      when "005"
        msgArr.each { |param|
          paramArr = param.split("=")
          case paramArr[0]
            when "NETWORK"
              @network.name = paramArr[1]
            when "MAXCHANNELS"
              @network.maxChannels = paramArr[1]
            when "CHANNELLEN"
              @network.maxChannelNameLength = paramArr[1]
            when "TOPICLEN"
              @network.maxTopicLength = paramArr[1]
            when "KICKLEN"
              @network.maxKickLength = paramArr[1]
            when "AWAYLEN"
              @network.maxAwayLength = paramArr[1]
            when "MAXTARGETS"
              @network.maxTargets = paramArr[1]
            when "MODES"
              @network.maxModes = paramArr[1]
            when "CHANTYPES"
              @network.channelTypes = paramArr[1]
            when "CHANMODES"
              @network.channelModes = paramArr[1]
            when "CASEMAPPING"
              @network.caseMapping = paramArr[1]
            when "PREFIX"
              prefixArr = paramArr[1].match(/^\(([^\)]+)\)(.*)$/)
              if prefixArr[1].length != prefixArr[2].length
                $log.warn('parser') { "The IRC server has provided an oddly-formatted list of nick mode prefixes." }
              end

              @network.prefixes = Hash.new()
              scannerPrefixes = StringScanner.new(prefixArr[1])
              scannerModes = StringScanner.new(prefixArr[2])

              scanLength = (prefixArr[1].length >= prefixArr[2].length ? prefixArr[2].length : prefixArr[1].length) - 1

              for i in 0..scanLength
                @network.prefixes[prefixArr[2][i].chr] = prefixArr[1][i].chr
              end

              $log.debug('parser') { "Prefixes: #{@network.prefixes}" }
            when "MAXLIST"
              maxListArrs = paramArr[1].split(",")
              maxListArrs.each { |maxListArr|
                maxListArr = maxListArr.split(":")                  
                if maxListArr[0] == "b"
                  @network.maxBans = maxListArr[1]
                elsif maxListArr[0] == "e"
                  @network.maxExempts = maxListArr[1]
                elsif maxListArr[0] == "I"
                  @network.maxInviteExempts = maxListArr[1]
                else
                  $log.warn('parser') { "Invalid MAXLIST parameter: #{maxListArr.join(":")}" }
                end
              }
        
          end
        }
      when "MODE" # Someone is joining something!
        type = MODE_CHANGE

      when "JOIN" # Someone is joining something!
        type = JOIN_CHANNEL

      when "PART" # Someone is joining something!
        type = PART_CHANNEL

      when "NICK" # Someone is changing nicks!
        type = NICK_CHANGE

      when "352" #who reply
        type = WHO_REPLY
        
      when "324" #channel modes
        type = CHANNEL_MODES

      when "332" #channel topic
        type = CHANNEL_TOPIC

      when "367" #ban list
        type = BAN_LIST
      when "348" #exception mask reply
        type = BAN_EXEMPT_LIST
      when "346" #invite mask data
        type = INVITE_EXEMPT_LIST
=begin
      when "315" #end of who reply
      when "331" #no topic
      when "341" #invite success
      when "342" #summoning
      when "347" #end of invite masks
      when "349" #end of exception masks
      when "351" #server version reply
      when "364" #links
      when "365" #end of links
      when "368" #end of ban list
      when "375" #motd start
      when "381" #oper success
      when "382" #rehashing
      when "391" #server time
      when "219" #end of stats
      when "242" #stats uptime
      when "243" #stats oline
      when "221" #own mode reply
      when "256" #admin info 1
      when "257" #admin info 2
      when "258" #admin info 3
      when "259" #admin info 4
      when "263" #command dropped, try again
      when "401" #no suck nick/channel
      when "402" #no such server
      when "403" #no such channel
      when "404" #cannot send to channel
      when "405" #too many channels
      when "406" #was no such nick
      when "407" #too many targets
      when "412" #no text to send
      when "415" #bad server/host mask
      when "421" #unknown command
      when "423" #no admin info
      when "431" #no nick given
      when "432" #erroneous nick (on change)
      when "433" #nick in use (on change)
      when "436" #nick collision
      when "437" #resource unavailable
      when "441" #nick isn't on channel
      when "442" #you're not on that channel
      when "443" #user already on channel (after invite)
      when "444" #user not logged in (after summon)
      when "445" #summon disabled
      when "446" #user disabled
      when "451" #not registered
      when "461" #not enough params
      when "462" #already registered, illegal command
      when "463" #no oper for host
      when "464" #password incorrect
      when "465" #you are banned from the server
      when "466" #you are about to be banned from server
      when "467" #key already set
      when "471" #cannot join, at +l
      when "472" #unknown mode char for channel
      when "473" #cannot join, +i
      when "474" #cannot join, +b
      when "475" #cannot join, wrong key
      when "476" #bad channel mask
      when "477" #chan doesn't support modes
      when "478" #channel ban list full
      when "481" #no oper privileges
      when "482" #no chan oper privileges
      when "483" #cannot kill a server
      when "484" #connection restricted
      when "485" #you are not channel creator
      when "491" #no o-lines for your host
      when "501" #unknown mode flag
      when "502" #cannot change mode for other users
      when "353" #names list
      when "366" #end of names list
=end

      when "376" #end of motd
        $log.debug('parser') { "End of MOTD." }
        finishedConnecting          

      when "422" #motd not found
        $log.debug('parser') { "MOTD not found." }
        finishedConnecting          

      #else
      #  $log.debug('parser') { "Unknown message type: #{msg}" }
    end

    processIRCMessage(IRCMessage.new(msg, type))
  end

  
  # This should run once when we're done connecting.
  # Set modes, join channels, and do whatever else we need.
  def finishedConnecting
    unless @alreadyFinished

      # Tell the server we're a bot.
      # TODO: Make sure the server supports this mode.
      sendMode(@config["Nick"], "+B")

      # TODO: Feed this through something in outgoing.rb to split up
      #       joins that exceed the server maximum found in @network.
      sendRaw "JOIN #{@config["Channels"].join(",")}"

      @alreadyFinished = true

    end
  end

  # Send a QUIT message to the server. This will (hopefully) cause
  # the server to disconnect us.
  # @param [String] quitMessage The quit message to use when disconnecting. This may be shown to users as a quit message, depending on server configuration.
  # @example
  # quit("Gee, look at the time! Gotta go!")
  def quit(quitMessage = @config["QuitMessage"])
    raw 'QUIT :' + quitMessage
  end

  # Once we're done parsing the message, we send it here.
  # First, we'll send it off to command hooks (cmd_name) in the
  # modules. Then, we fire generic events, such as bot_raw and bot_notice.
  # @param [IRCMessage] msg An object representing the parsed server message.
  def processIRCMessage(msg)

    # First, we're going to fire command hooks. The first word of the
    # message is used as the command name. If the message is sent in
    # a channel, the command prefix must be used, and is extracted
    # via regular expression.
    #
    # The header of the function in the module must be:
    #
    #  cmd_name(message)
    #
    #   "name" is the word that will trigger the command. 
    #   "message" is an IRCMessage object that represents the message
    #     that triggered the command.

    if msg.type == PRIVMSG or msg.type == NOTICE
      cmd = msg.msgArr[0].downcase

      if cmd =~ /\A#{Regexp.escape @config["Prefix"]}(.*)/
        cmd = $1
        cmd.gsub!(/[^a-z]/, "_")
        fireHooks("cmd_#{cmd}", msg)
      elsif msg.private?
        cmd.gsub!(/[^a-z]/, "_")
        fireHooks("cmd_#{cmd}", msg)
      end
    end
    
    fireHooks("bot_raw", msg)

    # We'll fire module hooks and run core stuff in the same go.
    case msg.type
      when PRIVMSG
        fireHooks("bot_privmsg", msg)
      when CTCP_REQUEST
        fireHooks("bot_ctcpRequest", msg)
      when CTCP_REPLY
        fireHooks("bot_ctcpReply", msg)
      when NOTICE
        fireHooks("bot_notice", msg)
      when WHO_REPLY
        #0-amethyst.sinsira.net 1-352 2-Terminus-Bot 3-#terminus-bot 4-Kabaka 5-sectoradmin.sinsira.net 6-emerald.sinsira.net 7-Kabaka 8-Hr*~ :9-1 10-Kabaka!
        # <channel> <user> <host> <server> <nick>
        # ( "H" / "G" > ["*"] [ ( "@" / "+" ) ]
        # :<hopcount> <real name>"
        $log.debug('process') { "Who Reply: #{msg.raw}" }
        @channels[msg.rawArr[3]] = Channel.new(msg.rawArr[3]) if @channels[msg.rawArr[3]] == nil
        
        whoUser = IRCUser.new("#{msg.rawArr[7]}!#{msg.rawArr[4]}@#{msg.rawArr[5]}")
        whoModes = Array.new

        msg.rawArr[8].each_char { |c|
          whoModes << @network.prefixes[c] if @network.prefixes.keys.include? c
        }

        @channels[msg.rawArr[3]].join(whoUser)
        @channels[msg.rawArr[3]].users[whoUser.nick].channelModes = whoModes
        

      when NICK_CHANGE
        #WiZ!jto@tolsun.oulu.fi NICK Kilroy
        newNick = msg.rawArr[2].match(/:?(.*)/)[1]
        @channels.each_value { |chan|
          chan.nickChange(msg.speaker.nick, newNick)
        }

        if @config["Nick"] == msg.speaker.nick
          $log.info('process') { "Bot is changing nick to #{newNick}" }
          @config["Nick"] = newNick
        end

        fireHooks("bot_nickChange", msg)
      when JOIN_CHANNEL
        @channels[msg.message] = Channel.new(msg.message) if @channels[msg.message] == nil

        @channels[msg.message].join(msg.speaker)
        if msg.speaker.nick == @config["Nick"]
          sendRaw("WHO #{msg.message}")
          sendRaw("MODE #{msg.message}")
          sendRaw("MODE #{msg.message} b")
          sendRaw("MODE #{msg.message} e")
          sendRaw("MODE #{msg.message} I")
        end

        fireHooks("bot_joinChannel", msg)
      when PART_CHANNEL
        @channels[msg.destination].part(msg.speaker)

        fireHooks("bot_partChannel", msg)
      when CHANNEL_TOPIC
        $log.debug('process') { "New topic for channel #{msg.rawArr[3]}" }
        @channels[msg.rawArr[3]].topic = msg.message
      when CHANNEL_MODES
        mode = msg.rawArr[4..msg.rawArr.length].join(" ")

        @channels[msg.rawArr[3]].modeChange(mode)
      when MODE_CHANGE
        unless msg.private?
          mode = msg.rawArr[3..msg.rawArr.length].join(" ")

          @channels[msg.destination].modeChange(mode)
        end
      when BAN_LIST
        @channels[msg.rawArr[3]].addBan(msg.rawArr[4])
      when INVITE_EXEMPT_LIST
        @channels[msg.rawArr[3]].addInviteExempt(msg.rawArr[4])
      when BAN_EXEMPT_LIST
        @channels[msg.rawArr[3]].addBanExempt(msg.rawArr[4])
    end
 
  end

  # Try to fire the given method in all loaded modules with
  # optional message parameter.
  # @param [String] cmd The name of the method that will be called.
  # @param [IRCMessage] msg An object representing a parsed server message. This won't be used in a few cases.
  # @example
  # fireHooks("bot_quit")
  # @example
  # fireHooks("bot_notice", message)
  def fireHooks(cmd, msg = nil)
      @modules.each do |m|
         begin
           if m.respond_to?(cmd)
             msg == nil ? m.send(cmd) : m.send(cmd,msg)
           end
         rescue => e
           $log.warn("fireHooks") { "Module failed to complete #{cmd}: #{e}" }
           unless msg == nil
             reply(msg, "There was a problem executing your command with one of my modules. Sorry!")
           end
         end
      end
  end
end

# Load all files in the given directory.
# @param [String] dir The base directory from which files will be recursively loades.
# @example
# enumerateIncludes("./includes/")
def enumerateIncludes(dir)
  $log.debug('init-enum') { "Enumerating files in #{dir}" }
  Dir.foreach(dir) { |f|
    unless f =~ /\A\.\.?\Z/
      f = dir + '/' + f
      if File.directory? f
        enumerateIncludes(f)
      elsif File.exists? f
        load f
      end
    end
  }

end

print <<EOF
 
 _______                  _                        ____        _
|__   __|                (_)                      |  _ \\      | |
   | | ___ _ __ _ __ ___  _ _ __  _   _ ___ ______| |_) | ___ | |_
   | |/ _ \\ '__| '_ ` _ \\| | '_ \\| | | / __|______|  _ < / _ \\| __|
   | |  __/ |  | | | | | | | | | | |_| \\__ \\      | |_) | (_) | |_
   |_|\\___|_|  |_| |_| |_|_|_| |_|\\__,_|___/      |____/ \\___/ \\__|

Terminus-Bot: An IRC bot to solve all of the problems with IRC bots.
Copyright (C) 2010  Terminus-Bot Development Team

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License along with this program.  If not, see <http://www.gnu.org/licenses/>.

EOF

if File.zero? "configuration"

  puts "The configuration file is empty. Since there is a back-up, I will recover and use it."

  FileUtils.cp "configuration.bak", "configuration"

  if File.zero? "configuration"
    puts "It looks like I wasn't able to recover your configuration file. I copied the back-up, but it appears empty as well."
    puts "Please check recent logs (found in the logs directory). They might contain hints about what went wrong in the first place."
    puts "Please contact the Terminus-Bot development team at <http://terminus-bot.net/> for help."
    exit
  else
    puts "Recovery successful!"
    puts "Any changes to configuration or module data since the last run has been lost."
  end
end



if File.exists? ".lock" and not File.zero? ".lock"
  pid = Integer(IO.read(".lock").chomp)

  begin
    Process.getpgid( pid )
    puts "This Terminus-Bot appears to be running as #{pid}. You may only run one at a time."
    puts "If (and only if) you know this is an error, delete the .lock file and try again."
    exit
  rescue Errno::ESRCH
    #puts "It looks like Terminus-Bot did not exit gracefully last time it was run. Checking for problems..."
    #puts "Done recovering from errors."
  end
end

FileUtils.touch ".lock"

Dir.mkdir 'logs' unless File.directory? 'logs'

$log = Logger.new('logs/system.log', 'weekly');

if ARGV.include? "--debug"
  $log.level = Logger::DEBUG
else
  $log.level = Logger::INFO
end

$log.info('init') { 'Terminus-Bot is now starting.' }

puts "Loading configuration..."

$log.debug('init') { 'Loading configuration.' }
load "config.rb"

configClass = Config.new

puts "Configuration loaded. Running in background..."

pid = fork do

  $log.debug('init') { 'Loading core bot files.' }
  enumerateIncludes("./includes/")

  # We have the classes we need to build our config. Go!
  configClass.readConfig

  $log.debug('init') { 'Firing off the bot.' }
  #puts "Done. Establishing IRC connection..."
  $bot = TerminusBot.new(configClass)

  $log.info('init') { 'Bot started! Now running.' }

  trap("INT"){ $bot.quit("Interrupted by host system. Exiting!") }
  trap("TERM"){ $bot.quit("Terminated by host system. Exiting!") }
  trap("KILL"){ exit } # Kill (signal 9) is pretty hardcore. Just exit!

  trap("HUP", "IGNORE") # We don't need to die on HUP.

  $bot.run
end

File.open(".lock", "w").puts(pid)

Process.detach pid

