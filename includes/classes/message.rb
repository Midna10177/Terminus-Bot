
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
#

#Declare to constants since we don't have enums in Ruby.
#There are more graceful solutions, but this will do for now.

CTCP_REQUEST = -2
CTCP_REPLY = -1
SERVER_MSG = 0
PRIVMSG = 1
NOTICE = 2
NICK_CHANGE = 3
JOIN_CHANNEL = 4
PART_CHANNEL = 5
WHO_REPLY = 6
CHANNEL_MODES = 7
CHANNEL_TOPIC = 8
MODE_CHANGE = 9
BAN_LIST = 10
BAN_EXEMPT_LIST = 11
INVITE_EXEMPT_LIST = 12

require 'date'

class IRCMessage
  attr_reader :destination, :message, :speaker, :timestamp, :msgArr, :args, :replyTo, :type, :raw, :rawArr

  def initialize(raw, type)
    case type
      when JOIN_CHANNEL..PART_CHANNEL
        @message = raw.match(/:(.*)/)[1] rescue ""
      when CTCP_REQUEST..CTCP_REPLY
        @message = raw.match(/#{1.chr}(.*)#{1.chr}/)[1]
      else # privmsg, notice, scheduled (pseudo-privmsg)
        @message = raw.match(/^[^:]+:(.*)$/)[1] rescue raw
    end

    @raw = raw
    @rawArr = raw.split(" ")

    @msgArr = message.split(" ")

    @type = type
    @destination = @rawArr[2]
    @speaker = IRCUser.new(@rawArr[0])
    @timestamp = DateTime.now

    @args = @msgArr.clone()
    @args.delete_at(0)
    @args = @args.join(" ")

    @replyTo = (self.private? ? @speaker.nick : @destination)
  end

  # Determine if a message was sent privately or in public (to a channel).
  # @return [Boolean] True if the message was not sent to a channel.
  # @example
  #   if message.private?
  #     $log.info("myModule") { "Someone sent me a private message!" }
  #   else
  #     $log.info("myModule") { "Someone sent a message to a channel." }
  #   end  
  def private?
    not $bot.network.isChannel? @destination
  end
  
  # Return a string representation of the user as nick!user@host
  # @example
  #   puts user.to_s
  #   # => "Terminus-Bot!Terminus@terminus.net"
  def to_s
    @message
  end
end
