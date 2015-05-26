#!/usr/bin/env lua
local brain = require "brain"
local lfs = require "lfs"

local script_name = arg[0]:match "[^/]+$"

local function open_append(name)
    return io.open(name, "a")
end

local function parse_args()
    local parser = require "argparse" (script_name)
        :description "Command line utility for the Brain bot engine."
    parser:option "--db"
        :description "Brain database filename."
        :default "brain.db"
    parser:option "--log"
        :description "Log error messages to a file."
        :convert(open_append)

    local cmd_learn = parser:command "learn"
        :description "Learns from the specified file."
    cmd_learn:mutex(
        cmd_learn:flag "-t" "--tweets"
            :description "Parses input as a 'tweets.csv' file from Twitter.",
        cmd_learn:flag "-i" "--irc"
            :description "Parses input as an IRC log.",
        cmd_learn:flag "-a" "--archive"
            :description "Parses input as an archive created by --save."
    )
    cmd_learn:flag "-c" "--create"
        :description "Creates a new database file."
    cmd_learn:option "-o" "--order"
        :description "Markov order."
        :default "2"
        :convert(tonumber)
    cmd_learn:option "-s" "--save"
        :description "Save the learned strings in a text file."
        :argname "<archive>"
        :convert(open_append)
    cmd_learn:argument "input"
        :description "Text file to learn."
        :convert(io.open)

    --[[local cmd_stats = ]]parser:command "stats"
        :description "Prints database stats."

    local cmd_reply = parser:command "reply"
        :description "Generates a reply based on the argument text."
    cmd_reply:option "-l" "--limit"
        :description "Maximum reply length in characters."
        :convert(tonumber)
    cmd_reply:argument "text"
        :args "*"
        :description "Text used to construct the reply."

    local cmd_tweet = parser:command "tweet"
        :description "Tweets a reply based on the argument text."
    cmd_tweet:argument "text"
        :args "*"
        :description "Text used to construct the reply."

    local cmd_connect = parser:command "connect"
        :description "Connects to a Twitter stream."
    cmd_connect:option "-u" "--user"
        :description "Learn tweets only from the specified user."
        :argname "<screen_name>"
    cmd_connect:option "-t" "--tweet-every"
        :description "Automatic tweet interval, in minutes."
        :argname "<minutes>"
        :default "60"
        :convert(tonumber)
    cmd_connect:option "-w" "--awake-time"
        :description "Hour of the day where the bot activates."
        :argname "<hour>"
        :default "12"
        :convert(tonumber)
    cmd_connect:option "-s" "--sleep-time"
        :description "Hour of the day where the bot sleeps."
        :argname "<hour>"
        :default "0"
        :convert(tonumber)
    cmd_connect:flag "-a" "--answer"
        :description "Answers to received replies."
    cmd_connect:option "-s" "--save"
        :description "Save the learned tweets in a text file."
        :argname "<archive>"
        :convert(open_append)

    local cmd_twitter = parser:command "twitter"
        :description "Twitter client configuration."

    local tw_login = cmd_twitter:command "login"
        :description "Authorizes the client with Twitter."
    tw_login:option "-k" "--consumer-key"
        :description "Application consumer key."
    tw_login:option "-s" "--consumer-secret"
        :description "Application consumer secret."

    --[[local tw_logout = ]]cmd_twitter:command "logout"
        :description "Deletes the auth info from the database."

    local tw_follow = cmd_twitter:command "follow"
        :description "Follows the specified user."
    tw_follow:argument "screen_name"
        :description "User to follow."

    local tw_unfollow = cmd_twitter:command "unfollow"
        :description "Unfollows the specified user."
    tw_unfollow:argument "screen_name"
        :description "User to unfollow."

    return parser:parse()
end

local function writeln(file, ...)
    file:write(...)
    file:write "\n"
end

local logfile
local function perror(...)
    writeln(io.stderr, ...)
    if logfile then
        writeln(logfile, ...)
    end
end

local function assert(res, err, ...)
    if res ~= nil then
        return res, err, ...
    else
        err = tostring(err)
        if logfile then
            writeln(logfile, "assert: ", debug.traceback(err, 2))
        end
        return error(err, 2)
    end
end

local function ask(str)
    io.stderr:write(str)
    return io.read()
end

local entities = { lt = "<", gt = ">", amp = "&" }

local function decode_entities(str)
    return str:gsub("&(%a+);", entities)
end

local function hour_in_range(s, e)
    local t = os.date("*t").hour
    return (s <= e and t >= s and t < e) or (s > e and (t >= s or t < e))
end

local function write_archive(file, text, id)
    if file then
        file:write(id or "", ":", text:gsub("\n", " "), "\n")
    end
end

-- skynet learn <file>
local function learn_text(bot, file, out)
    bot:begin_batch()
    local n = 0
    for line in file:lines() do
        bot:learn(line)
        write_archive(out, line)
        n = n + 1
    end
    bot:end_batch()
    perror("Learned ", n, " strings")
end

-- skynet learn --irc <file>
local function learn_irc(bot, file, out)
    bot:set_filter "u" -- remove url's
    bot:begin_batch()
    local n = 0
    for line in file:lines() do
        local text = line:match "<[^>]+>%s*(.*)"
        if text then
            bot:learn(text)
            write_archive(out, text)
            n = n + 1
        end
    end
    bot:end_batch()
    perror("Learned ", n, " messages")
end

-- skynet learn --tweets <file>
local function learn_twitter(bot, file, out)
    local lpeg = require "lpeg"
    local tablex = require "pl.tablex"
    local util = require "luatwit.util"
    local P, C, Cs, Ct  = lpeg.P, lpeg.C, lpeg.Cs, lpeg.Ct

    local qt   = P'"'
    local fsep = P','
    local rsep = P'\n' + P'\r\n'

    local unquoted_field = C( (1-(qt + fsep + rsep))^0 )
    local quoted_field   = qt * Cs( ((P(1)-qt) + P'""'/'"')^0 ) * qt
    local field          = quoted_field + unquoted_field
    local record         = Ct( field * (fsep*field)^0 )
    local line           = #P(1-rsep) * record * (rsep + -1) * lpeg.Cp()

    local function csv_next(str, cur)
        local row, pos = line:match(str, cur)
        return pos, row
    end

    -- parse header line
    local _, header = csv_next(file:read())
    assert(header, "invalid csv file")
    local cols = tablex.index_map(header)

    local data = file:read "*a"
    file:close()

    -- get the last tweet id from the first row
    local _, tweet = csv_next(data)
    local last_tweet_id = tweet[cols.tweet_id]
    local stored_id = bot.db:get_config "last_tweet_id"
    bot:begin_batch()
    if not stored_id or util.id_cmp(last_tweet_id, stored_id) > 0 then
        bot.db:set_config("last_tweet_id", last_tweet_id)
    end

    bot:set_filter "u@" -- remove url's and mentions
    local n = 0
    for _, row in csv_next, data do
        if row[cols.retweeted_status_id] == "" then   -- skip RTs
            local text = decode_entities(row[cols.text])
            bot:learn(text)
            write_archive(out, text, row[cols.tweet_id])
            n = n + 1
        end
    end
    bot:end_batch()

    perror("Learned ", n, " tweets")
end

-- skynet learn --archive <file>
local function learn_archive(bot, file, out)
    local util = require "luatwit.util"

    bot:set_filter "u@"
    bot:begin_batch()
    local n = 0
    local last_id = bot.db:get_config "last_tweet_id"
    for line in file:lines() do
        local id, text = line:match "(%d*):(.*)"
        if id then
            bot:learn(text)
            write_archive(out, text, id)
            n = n + 1
            if id ~= "" then
                if not last_id or util.id_cmp(id, last_id) > 0 then
                    last_id = id
                end
            end
        end
    end
    if last_id then
        bot.db:set_config("last_tweet_id", last_id)
    end
    bot:end_batch()
    perror("Learned ", n, " lines")
end

-- skynet reply [--limit <limit>] [text...]
local function print_reply(bot, text, limit)
    math.randomseed(os.time())
    print(bot:reply(text, limit))
end

-- skynet stats
local function print_stats(bot)
    local stats = bot.db:get_stats()
    print(string.format("markov order: %d\ntokens: %d\nstates: %d\ntransitions: %d",
        bot.order, stats.tokens, stats.states, stats.transitions))
end

local oauth_names = { "consumer_key", "consumer_secret", "oauth_token", "oauth_token_secret" }

local function load_keys(db)
    local keys = {}
    for _, name in ipairs(oauth_names) do
        keys[name] = db:get_config(name)
    end
    if not keys.oauth_token then
        perror("Error: Twitter keys not found.\nYou must login first with the '", script_name, " twitter login' command.")
        os.exit(1)
    end
    return keys
end

local function save_keys(db, ckey, csecret, token)
    db:exec "BEGIN"
    db:set_config("consumer_key", ckey)
    db:set_config("consumer_secret", csecret)
    db:set_config("oauth_token", token.oauth_token)
    db:set_config("oauth_token_secret", token.oauth_token_secret)
    db:exec "COMMIT"
end

-- skynet twitter login [--consumer-key <ckey>] [--consumer-secret <csecret>]
local function twitter_login(bot, ckey, csecret)
    local twitter = require "luatwit"

    ckey = ckey or bot.db:get_config "consumer_key" or ask "consumer key: "
    csecret = csecret or bot.db:get_config "consumer_secret" or ask "consumer secret: "
    local client = twitter.api.new{ consumer_key = ckey, consumer_secret = csecret }

    assert(client:oauth_request_token())
    perror("-- auth url: ", client:oauth_authorize_url())
    local pin = assert(ask("enter pin: "):match("%d+"), "invalid pin")
    local token = assert(client:oauth_access_token{ oauth_verifier = pin })
    save_keys(bot.db, ckey, csecret, token)

    perror("-- logged in as ", token.screen_name)
end

-- skynet twitter logout
local function twitter_logout(bot)
    bot.db:exec "PRAGMA secure_delete = true"
    bot.db:exec "BEGIN"
    for _, name in ipairs(oauth_names) do
        bot.db:unset_config(name)
    end
    bot.db:exec "COMMIT"
end

-- skynet twitter follow|unfollow <name>
local function twitter_follow(bot, name, follow)
    local twitter = require "luatwit"
    local client = twitter.api.new(load_keys(bot.db))
    if follow then
        assert(client:follow{ screen_name = name })
    else
        assert(client:unfollow{ screen_name = name })
    end
end

-- skynet tweet [text...]
local function twitter_tweet(bot, text)
    local twitter = require "luatwit"
    local client = twitter.api.new(load_keys(bot.db))
    math.randomseed(os.time())
    local reply = bot:reply(text, 140)
    perror("-- tweeting:\n", reply)
    assert(client:tweet{ status = reply })
end

-- skynet connect [--user <target_name>] [--tweet-every <tweet_interval>] [--answer] [--awake-time <awake_time>] [--sleep-time <sleep_time>]
local function twitter_connect(bot, tweet_interval, target_name, answer, awake_time, sleep_time, out)
    local twitter = require "luatwit"
    local util = require "luatwit.util"
    local client = twitter.api.new(load_keys(bot.db))

    perror "-- getting user info"
    local self_id = assert(client:verify_credentials()).id_str

    local target_id
    if target_name then
        local target = assert(client:get_user{ screen_name = target_name })
        if not target.following then
            local name = target.screen_name
            perror("Error: You're not following ", name, ".\nYou must follow the target user with '", script_name, " twitter follow ", name, "'")
            os.exit(1)
        end
        target_id = target.id_str
        perror("-- tracking ", target.screen_name)
    end

    local reply_queue = {}

    local function learn_tweet(tweet, do_answer)
        local not_rt = true
        if tweet.retweeted_status then
            tweet = tweet.retweeted_status
            not_rt = false
        end
        local user_id = tweet.user.id_str
        if user_id == self_id then return end   -- ignore own tweets
        local text = decode_entities(tweet.text)
        if do_answer and not_rt and tweet.in_reply_to_user_id_str == self_id then
            reply_queue[#reply_queue + 1] = { tweet, text }
        end
        if not target_id or user_id == target_id then
            print(string.format("<%s> %s", tweet.user.screen_name, text))
            bot:learn(text)
            write_archive(out, text, tweet.id_str)
        end
    end

    perror "-- loading timeline"
    local last_tweet_id = bot.db:get_config "last_tweet_id"
    local tl
    if target_id then
        tl = assert(client:get_user_timeline{ user_id = target_id, since_id = last_tweet_id, count = 100 })
    else
        tl = assert(client:get_home_timeline{ since_id = last_tweet_id, count = 100, include_entities = false })
    end

    bot:set_filter "u@" -- remove url's and mentions
    if out then
        out:setvbuf "line"
    end
    if #tl > 0 then
        bot:begin_batch()
        for i = #tl, 1, -1 do
            local tweet = tl[i]
            learn_tweet(tweet, false)
        end
        last_tweet_id = tl[1].id_str
        bot.db:set_config("last_tweet_id", last_tweet_id)
        bot:end_batch()
    end

    local last_tweet_time = tonumber(bot.db:get_config("last_tweet_time")) or 0

    perror "-- opening user stream"
    local stream = client:stream_user{ _async = 1, replies = target_id and "all" or nil }

    while true do
        local active, _, err, code = stream:is_active()
        if not active then
            if code then
                perror("-- stream closed with status ", code, ": ", err)
                if err ~= 503 then  -- Service Unavailable
                    break
                end
            else
                perror("-- stream closed with error: ", err)
            end
            return twitter_connect(bot, tweet_interval, target_name, answer, awake_time, sleep_time, out)
        end

        local last_id
        for obj in stream:iter() do
            if util.type(obj) == "tweet" then
                learn_tweet(obj, answer)
                last_id = obj.id_str
            end
        end
        if last_id then
            last_tweet_id = last_id
            bot.db:set_config("last_tweet_id", last_tweet_id)
        end

        if tweet_interval > 0 then
            local cur_time = os.time()
            if cur_time - last_tweet_time >= tweet_interval and hour_in_range(awake_time, sleep_time) then
                last_tweet_time = cur_time
                bot.db:set_config("last_tweet_time", last_tweet_time)
                local text = bot:reply(nil, 140)
                perror("-- tweeting: ", text)
                local res, err = client:tweet{ status = text }
                if res == nil then
                    perror("-- warning: tweet failed: ", err)
                end
            end
        end

        if answer then
            local reply = table.remove(reply_queue, 1)
            if reply then
                local tweet, input = unpack(reply)
                local text = bot:reply(input, 138 - #tweet.user.screen_name)
                perror("-- replying to ", tweet.user.screen_name, ": ", text)
                local res, err = tweet:reply{ status = text, _mention = true }
                if res == nil then
                    perror("-- warning: reply failed: ", err)
                end
            end
        end

        client.http:wait()
    end
end

local args = parse_args()

logfile = args.log
if logfile then
    logfile:setvbuf "line"
end
perror("-- started: ", os.date())

if lfs.attributes(args.db) then
    if args.create then
        perror("Error: output file '", args.db, "' already exists.")
        os.exit(1)
    end
else
    if not args.create then
        perror("Error: file '", args.db, "' not found.\nUse the --create option to create a new database.")
        os.exit(1)
    end
end

local bot = brain.new(args.db, args.order)

if args.learn then
    if args.tweets then
        learn_twitter(bot, args.input, args.save)
    elseif args.irc then
        learn_irc(bot, args.input, args.save)
    elseif args.archive then
        learn_archive(bot, args.input, args.save)
    else
        learn_text(bot, args.input, args.save)
    end
elseif args.stats then
    print_stats(bot)
elseif args.reply then
    local text = next(args.text) and table.concat(args.text, " ")
    print_reply(bot, text, args.limit)
elseif args.tweet then
    local text = next(args.text) and table.concat(args.text, " ")
    twitter_tweet(bot, text)
elseif args.connect then
    twitter_connect(bot, args.tweet_every * 60, args.user, args.answer, args.awake_time, args.sleep_time, args.save)
elseif args.twitter then
    if args.login then
        twitter_login(bot, args.consumer_key, args.consumer_secret)
    elseif args.logout then
        twitter_logout(bot)
    elseif args.follow then
        twitter_follow(bot, args.screen_name, true)
    elseif args.unfollow then
        twitter_follow(bot, args.screen_name, false)
    end
end
