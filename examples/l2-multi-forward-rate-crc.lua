--- Forward packets between two ports
-- local lm     = require "libmoon"
local mg     = require "moongen"
local memory = require "memory"
local device = require "device"
local ts     = require "timestamping"
local histogram = require "histogram"
local stats  = require "stats"
local log    = require "log"
local timer		= require "timer"

-- local limiter = require "software-ratecontrol"

function configure(parser)
	parser:description("Forward traffic between interfaces with moongen rate control")
	parser:argument("dev", "Devices to use, now accepts four devices, for two links!"):args(4):convert(tonumber)
	--parser:option("-r --rate", "Transmit rate in Mpps."):args(1):default(2):convert(tonumber)
	parser:argument("rate", "Forwarding rates in Mbps (four values for four links)"):args(4):convert(tonumber)
	parser:option("-t --threads", "Number of threads per forwarding direction using RSS."):args(1):convert(tonumber):default(1)
	return parser:parse()
end

function master(args)
	-- configure devices
	for i, dev in ipairs(args.dev) do
		args.dev[i] = device.config{
			port = dev,
			txQueues = args.threads,
			rxQueues = args.threads,
			rssQueues = 0,
			rssFunctions = {},
			-- 
			rxDescs = 32,
			dropEnable = true,
			disableOffloads = true
		}
	end
	device.waitForLinks()

	-- print stats
	stats.startStatsTask{devices = args.dev}

	-- start forwarding tasks
	for i = 1, args.threads do
		print("dev is ",tonumber(args.dev[1]["id"]))
		--rateLimiter1 = limiter:new(args.dev[2]:getTxQueue(i - 1), "cbr", 1 / args.rate[1] * 1000)
		mg.startTask("forward", args.dev[1]:getRxQueue(i - 1), args.dev[2]:getTxQueue(i - 1), args.dev[2], args.rate[1])
		mg.startTask("forward", args.dev[2]:getRxQueue(i - 1), args.dev[1]:getTxQueue(i - 1), args.dev[1], args.rate[2])

		--if args.dev[3] >= 0 then
			mg.startTask("forward", args.dev[3]:getRxQueue(i - 1), args.dev[4]:getTxQueue(i - 1), args.dev[4], args.rate[3])
			mg.startTask("forward", args.dev[4]:getRxQueue(i - 1), args.dev[3]:getTxQueue(i - 1), args.dev[3], args.rate[4])
		--end
	end
	mg.waitForTasks()
end

function forward(rxQueue, txQueue, txDev, rate)
	print("forward with rate "..rate)
	local ETH_DST	= "11:12:13:14:15:16"
	local pattern = "cbr"
	local numThreads = 1

	local count_hist = histogram:new()
	local size_hist = histogram:new()
	
	local linkspeed = txDev:getLinkStatus().speed
	print("linkspeed = "..linkspeed)

	-- larger batch size is useful when sending it through a rate limiter
	local bufs = memory.createBufArray()  --memory:bufArray()  --(128)
	local dist = pattern == "poisson" and poissonDelay or function(x) return x end
	while mg.running() do
		-- receive one or more packets from the queue
		local count = rxQueue:recv(bufs)

		count_hist:update(count)

		for iix=1,count do
			local buf = bufs[iix]
			if (buf ~= nil) then    -- should not be necessary
				local pktSize = buf.pkt_len + 24
				--print("forwarding packet of size ",pktSize)
				--buf:setDelay(dist(10^10 / numThreads / 8 / (rate * 10^6) - pktSize - 24))
				--buf:setDelay((pktSize+24) * (linkspeed/rate - 1) )
				size_hist:update(buf.pkt_len)
				buf:setDelay((pktSize) * (linkspeed/rate - 1) )
			end
		end

		-- the rate here doesn't affect the result afaict.  It's just to help decide the size of the bad pkts
		txQueue:sendWithDelay(bufs, rate * numThreads, count)
		--txQueue:sendWithDelay(bufs)
	end
	
	count_hist:print()
	count_hist:save("pkt-count-distribution-histogram-"..tonumber(txDev["id"])..".csv")
	size_hist:print()
	size_hist:save("pkt-size-distribution-histogram-"..tonumber(txDev["id"])..".csv")
end


function forward2(rxQueue, txQueue, rateLimiter)
	-- a bufArray is just a list of buffers that we will use for batched forwarding
	local bufs = memory.bufArray()
	while mg.running() do -- check if Ctrl+c was pressed
		-- receive one or more packets from the queue
		local count = rxQueue:recv(bufs)
		-- send out all received bufs on the other queue
		-- the bufs are free'd implicitly by this function
		-- txQueue:sendN(bufs, count)
		rateLimiter:send(bufs)
	end
end

