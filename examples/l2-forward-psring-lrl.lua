local mg      = require "moongen"
local memory  = require "memory"
local device  = require "device"
local ts      = require "timestamping"
local stats   = require "stats"
local log     = require "log"
local limiter = require "software-ratecontrol"
local pipe    = require "pipe"
local ffi     = require "ffi"
local libmoon = require "libmoon"
local histogram = require "histogram"
--local bit64   = require "bit64"

local PKT_SIZE	= 60

function configure(parser)
	parser:description("Forward traffic between interfaces with moongen rate control")
	parser:option("-d --dev", "Devices to use, specify the same device twice to echo packets."):args(2):convert(tonumber)
	parser:option("-r --rate", "Forwarding rates in Mbps (two values for two links)"):args(2):convert(tonumber)
	parser:option("-t --threads", "Number of threads per forwarding direction using RSS."):args(1):convert(tonumber):default(1)
	parser:option("-l --latency", "Fixed emulated latency (in ms) on the link."):args(2):convert(tonumber):default({0,0})
	parser:option("-q --queuedepth", "Maximum number of packets to hold in the delay line"):args(2):convert(tonumber):default({0,0})
	parser:option("-o --loss", "Rate of packet drops"):args(2):convert(tonumber):default({0,0})
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
			--rxDescs = 4096,
			dropEnable = true,
			disableOffloads = true
		}
	end
	device.waitForLinks()

	-- print stats
	stats.startStatsTask{devices = args.dev}
	
	-- create the ring buffers
	-- should set the size here, based on the line speed and latency, and maybe desired queue depth
	local qdepth1 = args.queuedepth[1]
	if qdepth1 < 1 then
		qdepth1 = math.ceil((args.latency[1] * args.rate[1] * 1000)/672)
		if (qdepth1 == 0) then
			qdepth1 = 1
		end
		print("automatically setting qdepth1="..qdepth1)
	end
	local qdepth2 = args.queuedepth[2]
	if qdepth2 < 1 then
		qdepth2 = math.ceil((args.latency[2] * args.rate[2] * 1000)/672)
		if (qdepth2 == 0) then
			qdepth2 = 1
		end
		print("automatically setting qdepth2="..qdepth2)
	end
	local ring1 = pipe:newPktsizedRing(qdepth1)
	local ring2 = pipe:newPktsizedRing(qdepth2)

	-- start the forwarding tasks
	for i = 1, args.threads do
		mg.startTask("forward", ring1, args.dev[1]:getTxQueue(i - 1), args.dev[1], args.rate[1], args.latency[1], args.loss[1])
		if args.dev[1] ~= args.dev[2] then
			mg.startTask("forward", ring2, args.dev[2]:getTxQueue(i - 1), args.dev[2], args.rate[2], args.latency[2], args.loss[2])
		end
	end

	-- start the receiving/latency tasks
	for i = 1, args.threads do
		mg.startTask("receive", ring1, args.dev[2]:getRxQueue(i - 1), args.dev[2])
		if args.dev[1] ~= args.dev[2] then
			mg.startTask("receive", ring2, args.dev[1]:getRxQueue(i - 1), args.dev[1])
		end
	end

	mg.waitForTasks()
end


function receive(ring, rxQueue, rxDev)
	--print("receive thread...")

	local bufs = memory.createBufArray()
	local count = 0
	local count_hist = histogram:new()
	local ringsize_hist = histogram:new()
	local ringbytes_hist = histogram:new()
	while mg.running() do
		count = rxQueue:recv(bufs)
		count_hist:update(count)
		--print("receive thread count="..count)
		for iix=1,count do
			local buf = bufs[iix]
			local ts = limiter:get_tsc_cycles()
			buf.udata64 = ts
			--print("RXRX arrival: ", bit64.tohex(buf.udata64))
		end
		if count > 0 then
			pipe:sendToPktsizedRing(ring.ring, bufs, count)
			--print("ring count: ",pipe:countPacketRing(ring.ring))
			ringsize_hist:update(pipe:countPktsizedRing(ring.ring))
		end
	end
	count_hist:print()
	count_hist:save("rxq-pkt-count-distribution-histogram-"..rxDev["id"]..".csv")
	ringsize_hist:print()
	ringsize_hist:save("rxq-ringsize-distribution-histogram-"..rxDev["id"]..".csv")
end

function forward(ring, txQueue, txDev, rate, latency, lossrate)
	print("forward with rate "..rate.." and latency "..latency.." and loss rate "..lossrate)
	local numThreads = 1
	
	local linkspeed = txDev:getLinkStatus().speed
	print("linkspeed = "..linkspeed)

	local tsc_hz = libmoon:getCyclesFrequency()
	local tsc_hz_ms = tsc_hz / 1000
	print("tsc_hz = "..tsc_hz)

	-- larger batch size is useful when sending it through a rate limiter
	local bufs = memory.createBufArray()  --memory:bufArray()  --(128)
	local count = 0

	while mg.running() do
		-- receive one or more packets from the queue
		count = pipe:recvFromPktsizedRing(ring.ring, bufs, 1)

		for iix=1,count do
			local buf = bufs[iix]
			
			-- get the buf's arrival timestamp and compute departure time
			local arrival_timestamp = buf.udata64
			--print("TXTX arrival: ", bit64.tohex(buf.udata64))
			local send_time = arrival_timestamp + (latency * tsc_hz_ms)
			--print("TXTX send time: ", bit64.tohex(send_time))
                        --print("TXTX tsc_cycles: ", bit64.tohex(limiter:get_tsc_cycles()))

			-- spin/wait until it is time to send this frame
			-- this does not allow reordering of frames
			while limiter:get_tsc_cycles() < send_time do
				if not mg.running() then
					return
				end
			end
			
			local pktSize = buf.pkt_len + 24
			--print("TXTX set delay: ", (pktSize) * (linkspeed/rate - 1))
			buf:setDelay((pktSize) * (linkspeed/rate - 1))
		end

		if count > 0 then
			-- the rate here doesn't affect the result afaict.  It's just to help decide the size of the bad pkts
			txQueue:sendWithDelayLoss(bufs, rate * numThreads, lossrate, count)
		end
	end
end

