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

local namespaces = require "namespaces"

local PKT_SIZE	= 60

-- 
-- Network A --> MG --> C
--
-- Uplink example:
-- sudo ./build/MoonGen examples/l2-forward-psring-hybrid-latency-rate-lte-catchup-rateramp.lua -d <A> <C> -r 38 40 -l 10 30 -q 1000 350 -u 1000 1000 -c 0.005 0.005 -o 0.001 0.001
--
-- Downlink example:
-- sudo ./build/MoonGen examples/l2-forward-psring-hybrid-latency-rate-lte-catchup-rateramp.lua -d <C> <A> -r 38 40 -l 10 30 -q 1000 350 -u 1000 1000 -c 0.005 0.005 -o 0.001 0.001
--

function configure(parser)
	parser:description("Forward traffic between interfaces with moongen rate control")
	parser:description("device args:    dev1=eNodeB     dev2=UE Handset")
	parser:option("-d --dev", "Devices to use, specify the same device twice to echo packets."):args(2):convert(tonumber)
	parser:option("-r --rate", "Forwarding rates in Mbps (two values for two links)"):args(2):convert(tonumber)
	parser:option("-t --threads", "Number of threads per forwarding direction using RSS."):args(1):convert(tonumber):default(1)
	parser:option("-l --latency", "Fixed emulated latency (in ms) on the link."):args(2):convert(tonumber):default({0,0})
	parser:option("-x --xlatency", "Extra exponentially distributed latency, in addition to the fixed latency (in ms)."):args(2):convert(tonumber):default({0,0})
	parser:option("-q --queuedepth", "Maximum number of packets to hold in the delay line"):args(2):convert(tonumber):default({0,0})
	parser:option("-o --loss", "Rate of packet drops"):args(2):convert(tonumber):default({0,0})
	parser:option("-c --concealedloss", "Rate of concealed packet drops"):args(2):convert(tonumber):default({0,0})
	parser:option("-u --catchuprate", "After a concealed loss, this rate will apply to the backed-up frames."):args(2):convert(tonumber):default({0,0})
	parser:option("--short_DRX_cycle_length", "The short DRX cycle length in ms"):args(1):convert(tonumber):default(6)
	parser:option("--long_DRX_cycle_length", "The long DRX cycle length in ms"):args(1):convert(tonumber):default(12)
	parser:option("--active_time", "The active time from PDCCH in ms"):args(1):convert(tonumber):default(1)
	parser:option("--continuous_reception_inactivity_timer", "The continous reception inactivity timer in ms"):args(1):convert(tonumber):default(200)
	parser:option("--short_DRX_inactivity_timer", "The short DRX inactivity timer in ms"):args(1):convert(tonumber):default(2298)
	parser:option("--long_DRX_inactivity_timer", "The long DRX inactivity timer in ms"):args(1):convert(tonumber):default(7848)
	parser:option("--rcc_idle_cycle_length", "The RCC IDLE cycle length in ms"):args(1):convert(tonumber):default(50)
	parser:option("--rcc_connection_build_delay", "The Delay from RCC_IDLE to RCC_CONNECT in ms"):args(1):convert(tonumber):default(70)
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
			txDescs = 32,
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
		qdepth1 = math.floor((args.latency[1] * args.rate[1] * 1000)/672)
	end
	local qdepth2 = args.queuedepth[2]
	if qdepth2 < 1 then
		qdepth2 = math.floor((args.latency[2] * args.rate[2] * 1000)/672)
	end
	local ring1 = pipe:newPktsizedRing(qdepth1)
	local ring2 = pipe:newPktsizedRing(qdepth2)

	local lte_ns = namespaces:get("lte")

	-- start the forwarding tasks
	for i = 1, args.threads do
		-- uplink does not have to wait for a RCC_IDLE cycle, so the rcc_idle_cycle_length is effectively zero
		mg.startTask("forward", 1, ring1, args.dev[1]:getTxQueue(i - 1), args.dev[1],
				args.rate[1], 
			 	args.latency[1],
				args.xlatency[1],
				args.loss[1],
				args.concealedloss[1],
				args.catchuprate[1],
				args.short_DRX_cycle_length,
				args.long_DRX_cycle_length,
				args.active_time,
				args.continuous_reception_inactivity_timer,
				args.short_DRX_inactivity_timer,
				args.long_DRX_inactivity_timer,
				args.rcc_idle_cycle_length,
				args.rcc_connection_build_delay)
		if args.dev[1] ~= args.dev[2] then
			mg.startTask("forward", 2, ring2, args.dev[2]:getTxQueue(i - 1), args.dev[2],
					args.rate[2],
					args.latency[2],
					args.xlatency[2],
					args.loss[2],
					args.concealedloss[2],
					args.catchuprate[2],
					args.short_DRX_cycle_length,
					args.long_DRX_cycle_length,
					args.active_time,
					args.continuous_reception_inactivity_timer,
					args.short_DRX_inactivity_timer,
					args.long_DRX_inactivity_timer,
					0,
					args.rcc_connection_build_delay)
		end
	end

	-- start the receiving/latency tasks
	for i = 1, args.threads do
		mg.startTask("receive", 1, ring1, args.dev[2]:getRxQueue(i - 1), args.dev[2])
		if args.dev[1] ~= args.dev[2] then
			mg.startTask("receive", 2, ring2, args.dev[1]:getRxQueue(i - 1), args.dev[1])
		end
	end

	mg.waitForTasks()
end


function receive(threadNumber, ring, rxQueue, rxDev)
	--print("receive thread...")

	local tsc_hz = libmoon:getCyclesFrequency()
	local tsc_hz_ms = tsc_hz / 1000
	local tsc_hz_ns = tsc_hz / 1000000

	local bufs = memory.createBufArray()
	local count = 0
	--local count_hist = histogram:new()
	while mg.running() do
		count = rxQueue:recv(bufs)

		--count_hist:update(count)
		for iix=1,count do
			local buf = bufs[iix]
			local ts = limiter:get_tsc_cycles()
			buf.udata64 = ts
		end

		if count > 0 then
			pipe:sendToPktsizedRing(ring.ring, bufs, count)
		end
	end
	--count_hist:print()
	--count_hist:save("rxq-pkt-count-distribution-histogram-"..rxDev["id"]..".csv")
end

function forward(threadNumber, ring, txQueue, txDev,
			rate,
			latency,
			xlatency,
			lossrate,
			clossrate,
			catchuprate,
			short_DRX_cycle_length,
			long_DRX_cycle_length,
			active_time,
			continuous_reception_inactivity_timer,
			short_DRX_inactivity_timer,
			long_DRX_inactivity_timer,
			rcc_idle_cycle_length,
			rcc_connection_build_delay)

	print("forward with rate "..rate.." and latency "..latency.." and loss rate "..lossrate.." and clossrate "..clossrate.." and catchuprate "..catchuprate)
	local numThreads = 1

	local lte_ns = namespaces:get("lte")

	math.randomseed( os.time() )

	local linkspeed = txDev:getLinkStatus().speed
	print("linkspeed = "..linkspeed)

	local tsc_hz = libmoon:getCyclesFrequency()
	local tsc_hz_ms = tsc_hz / 1000
	print("tsc_hz = "..tsc_hz)

	print("Thread: "..threadNumber)

	local debug = false

	-- DRX in LTE is in RRC_IDLE or in RRC_CONNECTED mode
	-- RRC_IDLE: sleep state
	-- RRC_CONNECTED:
	lte_ns.rcc_idle = true

	-- after connection establishment the rate ramps up to the emulated rate over some time
	lte_ns.rate_ramp_mode = false
	local rate_ramp_mode_last = false  -- for the other thread(s) to detect when we enter rate_ramp_mode
	local rate_ramp_length_ms = 500
	local rate_ramp_length_tsc_hz = rate_ramp_length_ms * tsc_hz_ms
	local rate_ramp_start = 0
	local rate_ramp_end = 0
	local rate_ramp_min = 5

	-- the RRC_CONNECTED mode got the short DRX cycle and long DRX cycle
	lte_ns.short_DRX = false
	lte_ns.long_DRX = false
	lte_ns.continuous_reception = false

	local last_activity = limiter:get_tsc_cycles()
	lte_ns.last_packet_time = ullToNumber(last_activity)
	lte_ns.last_packet_time_thread1 = lte_ns.last_packet_time
	lte_ns.last_packet_time_thread2 = lte_ns.last_packet_time

	lte_ns.first_rcc_connected = false

	local bufs = memory.createBufArray()
	local count = 0

	-- when there is a concealed loss, the backed-up packets can catch up at line rate
	local catchup_mode = false

	-- between 0.32 and 2.56 sec
	local rcc_idle_cycle_length_tsc_hz_ms = rcc_idle_cycle_length * tsc_hz_ms

	local short_DRX_cycle_length_tsc_hz_ms = short_DRX_cycle_length * tsc_hz_ms
	local long_DRX_cycle_length_tsc_hz_ms = long_DRX_cycle_length * tsc_hz_ms

	local active_time_tsc_hz_ms = active_time * tsc_hz_ms

	-- will be reset after each send/received packet
	-- timer is between 1ms - 2.56sec Paper-[10]
	local inactive_continuous_reception_cycle_time = continuous_reception_inactivity_timer * tsc_hz_ms

	local inactive_short_DRX_cycle_time = (short_DRX_inactivity_timer + continuous_reception_inactivity_timer) * tsc_hz_ms

	local inactive_long_DRX_cycle_time = (long_DRX_inactivity_timer + short_DRX_inactivity_timer + continuous_reception_inactivity_timer)* tsc_hz_ms

	-- 16 to 19 signalling messages
	local rcc_connection_build_delay_tsc_hz_ms = rcc_connection_build_delay * tsc_hz_ms

	-- in ms
	local concealed_resend_time = 8
	local num_catchup_packets = 0

	-- send time of the most recent concealed loss
	local cl_send_time = 0

	-- when catching up after a concealed loss, we need to keep track of when a packet
	-- /would/ have been sent during the correction delay interval
	local last_send_time = 0
	local last_tx_time_tsc = 0

	-- time between when a concealed loss would have been sent, and when it is actually sent
	local clI = 0

	local time_stuck_in_loop = 0

	while mg.running() do
		-- RCC_IDLE to RCC_CONNECTED the delay
		if lte_ns.first_rcc_connected then
			if debug then print("Build RCC_CONNECTION "..threadNumber) end
			last_activity = limiter:get_tsc_cycles()
			while limiter:get_tsc_cycles() < last_activity + rcc_connection_build_delay_tsc_hz_ms do
				if not mg.running() then
					return
				end
				-- if the other thread finished the LOOP
				if not lte_ns.first_rcc_connected then
					break
				end
			end
			lte_ns.rate_ramp_mode = true
			rate_ramp_mode_last = true
			rate_ramp_start = limiter:get_tsc_cycles()
			rate_ramp_end = rate_ramp_start + rate_ramp_length_tsc_hz
			lte_ns.first_rcc_connected = false
			if time_stuck_in_loop > 0 then
				time_stuck_in_loop = time_stuck_in_loop + rcc_connection_build_delay_tsc_hz_ms
			end
			last_activity = limiter:get_tsc_cycles()
		end

		-- detect if another thread put us into rate_ramp_mode
		if (lte_ns.rate_ramp_mode and not rate_ramp_mode_last) then
			rate_ramp_start = limiter:get_tsc_cycles()
			rate_ramp_end = rate_ramp_start + rate_ramp_length_tsc_hz
		end
		rate_ramp_mode_last = lte_ns.rate_ramp_mode

		-- if the continuous_reception mode is active
		if lte_ns.continuous_reception then
			count = pipe:recvFromPktsizedRing(ring.ring, bufs, 1)

			for iix=1,count do
				local buf = bufs[iix]

				-- get the buf's arrival timestamp and compare to current time
				--local arrival_timestamp = buf:getTimestamp()
				local arrival_timestamp = buf.udata64
				local extraDelay = 0.0
				if (xlatency > 0) then
					extraDelay = -math.log(math.random())*xlatency
				end

				-- emulate concealed losses
				-- for now, only allow one concealed loss at a time
				local closses = 0.0
				if (not catchup_mode) then
				while (math.random() < clossrate) do
					closses = closses + 1
					if (catchuprate > 0) then
						catchup_mode = true
					end
				end
				end

				local send_time = arrival_timestamp
				send_time = send_time + ((closses*concealed_resend_time + latency + extraDelay) * tsc_hz_ms + time_stuck_in_loop)

				-- spin/wait until it is time to send this frame
				-- this assumes frame order is preserved
				while limiter:get_tsc_cycles() < send_time do
					if not mg.running() then
						return
					end
				end
				
				local current_rate = rate
				if lte_ns.rate_ramp_mode then
					local tsc_now = limiter:get_tsc_cycles()
					if (tsc_now > rate_ramp_end) then
						lte_ns.rate_ramp_mode = false
						rate_ramp_start = 0
						rate_ramp_end = 0
					else
						local rate_range = rate - rate_ramp_min
						local ramp_fraction = (tsc_now - rate_ramp_start) / rate_ramp_length_tsc_hz
						current_rate = rate_ramp_min + rate_range * (tsc_now - rate_ramp_start) / rate_ramp_length_tsc_hz
					end
				end

				if(closses > 0) then
					-- compute how much time other packets have left to transmit while
					-- the concealed loss is getting detected/corrected
					cl_send_time = send_time
					local pktSize = buf.pkt_len + 24
					local time_to_tx_ms = ((pktSize*8) / (current_rate*1000))
					clI = (closses*concealed_resend_time - time_to_tx_ms) * tsc_hz_ms
				end

				-- if we're in catchup_mode, check if the current packet fits inside the clI window or not
				-- for now, just check if its normal send_time comes before the delayed send time of the concelaed lost packet
				if (closses == 0 and catchup_mode) then
					local pktSize = buf.pkt_len + 24
					local time_to_tx_tsc = ((pktSize*8) / (current_rate*1000)) * tsc_hz_ms

					if (send_time < (last_send_time + last_tx_time_tsc)) then
						send_time = last_send_time + last_tx_time_tsc
					end

					if (send_time > cl_send_time) then
						-- we exit catchup_mode
						num_catchup_packets = 0
						catchup_mode = false
						last_send_time = 0
						last_tx_time_tsc = 0
					elseif (time_to_tx_tsc > (cl_send_time-send_time)) then
						num_catchup_packets = 0
						catchup_mode = false
						last_send_time = 0
						last_tx_time_tsc = 0
					else
						clI = cl_send_time - send_time - time_to_tx_tsc
						last_send_time = send_time
						last_tx_time_tsc = time_to_tx_tsc
					end
				end
				

				time_stuck_in_loop = 0


				local pktSize = buf.pkt_len + 24
				if (catchup_mode) then
					buf:setDelay((pktSize) * (linkspeed/catchuprate - 1))
					num_catchup_packets = num_catchup_packets + 1
				else
					buf:setDelay((pktSize) * (linkspeed/current_rate - 1))
				end
			end

			if count > 0 then

				-- the rate here doesn't affect the result afaict.  It's just to help decide the size of the bad pkts
				txQueue:sendWithDelayLoss(bufs, rate * numThreads, lossrate, count)

				last_activity = limiter:get_tsc_cycles()
				--lte_ns.last_packet_time = ullToNumber(limiter:get_tsc_cycles())
				local tmptime = ullToNumber(limiter:get_tsc_cycles())
				if (threadnumber == 1) then
					lte_ns.last_packet_time_thread1 = tmptime
				else
					lte_ns.last_packet_time_thread2 = tmptime
				end
				--lte_ns.last_packet_time = tmptime
			end

			if limiter:get_tsc_cycles() > last_activity + inactive_continuous_reception_cycle_time then
				local loc_last_packet_time = math.max(lte_ns.last_packet_time_thread1,lte_ns.last_packet_time_thread2)
				if limiter:get_tsc_cycles() > loc_last_packet_time + inactive_continuous_reception_cycle_time then

					if debug then print("continuous_reception deactivating "..threadNumber) end
					lte_ns.continuous_reception = false

					if debug then  print("short_DRX activating "..threadNumber) end
					lte_ns.short_DRX = true
				end
			end
		end

		-- RCC_CONNECTED short_DRX
		if lte_ns.short_DRX then

			last_activity = limiter:get_tsc_cycles()

			local packet_arrival_time = 0
			local lcount = 0
			time_stuck_in_loop = 0

			-- time to wait
			while lte_ns.short_DRX and limiter:get_tsc_cycles() < last_activity + short_DRX_cycle_length_tsc_hz_ms - active_time_tsc_hz_ms do
				lcount = pipe:countPktsizedRing(ring.ring)
				if (lcount > 0) and (packet_arrival_time == 0) then
					packet_arrival_time = limiter:get_tsc_cycles()
				end
				if not mg.running() then
					return
				end
			end

			-- save the time the packet waited
			last_activity = limiter:get_tsc_cycles()
			if (lcount > 0) then
				time_stuck_in_loop = (last_activity-packet_arrival_time)
			end

			-- T_on is active
			while lte_ns.short_DRX and limiter:get_tsc_cycles() < last_activity + active_time_tsc_hz_ms do
				if not mg.running() then
					return
				end
				-- count = pipe:recvFromPktsizedRing(ring.ring, bufs, 1)
				count = pipe:countPktsizedRing(ring.ring)

				if count > 0 then
					if debug then  print("short_DRX deactivating "..threadNumber) end
					lte_ns.short_DRX = false

					if debug then  print("continuous_reception activating "..threadNumber) end
					lte_ns.continuous_reception = true

					last_activity = limiter:get_tsc_cycles()
					--lte_ns.last_packet_time = ullToNumber(limiter:get_tsc_cycles())
					local tmptime = ullToNumber(limiter:get_tsc_cycles())
					if (threadnumber == 1) then
						lte_ns.last_packet_time_thread1 = tmptime
					else
						lte_ns.last_packet_time_thread2 = tmptime
					end
					--lte_ns.last_packet_time = tmptime
					break
				end
			end

			-- if the the max of interactive Time from short DRX arrived, it will be changed to long DRX
			local loc_last_packet_time = math.max(lte_ns.last_packet_time_thread1,lte_ns.last_packet_time_thread2)
			if limiter:get_tsc_cycles() > loc_last_packet_time + inactive_short_DRX_cycle_time then
				if debug then  print("short_DRX deactivating after inactive time, "..threadNumber) end
				lte_ns.short_DRX = false

				if debug then  print("long_DRX activating after inactive time, "..threadNumber) end
				lte_ns.long_DRX = true
			end
		end

		-- RCC_CONNECTED long_DRX
		if lte_ns.long_DRX then
			last_activity = limiter:get_tsc_cycles()

			local packet_arrival_time = 0
			local lcount = 0
			time_stuck_in_loop = 0

			-- time to wait
			while lte_ns.long_DRX and limiter:get_tsc_cycles() < last_activity + long_DRX_cycle_length_tsc_hz_ms - active_time_tsc_hz_ms do
				lcount = pipe:countPktsizedRing(ring.ring)
				if (lcount > 0) and (packet_arrival_time == 0) then
					packet_arrival_time = limiter:get_tsc_cycles()
				end
				if not mg.running() then
					return
				end
			end

			-- save the time the packet waited
			last_activity = limiter:get_tsc_cycles()
			if (lcount > 0) then
				time_stuck_in_loop = (last_activity-packet_arrival_time)
			end

			-- T_on is active
			while lte_ns.long_DRX and limiter:get_tsc_cycles() < last_activity + active_time_tsc_hz_ms do
				if not mg.running() then
					return
				end

				count = pipe:countPktsizedRing(ring.ring)

				if count > 0 then
					if debug then  print("long_DRX deactivating "..threadNumber) end
					lte_ns.long_DRX = false

					if debug then  print("continuous_reception activating "..threadNumber) end
					lte_ns.continuous_reception = true

					last_activity = limiter:get_tsc_cycles()
					--lte_ns.last_packet_time = ullToNumber(limiter:get_tsc_cycles())
					local tmptime = ullToNumber(limiter:get_tsc_cycles())
					if (threadnumber == 1) then
						lte_ns.last_packet_time_thread1 = tmptime
					else
						lte_ns.last_packet_time_thread2 = tmptime
					end

					--lte_ns.last_packet_time = tmptime

					break
				end
			end

			-- if the the max of interactive Time from long DRX arrived, return to RCC_IDLE
			local loc_last_packet_time = math.max(lte_ns.last_packet_time_thread1,lte_ns.last_packet_time_thread2)
			if limiter:get_tsc_cycles() > loc_last_packet_time + inactive_long_DRX_cycle_time then

				if debug then print("long_DRX deactivating after inactive time, "..threadNumber) end
				lte_ns.long_DRX = false

				if debug then  print("rcc_idle activating after inactive time, "..threadNumber) end
				lte_ns.rcc_idle = true
			end
		end

		-- if the RCC_IDLE mode is active
		if lte_ns.rcc_idle then
			last_activity = limiter:get_tsc_cycles()

			local packet_arrival_time = 0
			local lcount = 0
			time_stuck_in_loop = 0

			-- time to wait
			if (rcc_idle_cycle_length_tsc_hz_ms > 0) then
				while limiter:get_tsc_cycles() < last_activity + rcc_idle_cycle_length_tsc_hz_ms - active_time_tsc_hz_ms do
					lcount = pipe:countPktsizedRing(ring.ring)
					if (lcount > 0) and (packet_arrival_time == 0) then
						packet_arrival_time = limiter:get_tsc_cycles()
					end
					if not mg.running() then
						return
					end
				end
			end

			-- save the time the packet waited
			last_activity = limiter:get_tsc_cycles()
			if (lcount > 0) then
				time_stuck_in_loop = (last_activity - packet_arrival_time)
			end

			-- T_on is active
			while limiter:get_tsc_cycles() < last_activity + active_time_tsc_hz_ms do
				if not mg.running() then
					return
				end

				-- this does not actually count the contents,
				-- it computes the difference between head and tail
				count = pipe:countPktsizedRing(ring.ring)

				if count > 0 then

					if debug then print("rcc_idle deactivating "..threadNumber) end
					lte_ns.rcc_idle = false

					if debug then print("continuous_reception activating "..threadNumber) end
					lte_ns.continuous_reception = true

					lte_ns.first_rcc_connected = true

					local tmptime = ullToNumber(limiter:get_tsc_cycles())
					if (threadnumber == 1) then
						lte_ns.last_packet_time_thread1 = tmptime
					else
						lte_ns.last_packet_time_thread2 = tmptime
					end
					--lte_ns.last_packet_time = tmptime

					break
				end
			end
		end
	end
end

-- Help function:
-- cast a uint64_i to "lua number"
function ullToNumber(value)

	local vstring = tostring(value)
	-- remove the "ULL" ending
	vstring = string.sub(vstring, 0, string.len(vstring) - 3)

	return tonumber(vstring)
end


