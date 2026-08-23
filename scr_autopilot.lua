--[[ ======================================================================
     ANTI-IDLE  —  self-contained add-on, sits above the original script.

     Roblox disconnects a client that has sent no real input for ~20 minutes.
     The autopilot's keystrokes go through VirtualInputManager, which is
     synthetic and does not reliably reset that timer, so a long run gets
     dropped mid-route.

     This block does not touch the autopilot. Everything in it is scoped
     inside `do ... end`, so it declares no globals except `_G.AntiAFK`, and
     it never sends W, S, T or Q — the only input it produces is a
     right-click through VirtualUser, which pans the camera and nothing else.
     Deleting these lines returns you to the stock script exactly.

     It is placed above the autopilot on purpose: it arms itself before the
     main script runs, so it stays alive even if something below errors out.

       _G.AntiAFK.nudge()   -- fire one by hand to test it
       _G.AntiAFK.status()  -- nudges sent, seconds since the last one
====================================================================== ]]
do
	local ENABLED  = true   -- set false to disable without deleting anything
	local INTERVAL = 600    -- backup nudge every N seconds, if Idled never fires
	local VERBOSE  = true   -- print each nudge to the console

	local localPlayer = game:GetService("Players").LocalPlayer

	local VirtualUser
	do
		local ok, service = pcall(game.GetService, game, "VirtualUser")
		VirtualUser = ok and service or nil
	end

	local nudges    = 0
	local lastNudge = os.clock()

	local function nudge(source)
		lastNudge = os.clock()
		if not VirtualUser then return false end
		local ok, err = pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
		nudges = nudges + 1
		if VERBOSE then
			print(("[anti-idle] nudge #%d (%s) %s"):format(
				nudges, source or "manual", ok and "sent" or ("FAILED: " .. tostring(err))))
		end
		return ok
	end

	_G.AntiAFK = {
		nudge  = function() return nudge("manual") end,
		status = function()
			return ("[anti-idle] %s | %d nudges | %.0fs since last"):format(
				(ENABLED and VirtualUser) and "armed" or "inactive",
				nudges, os.clock() - lastNudge)
		end,
	}

	if not ENABLED then
		print("[anti-idle] disabled by config.")
	elseif not VirtualUser then
		warn("[anti-idle] VirtualUser is not available to this executor — " ..
		     "anti-idle is NOT active and you will still time out.")
	else
		-- Layer 1: Roblox tells us directly. Idled fires at the 20 minute
		-- mark, roughly a minute before the disconnect.
		localPlayer.Idled:Connect(function()
			nudge("Idled")
		end)

		-- Layer 2: backup, for executors where Idled never arrives.
		task.spawn(function()
			while true do
				task.wait(30)
				if os.clock() - lastNudge >= INTERVAL then
					nudge("timer")
				end
			end
		end)

		print(("[anti-idle] armed — Idled hook + %ds backup timer"):format(INTERVAL))
	end
end
-- ====================== END ANTI-IDLE — original script follows ==========


--[[ ======================================================================
     RUNAWAY-CREEP GUARD  —  self-contained add-on, above the original.

     THE BUG THIS FIXES
     ------------------
     The original ends a terminating leg by creeping to the buffer stop:

         while getD(buf[st][plat]) >= BUFFERSTOP do
             print(getD(buf[st][plat]))
             cs:Fire(15)
             task.wait(0.1)
         end

     getD measures the camera's distance to a fixed buffer position, and the
     loop only exits by getting CLOSER to it. Click Next Leg and you are put
     in the cab at the other end, now driving AWAY from that buffer — so the
     distance only grows and the loop never ends. It keeps commanding 15 mph
     ten times a second, forever. That is the 15 mph ceiling.

     The twitching is the same loop hitting a second bug in target():

         while speed_angle(speed) > arm.Rotation or tt do task.wait(0.005) end

     `or tt` should be `and not tt`. As written, every new cs:Fire sets tt on
     all the older target() calls, and instead of stopping them it makes their
     loops run forever — so they never reach input.stop() and never release
     the key they are holding. Ten new threads a second, each grabbing W or S
     and never letting go, is the twitch.

     THE FIX
     -------
     Both getD and target are globals in the original, so this block wraps
     them from outside instead of editing a single line of it:

       * getD returns 0 — ending the loop cleanly — if the creep has run past
         a timeout, if the buffer is getting FARTHER away, or if a leg change
         just happened. Otherwise it passes the real distance straight through
         and normal buffer creeping works exactly as before.
       * target ignores a repeat of the speed it was just given, so a stuck
         loop can no longer spawn hundreds of fighting threads.

     Because it wraps globals, this must run in the SAME file as the original.
     It waits for the original to define them, then installs.

       _G.SCRFix.status()   -- what the guards have done so far
====================================================================== ]]
do
	local CREEP_TIMEOUT  = 15    -- s of creeping without arriving = give up
	local CREEP_BACKOFF  = 60    -- studs of moving AWAY from the buffer = give up
	local LEG_SUPPRESS   = 25    -- s after a leg change where creeping is refused
	local DEDUPE         = true  -- drop repeats of the same target speed
	local DEDUPE_WINDOW  = 1.0
	local VERBOSE        = true

	local VIM = game:GetService("VirtualInputManager")

	local lastLegChange = -math.huge
	local burstStart, lastCall, minSeen = 0, 0, math.huge
	local aborts, dupes, installed = 0, 0, false

	local function log(fmt, ...)
		if not VERBOSE then return end
		print("[fix] " .. (select("#", ...) > 0 and fmt:format(...) or fmt))
	end

	local function install()
		----------------------------------------------------------------
		-- getD guard
		----------------------------------------------------------------
		local realGetD = getD
		getD = function(v)
			local now  = os.clock()
			local dist = realGetD(v)

			-- The creep loop calls this ~10x/sec. A gap means a new creep.
			if now - lastCall > 1 then
				burstStart, minSeen = now, math.huge
			end
			lastCall = now

			if now - lastLegChange < LEG_SUPPRESS then
				aborts = aborts + 1
				log("creep refused — leg changed %.0fs ago, that buffer is behind us",
					now - lastLegChange)
				return 0
			end

			if dist < minSeen then minSeen = dist end

			if dist > minSeen + CREEP_BACKOFF then
				aborts = aborts + 1
				log("creep aborted — buffer going away (closest %.0f, now %.0f studs)",
					minSeen, dist)
				return 0
			end

			if now - burstStart > CREEP_TIMEOUT then
				aborts = aborts + 1
				log("creep timed out — %.0fs without reaching the buffer", now - burstStart)
				return 0
			end

			return dist
		end

		----------------------------------------------------------------
		-- target guard
		----------------------------------------------------------------
		-- Purely a duplicate filter, on a short time window. It never blocks
		-- a NEW speed, so it cannot wedge the autopilot even if an old
		-- target() thread is stuck.
		local realTarget = target
		local lastSpeed, lastTime = nil, 0
		target = function(speed)
			local now = os.clock()
			if DEDUPE and speed == lastSpeed and (now - lastTime) < DEDUPE_WINDOW then
				dupes = dupes + 1
				return
			end
			lastSpeed, lastTime = speed, now
			return realTarget(speed)
		end

		_G.SCRFix = {
			-- Called by the next-leg block the moment a leg change lands.
			legChanged = function()
				lastLegChange = os.clock()
				lastSpeed = nil          -- next command always gets through
				minSeen   = math.huge
				log("leg change registered — creeping suppressed for %ds", LEG_SUPPRESS)
			end,

			-- Lets the next target() through even if it repeats the last
			-- speed. Used after a defib, where re-asserting the same speed
			-- is the whole point.
			resetDedupe = function() lastSpeed = nil end,

			-- When getD was last called, i.e. when a buffer creep last ran.
			-- The stop-hold uses this to stay out of the way at termini.
			lastCreep = function() return lastCall end,

			-- When the last leg change landed. The buffer approach reads this
			-- so it never drives at a buffer that Next Leg just put behind us.
			lastLegChange = function() return lastLegChange end,

			-- Clears any key left latched by a stranded target() thread.
			releaseKeys = function()
				pcall(function()
					VIM:SendKeyEvent(false, Enum.KeyCode.W, false, nil)
					VIM:SendKeyEvent(false, Enum.KeyCode.S, false, nil)
				end)
				log("released W and S")
			end,

			status = function()
				return ("[fix] guards %s | %d creep abort(s) | %d duplicate target(s) dropped")
					:format(installed and "installed" or "NOT installed", aborts, dupes)
			end,
		}

		installed = true
		log("guards installed on getD and target")
	end

	-- The original defines getD and target further down this file; wait for them.
	task.spawn(function()
		local t0 = os.clock()
		repeat
			task.wait(0.1)
		until (type(getD) == "function" and type(target) == "function")
			or (os.clock() - t0 > 30)

		if type(getD) == "function" and type(target) == "function" then
			install()
		else
			warn("[fix] getD/target never appeared — the guards are NOT active. " ..
			     "This block has to run in the same file as the autopilot.")
		end
	end)
end
-- ================== END RUNAWAY-CREEP GUARD =============================


--[[ ======================================================================
     DYNAMIC BRAKING POINT  —  self-contained add-on, above the original.

     THE BUG THIS FIXES
     ------------------
     The original comes off line speed at a FIXED distance:

         local SAFESTOPDISTANCE = 0.32          -- miles
         ...
         elseif num <= SAFESTOPDISTANCE then
                 cs:Fire(math.min(SAFESTOPSPEED, getSpeedLimit()))

     0.32 mi is 515 metres, and it does not care how fast you are going.
     Above that line b() commands min(MAXSPEED, limit) — on a 125 line that
     is 100 mph. The distance actually needed to get from 100 mph down to 25
     is about 940 m at a realistic service brake rate. So on a fast line the
     train physically cannot make 25 by the platform: it arrives at 50-70
     and runs straight through. On a 60 line the same sum is 296 m, well
     inside 0.32, which is why slower stations have always looked fine.

     Not "some stations". Fast lines.

     HOW IT FIXES IT
     ---------------
     It does not fight b() and it does not replace it. It puts a CEILING on
     what b() is allowed to ask for, taken off a braking curve:

         v_allowed = sqrt(TARGET^2 + A * remaining_miles)

     so the ceiling falls smoothly as the platform gets nearer and reaches
     TARGET (the original's own approach speed) exactly at the stop. Further
     out the ceiling is above line speed and nothing changes. On a 125 line
     it starts pulling the speed down about 0.65 mi out instead of 0.32.

     It can only ever LOWER a commanded speed. There is no path through this
     block that makes the train go faster than the original asked for.

     UNITS, AND WHY THERE ARE NO STUDS IN HERE
     -----------------------------------------
     Speed is measured from the next-stop counter itself — miles per tick
     into miles per hour. That is the closing speed on the platform, which
     is exactly the quantity the curve needs, and it sidesteps having to
     know how many studs SCR thinks a mile is.

     THE BRAKE RATE
     --------------
     Starts at a deliberately weak guess and measures the real one while the
     train brakes. Braking early costs seconds; braking late costs the run,
     so the planning rate is derated — EXCEPT when you are more than a
     minute down, where it plans against the measured rate as it is and
     gives the time back. Lateness is read off the schedule panel.

       _G.SCRBrake.status()     -- curve, measured brake rate, lateness
       _G.SCRBrake.set{...}     -- target = 25, rate = 2.0, early = 0.75
       _G.SCRBrake.disable()    -- and .enable(); off = the original's 0.32 mi
====================================================================== ]]
do
	----------------------------------------------------------------------
	local ENABLED       = true

	-- Must match the original's SAFESTOPSPEED: the speed the curve aims to
	-- be down to when the counter reaches the stop. 30 at 0.2 miles out is
	-- the station approach we want; this block is what makes it actually
	-- happen on a 125 line, where 0.2 miles is nowhere near enough room.
	local TARGET_SPEED  = 30

	-- Service brake rate in mph per second. 2.0 mph/s is about 0.9 m/s²,
	-- deliberately on the weak side as a starting guess.
	local RATE          = 2.0
	local RATE_MIN      = 0.8
	local RATE_MAX      = 4.0

	-- How much of the measured rate to plan against.
	local EARLY_FACTOR  = 0.75   -- normally: brake sooner than strictly needed
	local LATE_FACTOR   = 1.00   -- when down on time: brake to the numbers
	local LATE_AFTER    = 60     -- seconds behind before the tighter plan

	local MIN_CAP       = TARGET_SPEED   -- never cap below the original's own
	                                     -- approach speed; the last bit of the
	                                     -- stop belongs to b()
	local MAX_LOOK      = 3.0    -- miles — beyond this there is nothing to do
	local TICK          = 0.4    -- s between re-assertions of the ceiling
	local NOTCH_SLACK   = 2.0    -- mph the notch may sit above the ceiling
	                             -- before we push it down ourselves

	local VERBOSE       = true
	----------------------------------------------------------------------

	local Players = game:GetService("Players")
	local player  = Players.LocalPlayer

	local DIST_PATH  = { "Additional", "DetailsStack", "AdvanceContainer", "Main",
	                     "ScheduleDetails", "Counters", "Distance" }
	local SCHED_PATH = { "Additional", "DetailsStack", "AdvanceContainer",
	                     "Main", "ScheduleDetails" }
	local NOTCH_PATH = { "Cluster", "Spedometer", "TargetIndicator" }

	local realTarget = nil
	local installed  = false

	local mph        = 0         -- measured closing speed on the stop
	local lastMi, lastAt = nil, nil
	local lastCap    = nil
	local capped     = 0         -- how many commands we have pulled down
	local rateSeen   = nil       -- measured brake rate, mph/s
	local lastLine   = "nothing yet"

	local function log(fmt, ...)
		if not VERBOSE then return end
		print("[brake] " .. (select("#", ...) > 0 and fmt:format(...) or fmt))
	end

	----------------------------------------------------------------------
	-- HUD
	----------------------------------------------------------------------
	local function driveGui()
		local pg = player:FindFirstChild("PlayerGui")
		return pg and pg:FindFirstChild("DriveGui") or nil
	end

	local function descend(root, path)
		local node = root
		for _, name in ipairs(path) do
			if not node then return nil end
			node = node:FindFirstChild(name)
		end
		return node
	end

	local function stopMiles()
		local gui = driveGui()
		local n = gui and descend(gui, DIST_PATH)
		if not n then return nil end
		local ok, txt = pcall(function() return n.Text end)
		if not ok then return nil end
		return tonumber(tostring(txt):match("%d+%.?%d*"))
	end

	local function notchMph()
		local gui = driveGui()
		local a = gui and descend(gui, NOTCH_PATH)
		if not a then return nil end
		local ok, rot = pcall(function() return a.Rotation end)
		if not ok or type(rot) ~= "number" then return nil end
		return (rot + 31) / 1.2
	end

	-- Seconds behind schedule. The panel shows (+01:22) for late and
	-- (-00:54) for early, so a positive answer here means late.
	local function lateness()
		local gui = driveGui()
		local sd  = gui and descend(gui, SCHED_PATH)
		if not sd then return nil end

		for _, node in ipairs(sd:GetDescendants()) do
			if node:IsA("TextLabel") then
				local ok, t = pcall(function() return node.Text end)
				if ok and t then
					local sign, mm, ss = tostring(t):match("([%+%-])(%d+):(%d%d)")
					if sign and mm and ss then
						local secs = tonumber(mm) * 60 + tonumber(ss)
						if secs then
							return (sign == "+") and secs or -secs
						end
					end
				end
			end
		end
		return nil
	end

	----------------------------------------------------------------------
	-- SPEED, MEASURED OFF THE COUNTER ITSELF
	--
	-- The counter moves in 0.01 mi steps, which at 100 mph is a tick every
	-- third of a second and at 30 mph every 1.2 s — coarse, but it is in
	-- exactly the units the curve wants and it cannot disagree with the
	-- distance the curve is working from.
	----------------------------------------------------------------------
	local function sampleSpeed()
		local mi  = stopMiles()
		local now = os.clock()

		if mi == nil then
			lastMi, lastAt = nil, nil
			return
		end

		if lastMi == nil then
			lastMi, lastAt = mi, now
			return
		end

		local dt = now - lastAt
		if dt < 0.25 then return end

		local closed = lastMi - mi          -- miles closed since last sample
		lastMi, lastAt = mi, now

		if closed <= 0 then
			-- Counter went up or stood still. Standing still is a stopped
			-- train; going up is a new leg. Either way decay rather than
			-- claim a speed we did not see.
			mph = mph * 0.6
			return
		end

		local obs = (closed / dt) * 3600    -- miles/s -> mph
		if obs > 200 then return end        -- a leg change, not a speed

		local prev = mph
		mph = mph + (obs - mph) * 0.4

		-- Falling speed is the brake working. Measure it.
		if prev > mph and dt > 0 then
			local drop = (prev - mph) / dt
			if drop > 0.2 and drop < 8 then
				rateSeen = rateSeen and (rateSeen + (drop - rateSeen) * 0.2) or drop
				if rateSeen < RATE_MIN then rateSeen = RATE_MIN end
				if rateSeen > RATE_MAX then rateSeen = RATE_MAX end
			end
		end
	end

	----------------------------------------------------------------------
	-- THE CURVE
	--
	-- v^2 = TARGET^2 + A * d, with A in mph^2 per mile. A = 7200 * rate,
	-- where rate is mph per second — that constant carries the hours-to-
	-- seconds conversion and the factor of two out of v^2 = 2 a d.
	--
	-- Sanity check: rate 2.23694 mph/s is 1.0 m/s², giving A = 16106, and
	-- 100 mph down to 25 needs (10000 - 625) / 16106 = 0.58 mi. Which is
	-- the number that says 0.32 mi was never going to be enough.
	----------------------------------------------------------------------
	local function planRate()
		-- The measurement can only ever RAISE the planned rate above the
		-- default, never lower it. `drop` is the change in an EWMA, not the
		-- real deceleration, so it reads roughly 40% of the truth — and a
		-- rate that low is not conservative, it is useless: at RATE_MIN the
		-- curve starts braking 2.2 miles out and the train crawls into every
		-- station. Flooring at the assumed rate keeps the measurement doing
		-- the one thing it is good for, which is noticing a train that stops
		-- harder than assumed and braking later for it.
		local base = RATE
		if rateSeen and rateSeen > base then base = rateSeen end

		local late = lateness()
		local factor = EARLY_FACTOR
		if late ~= nil and late > LATE_AFTER then factor = LATE_FACTOR end
		return base * factor, factor
	end

	-- The highest speed we are willing to see commanded right now, or nil
	-- when the platform is far enough away that the original's own choice
	-- is already fine.
	local function ceiling()
		if not ENABLED then return nil end

		local mi = stopMiles()
		if mi == nil or mi <= 0 or mi > MAX_LOOK then return nil end

		local rate = planRate()
		local A    = 7200 * rate
		local v    = math.sqrt(TARGET_SPEED * TARGET_SPEED + A * mi)

		if v < MIN_CAP then v = MIN_CAP end
		return v
	end

	----------------------------------------------------------------------
	-- INSTALL
	----------------------------------------------------------------------
	local function install()
		realTarget = target

		-- Reduce only. There is deliberately no branch here that can raise a
		-- commanded speed: if the curve allows more than b() asked for, b()
		-- wins.
		target = function(speed)
			if type(speed) == "number" and speed > MIN_CAP then
				local cap = ceiling()
				if cap and speed > cap then
					capped = capped + 1
					lastCap = cap
					speed = math.floor(cap + 0.5)
				end
			end
			return realTarget(speed)
		end

		-- b() only fires when a HUD label changes, and near the end of an
		-- approach those go quiet for seconds at a time. Re-assert the
		-- ceiling on our own clock so the curve is actually followed, but
		-- only ever downwards.
		-- True while one of our own re-assertions is still inside the
		-- original's target(). That function BLOCKS while it ramps the notch,
		-- so firing another every 0.4s would stack ramp threads fighting over
		-- W and S — the exact failure the buffer approach had to be rebuilt
		-- to avoid.
		local inFlight = false

		local function othersDriving()
			for _, name in ipairs({ "SCRBuffer", "SCRPlatform" }) do
				local api = _G[name]
				if api and api.busy then
					local ok, busy = pcall(api.busy)
					if ok and busy then return true end
				end
			end
			return false
		end

		task.spawn(function()
			while true do
				task.wait(TICK)
				pcall(function()
					sampleSpeed()
					if not ENABLED or inFlight then return end

					-- The buffer approach and the platform block press W and S
					-- themselves. This re-assertion goes straight to the
					-- original's target(), underneath their swallows, so it
					-- has to stand down on its own account.
					if othersDriving() then return end

					local cap = ceiling()
					if not cap then return end
					local have = notchMph()
					if have and have > cap + NOTCH_SLACK then
						lastCap = cap
						inFlight = true
						task.spawn(function()
							pcall(realTarget, math.floor(cap + 0.5))
							inFlight = false
						end)
					end
				end)
			end
		end)

		_G.SCRBrake = {
			set = function(t)
				if type(t) ~= "table" then
					warn("[brake] usage: _G.SCRBrake.set{ target = 25, rate = 2.0, early = 0.75 }")
					return false
				end
				if tonumber(t.target) then TARGET_SPEED = tonumber(t.target) end
				if tonumber(t.rate)   then RATE         = tonumber(t.rate)   end
				if tonumber(t.early)  then EARLY_FACTOR = tonumber(t.early)  end
				if tonumber(t.lateAfter) then LATE_AFTER = tonumber(t.lateAfter) end
				log("target %.0f mph | rate %.2f mph/s | early %.2f | late after %.0fs",
					TARGET_SPEED, RATE, EARLY_FACTOR, LATE_AFTER)
				return true
			end,

			enable  = function() ENABLED = true  ; log("armed") end,
			disable = function() ENABLED = false ; log("off — the original's fixed 0.32 mi is back") end,

			status = function()
				local mi   = stopMiles()
				local rate, factor = planRate()
				local late = lateness()
				local cap  = ceiling()

				-- Where the curve says braking has to begin from the speed
				-- we are actually doing. This is the number the original
				-- hard-coded at 0.32.
				local need = nil
				if mph > TARGET_SPEED then
					need = (mph * mph - TARGET_SPEED * TARGET_SPEED) / (7200 * rate)
				end

				return ("[brake] %s | %.0f mph closing | %s mi to go | ceiling %s mph\n" ..
				        "        brake rate %.2f mph/s (%s) x %.2f (%s) | needs %s mi to reach %.0f\n" ..
				        "        %.0f command(s) pulled down | last ceiling %s")
					:format(installed and (ENABLED and "armed" or "disabled") or "NOT installed",
						mph, mi and ("%.2f"):format(mi) or "?",
						cap and ("%.0f"):format(cap) or "none",
						rate / factor, rateSeen and "measured" or "assumed", factor,
						(late ~= nil and late > LATE_AFTER) and ("running %.0fs late"):format(late)
							or "on time",
						need and ("%.2f"):format(need) or "-", TARGET_SPEED,
						capped, lastCap and ("%.0f"):format(lastCap) or "-")
			end,
		}

		installed = true
		log("armed — braking point now comes off the curve, not a fixed %.2f mi", 0.32)
	end

	-- Installs early, so its ceiling is the last thing applied before the
	-- original's target() actually moves the notch.
	task.spawn(function()
		local t0 = os.clock()
		repeat
			task.wait(0.1)
		until (_G.SCRFix and type(target) == "function") or (os.clock() - t0 > 30)

		if type(target) == "function" then
			install()
		else
			warn("[brake] target() never appeared — dynamic braking is NOT active.")
		end
	end)
end
-- ================== END DYNAMIC BRAKING POINT ===========================

--[[ ======================================================================
     STATION STOP HOLD  —  self-contained add-on, above the original.

     On arrival the original goes straight to a dead stop:

         if num == 0 ... then
             ...
             cs:Fire(0)

     This inserts a short crawl first — HOLD_SPEED for HOLD_TIME, then 0 —
     so the train eases the last few feet into the platform instead of
     slamming to a stand the instant the counter hits zero.

     It works by wrapping the global target(), so the original is untouched.
     When a stop command arrives AND the distance counter reads zero, it
     commands the crawl, waits, then passes the stop through.

     THREE THINGS IT DELIBERATELY DOES NOT DO
       * It never holds for a RED SIGNAL. That branch of the original also
         calls for a stop, but with distance still above zero, so the crawl
         is skipped. A 5 mph creep towards a red is exactly how you SPAD.
       * It never holds at a terminus straight after a buffer creep. That
         creep has already put you where you should be, and two more seconds
         of 5 mph would push you into the buffer.
       * It holds ONCE per arrival. The original calls b() again on every
         label change, and without a latch the train would inch forward
         every few seconds while sat at the platform.

       _G.SCRStop.status()     -- armed? how many holds?
       _G.SCRStop.set(5, 2)    -- speed, seconds
       _G.SCRStop.disable()    -- and .enable()
====================================================================== ]]
do
	local ENABLED     = true
	local HOLD_SPEED  = 5     -- mph to crawl at
	local HOLD_TIME   = 2.0   -- seconds to hold it
	local CREEP_GUARD = 3.0   -- skip if a buffer creep ran within this many s
	local VERBOSE     = true

	local Players = game:GetService("Players")
	local player  = Players.LocalPlayer

	local DIST_PATH = { "Additional", "DetailsStack", "AdvanceContainer", "Main",
	                    "ScheduleDetails", "Counters", "Distance" }

	local holds, active, done, installed = 0, false, false, false

	local function log(fmt, ...)
		if not VERBOSE then return end
		print("[stop-hold] " .. (select("#", ...) > 0 and fmt:format(...) or fmt))
	end

	local function distanceMiles()
		local pg  = player:FindFirstChild("PlayerGui")
		local gui = pg and pg:FindFirstChild("DriveGui")
		if not gui then return nil end
		local node = gui
		for _, name in ipairs(DIST_PATH) do
			node = node:FindFirstChild(name)
			if not node then return nil end
		end
		local ok, txt = pcall(function() return node.Text end)
		if not ok then return nil end
		return tonumber(tostring(txt):match("%d+%.?%d*"))
	end

	-- Latch reset: once the counter shows distance again we have departed,
	-- so the next arrival gets its own hold.
	task.spawn(function()
		while true do
			task.wait(1)
			local mi = distanceMiles()
			if mi and mi > 0 and done then
				done = false
			end
		end
	end)

	local function install()
		local realTarget = target

		target = function(speed)
			if ENABLED and speed == 0 and not done then
				-- Only at a platform. A red-signal stop still has distance
				-- on the clock, so it falls straight through to the stop.
				local mi = distanceMiles()

				-- Never at a terminus. The buffer approach drives its own way
				-- in and a 5 mph hold on top of it is one more thing pushing
				-- the train at the buffer.
				local bufferBusy = false
				if _G.SCRBuffer and _G.SCRBuffer.busy then
					local okb, bb = pcall(_G.SCRBuffer.busy)
					bufferBusy = okb and bb or false
				end
				if bufferBusy then done = true end

				if mi == 0 and not active and not bufferBusy then
					local creeping = false
					if _G.SCRFix and _G.SCRFix.lastCreep then
						local ok, t = pcall(_G.SCRFix.lastCreep)
						creeping = ok and (os.clock() - t) < CREEP_GUARD
					end

					if creeping then
						log("terminus creep just ran — stopping immediately")
						done = true
					else
						active, done = true, true
						holds = holds + 1
						log("arrival #%d — holding %d mph for %.1fs", holds, HOLD_SPEED, HOLD_TIME)
						realTarget(HOLD_SPEED)
						task.wait(HOLD_TIME)
						active = false
						log("hold done — stopping")
						return realTarget(0)
					end
				end
			end

			-- Drop stop commands that land mid-hold; the hold ends in one
			-- anyway, and letting them through would cut it short.
			if active and speed == 0 then return end

			return realTarget(speed)
		end

		_G.SCRStop = {
			enable  = function() ENABLED = true;  log("enabled") end,
			disable = function() ENABLED = false; log("disabled") end,

			-- Let the next stop command through untouched. The buffer
			-- approach calls this before its final stop: it has already
			-- eased the train in over the whole run, and a 5 mph nudge on
			-- top of that would roll it into the buffer.
			skipNext = function()
				done   = true
				active = false
			end,
			set = function(spd, secs)
				spd, secs = tonumber(spd), tonumber(secs)
				if not spd or not secs or spd < 0 or secs < 0 then
					warn("[stop-hold] usage: _G.SCRStop.set(speed, seconds)")
					return false
				end
				HOLD_SPEED, HOLD_TIME = spd, secs
				log("now %d mph for %.1fs", spd, secs)
				return true
			end,
			status = function()
				return ("[stop-hold] %s | %d mph for %.1fs | %d hold(s) | %s"):format(
					installed and (ENABLED and "armed" or "disabled") or "NOT installed",
					HOLD_SPEED, HOLD_TIME, holds,
					active and "holding now" or (done and "already held this stop" or "waiting"))
			end,
		}

		installed = true
		log("armed — %d mph for %.1fs on arrival", HOLD_SPEED, HOLD_TIME)
	end

	-- Install after the creep guard, so the chain is
	-- caller -> stop-hold -> dedupe -> real target.
	task.spawn(function()
		local t0 = os.clock()
		repeat task.wait(0.1) until (_G.SCRFix and type(target) == "function")
			or os.clock() - t0 > 35
		if type(target) == "function" then
			install()
		else
			warn("[stop-hold] target() never appeared — hold NOT active.")
		end
	end)
end
-- ================== END STATION STOP HOLD ===============================


--[[ ======================================================================
     WHITE LIGHT / SHUNT SIGNAL  —  self-contained add-on, above the original.

     THE PROBLEM
     -----------
     The original only knows four aspects. getSignal() checks, in order,
     Standard.Danger, Standard.Precaution, Standard.Caution, Standard.Proceed:

         if signal.Danger.BackgroundTransparency == 0 then ... danger

     A position light — the white lights you get let out of a depot or across
     a yard — is not one of those four. SCR swaps the aspect column out for a
     shunt display, but the old column's transparency is left exactly as it
     was, so the original goes on reading a red that is no longer on screen.
     b() then lands on

         if num == 0 or (getSignal() == signalv.danger and num >= getSignalDistance())
             cs:Fire(0)

     and the train is pinned. Drive it forward by hand and the next label
     change re-runs b(), which fires 0 again and winds the notch straight back
     down — hence having to out-muscle it until the signal is behind you.

     WHAT THIS DOES
     --------------
     It turns that one stop command into a shunt-speed command, and only that
     one. Nothing else about the original changes, and the moment the shunt
     display goes away the stop command passes through untouched again.

     HOW IT KNOWS, AND WHY IT IS THIS FUSSY
     --------------------------------------
     Releasing a stop is the most dangerous thing an add-on here can do, so
     the test is not "does anything white-ish appear anywhere". Two separate
     things must both be true:

       1. THE ASPECT COLUMN THE ORIGINAL READS IS NOT ON SCREEN. This is the
          whole bug in one condition — it is what makes the red reading stale.
          At a real red the column is up and lit, so this is false and the
          stop always stands. No amount of white elsewhere can override it.

       2. A LIT, NEAR-WHITE, INDICATOR-SHAPED NODE IS ON SCREEN in the signal
          frame. Colour, not name: names are guesswork, a white light is
          white. Near-white is deliberately strict, so a pale grey unlit lamp
          cannot pass for a lit one.

     Plus the ordinary guards: never while berthing at a platform, never for a
     signal further off than SIGNAL_NEAR, never over the buffer approach, and
     never faster than the posted limit.

     If it cannot see the light it says so and points at the probe, rather
     than sitting there silently — but it will not guess.

       _G.SCRWhite.probe()    -- dump the signal panel: what is lit, and what colour
       _G.SCRWhite.go()       -- release by hand for RELEASE_FOR seconds. This one
                              -- does NOT look at the signal at all — it is the
                              -- escape hatch for when detection is wrong, and it
                              -- will happily drive past a red. .stop() cancels it.
       _G.SCRWhite.status()   -- armed? how many shunt releases so far?
       _G.SCRWhite.set(mph)   -- change the shunt speed
       _G.SCRWhite.disable()  -- and .enable()
====================================================================== ]]
do
	----------------------------------------------------------------------
	local ENABLED      = true

	local SHUNT_SPEED  = 15    -- mph to move at under a white light
	local SIGNAL_NEAR  = 0.15  -- miles — only release when the signal is this close
	local RELEASE_FOR  = 90    -- s — how long a manual .go() lasts
	local HOLD_LIMIT   = 300   -- s — stop releasing if one white light somehow
	                           -- stays lit this long without us getting past it

	local WHITE_MIN    = 0.85  -- darkest channel a lit white light may have
	local WHITE_SPREAD = 0.08  -- most it may vary between channels

	local HINT_AFTER   = 8     -- stop commands, at an unchanging very-close
	local HINT_WINDOW  = 45    -- signal within this many seconds, before it
	                           -- says "I cannot see this light"

	local VERBOSE      = true
	----------------------------------------------------------------------

	local Players = game:GetService("Players")
	local player  = Players.LocalPlayer

	local SIG_PATH  = { "Additional", "DetailsStack", "AdvanceContainer", "Signal" }
	local DIST_PATH = { "Additional", "DetailsStack", "AdvanceContainer", "Main",
	                    "ScheduleDetails", "Counters", "Distance" }

	-- The four the original already reads, plus the readouts and containers.
	-- Everything else in the signal frame is a candidate for being white.
	local KNOWN = {
		Danger = true, Precaution = true, Caution = true, Proceed = true,
		Distance = true, Standard = true,
	}

	-- Only ever used to annotate the probe output. Deliberately NOT part of
	-- the release test: a node called "Subsidiary" or "WhiteBar" exists
	-- whether or not the lamp behind it is on, and treating a name as
	-- evidence of a lit light is how this block would run a red.
	local SHUNT_NAMES = {
		"hite", "hunt", "ubsid", "all[Oo]n", "osition", "estricted", "ossession",
	}

	local realTarget  = nil
	local installed   = false
	local shunts      = 0
	local whiteSince, whiteAtSig = nil, nil
	local holdTripped = false
	local manualUntil = -math.huge
	local lastName    = "-"
	local zeroes, zeroFrom, hinted = 0, 0, false

	local function unlatch()
		whiteSince, whiteAtSig, holdTripped = nil, nil, false
	end

	local function log(fmt, ...)
		if not VERBOSE then return end
		print("[white] " .. (select("#", ...) > 0 and fmt:format(...) or fmt))
	end

	----------------------------------------------------------------------
	-- HUD, resolved fresh so a rebuilt DriveGui cannot strand this
	----------------------------------------------------------------------
	local function driveGui()
		local pg = player:FindFirstChild("PlayerGui")
		return pg and pg:FindFirstChild("DriveGui") or nil
	end

	local function descend(root, path)
		local node = root
		for _, name in ipairs(path) do
			if not node then return nil end
			node = node:FindFirstChild(name)
		end
		return node
	end

	local function signalFrame()
		local gui = driveGui()
		return gui and descend(gui, SIG_PATH) or nil
	end

	local function milesFrom(node)
		if not node then return nil end
		local ok, txt = pcall(function() return node.Text end)
		if not ok then return nil end
		return tonumber(tostring(txt):match("%d+%.?%d*"))
	end

	local function nextStopMiles()
		local gui = driveGui()
		return milesFrom(gui and descend(gui, DIST_PATH))
	end

	local function signalMiles()
		local sf = signalFrame()
		return milesFrom(sf and sf:FindFirstChild("Distance"))
	end

	local function onScreen(obj)
		local node = obj
		while node and node ~= game do
			if node:IsA("LayerCollector") then return node.Enabled end
			if node:IsA("GuiObject") and not node.Visible then return false end
			node = node.Parent
		end
		return false
	end

	----------------------------------------------------------------------
	-- CONDITION 1 — the column the original reads is not on screen
	--
	-- This is the entire bug, expressed as a test. getSignal() reports danger
	-- off Standard.Danger.BackgroundTransparency, and transparency does not
	-- change when SCR hides the column, so the reading outlives the aspect.
	-- At a genuine red the column is up, this is false, and the stop stands
	-- no matter what else is on screen.
	----------------------------------------------------------------------
	local function aspectColumnStale()
		local sf = signalFrame()
		if not sf then return false end
		local std = sf:FindFirstChild("Standard")
		if not std then return false end   -- cannot tell — assume it is live

		-- The straightforward case: SCR swapped the column out for a shunt
		-- display and left the old transparencies where they were.
		if not onScreen(std) then return true end

		-- The other way SCR could do it is to REBUILD the panel. Then the
		-- original is holding an orphaned Danger node, frozen at whatever it
		-- was, while a fresh column sits on screen — and the column looks
		-- perfectly live from here. What gives it away is that the two
		-- disagree: ask the live lamp, then ask the original.
		local dg = std:FindFirstChild("Danger")
		if not dg then return false end
		local ok, t = pcall(function() return dg.BackgroundTransparency end)
		if not ok then return false end

		-- Live lamp lit means a real red. Nothing below can override that.
		if t <= 0.15 then return false end

		if type(getSignal) == "function" and signalv then
			local ok2, s = pcall(getSignal)
			if ok2 and s == signalv.danger then
				return true   -- the original is reading a node that is no longer the panel
			end
		end
		return false
	end

	----------------------------------------------------------------------
	-- CONDITION 2 — a lit white indicator is on screen
	----------------------------------------------------------------------
	local function nearWhite(c)
		if not c then return false end
		local lo = math.min(c.R, c.G, c.B)
		local hi = math.max(c.R, c.G, c.B)
		return lo >= WHITE_MIN and (hi - lo) <= WHITE_SPREAD
	end

	local function shuntName(name)
		for _, pat in ipairs(SHUNT_NAMES) do
			if string.match(name, pat) then return true end
		end
		return false
	end

	-- Shaped like a lamp rather than a panel or a caption, sized against the
	-- viewport so this still works on a 4K screen or a scaled HUD.
	local function indicatorShaped(node)
		if node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox") then
			return false
		end
		local ok, sz = pcall(function() return node.AbsoluteSize end)
		if not ok or not sz then return false end

		local cam = workspace.CurrentCamera
		local h   = (cam and cam.ViewportSize and cam.ViewportSize.Y) or 1080
		if type(h) ~= "number" or h <= 0 then h = 1080 end   -- 0 is truthy in Lua
		local lo, hi = h * 0.004, h * 0.055

		if sz.X < lo or sz.Y < lo or sz.X > hi or sz.Y > hi then return false end
		local big = math.max(sz.X, sz.Y)
		return math.abs(sz.X - sz.Y) <= big * 0.25
	end

	local function litWhite(node)
		local ok, res = pcall(function()
			if (node:IsA("ImageLabel") or node:IsA("ImageButton"))
				and node.ImageTransparency <= 0.15
				and nearWhite(node.ImageColor3) then
				return true
			end
			return node.BackgroundTransparency <= 0.15 and nearWhite(node.BackgroundColor3)
		end)
		return ok and res or false
	end

	-- Walks the WHOLE signal frame, not just Standard, because the shunt
	-- display is its own sub-frame. Colour and shape only — see SHUNT_NAMES.
	local function whiteLit()
		local sf = signalFrame()
		if not sf then return false, nil end
		for _, node in ipairs(sf:GetDescendants()) do
			if node:IsA("GuiObject") and not KNOWN[node.Name]
				and indicatorShaped(node) and litWhite(node) and onScreen(node) then
				return true, node.Name
			end
		end
		return false, nil
	end

	----------------------------------------------------------------------
	-- SHOULD THIS STOP BECOME A SHUNT
	----------------------------------------------------------------------
	local function bufferBusy()
		for _, name in ipairs({ "SCRBuffer" }) do
			local api = _G[name]
			if api and api.busy then
				local ok, busy = pcall(api.busy)
				if ok and busy then return true end
			end
		end
		return false
	end

	local function shouldShunt()
		if not ENABLED then unlatch() return false end

		-- Two things a release is never right for, manual or not: berthing at
		-- a platform, and the buffer approach's own stops.
		if bufferBusy() then unlatch() return false end
		local stop = nextStopMiles()
		if stop == nil or stop == 0 then unlatch() return false end

		-- A hand release skips the detection, because it exists for the case
		-- where the detection is wrong. It does not skip the two above — and
		-- it does not check the signal either, which is the point of it.
		if os.clock() < manualUntil then return true, "manual" end

		-- Only at the signal, never approaching one.
		local sig = signalMiles()
		if sig == nil or sig > SIGNAL_NEAR then unlatch() return false end

		-- Condition 1, then condition 2. Both, every time.
		if not aspectColumnStale() then unlatch() return false end

		local lit, name = whiteLit()
		if not lit then unlatch() return false end

		-- A different signal, even if it is also a white one, is a fresh
		-- start. Without this the timer from the last depot would still be
		-- running at the next one.
		if whiteSince and whiteAtSig and math.abs(sig - whiteAtSig) > 0.05 then
			unlatch()
		end

		if not whiteSince then
			whiteSince, whiteAtSig = os.clock(), sig
			log("white light on (%s), aspect column stale, %.2f mi — shunting at %.0f mph",
				name, sig, SHUNT_SPEED)
		elseif os.clock() - whiteSince > HOLD_LIMIT then
			-- Five minutes of releasing and still at the same light means
			-- something is wrong with the reading. Let the stop stand.
			if not holdTripped then
				holdTripped = true
				warn("[white] still at the same white light after " .. HOLD_LIMIT ..
				     "s — no longer releasing. _G.SCRWhite.go() overrides this.")
			end
			return false
		end

		lastName = name or "-"
		return true, name
	end

	local function shuntSpeed()
		local mph = SHUNT_SPEED
		if type(getSpeedLimit) == "function" then
			local ok, v = pcall(getSpeedLimit)
			local lim = ok and tonumber(v) or nil
			if lim and lim > 0 and lim < mph then mph = lim end
		end
		return math.floor(mph)
	end

	----------------------------------------------------------------------
	-- The stop that nobody can explain. Not a red — at a red the aspect
	-- column is on screen. This is specifically "the column is gone, so the
	-- original is reading a stale aspect, and no white light was recognised
	-- either", at a signal whose distance has not budged. That is the bug
	-- this block exists for, with detection that failed.
	----------------------------------------------------------------------
	local function maybeHint()
		if hinted or holdTripped then return end
		local sig, stop = signalMiles(), nextStopMiles()
		if not (sig and sig <= 0.05 and stop and stop ~= 0) then return end
		-- A red has its column on screen and agreeing with the original, so
		-- this alone is enough to keep the hint away from ordinary signals.
		if not aspectColumnStale() then return end

		local now = os.clock()
		if (now - zeroFrom) > HINT_WINDOW then zeroes, zeroFrom = 0, now end
		zeroes = zeroes + 1
		if zeroes < HINT_AFTER then return end

		hinted = true
		warn("[white] stopped at a signal " .. tostring(sig) .. " mi away, the aspect " ..
		     "column is not on screen, and no white light was recognised. Run " ..
		     "_G.SCRWhite.probe() and send the output. If you can see a white light " ..
		     "on the signal, _G.SCRWhite.go() will get you moving now.")
	end

	----------------------------------------------------------------------
	-- INSTALL
	----------------------------------------------------------------------
	local function install()
		realTarget = target
		target = function(speed)
			if speed == 0 then
				local ok, go, why = pcall(shouldShunt)
				if ok and go then
					shunts = shunts + 1
					local mph = shuntSpeed()
					if shunts % 20 == 1 then
						log("holding %.0f mph past the white light (%s)", mph, why or lastName)
					end
					return realTarget(mph)
				end
				pcall(maybeHint)
			end
			return realTarget(speed)
		end

		_G.SCRWhite = {
			go = function(secs)
				local n = tonumber(secs) or RELEASE_FOR
				manualUntil = os.clock() + n
				log("manual release for %.0fs at %.0f mph. This does NOT check the " ..
					"signal — it will drive past a red. Platform stops and the buffer " ..
					"approach still override it; _G.SCRWhite.stop() cancels it.",
					n, shuntSpeed())
				if type(b) == "function" then pcall(b) end
				return true
			end,

			stop = function()
				manualUntil = -math.huge
				unlatch()
				log("manual release cancelled")
				if type(b) == "function" then pcall(b) end
			end,

			-- Everything in the signal panel, so a light this does not
			-- recognise can be identified and named.
			probe = function()
				local sf = signalFrame()
				if not sf then
					warn("[white] no signal frame — is the DriveGui up?")
					return
				end
				print("[white] --- " .. sf:GetFullName() .. " ---")
				for _, n in ipairs(sf:GetDescendants()) do
					if n:IsA("GuiObject") then
						local ok, line = pcall(function()
							local c  = n.BackgroundColor3
							local sz = n.AbsoluteSize
							return ("  %-22s %-12s bg %.2f  rgb %.2f/%.2f/%.2f  %.0fx%.0f  vis=%s shown=%s%s%s")
								:format(n.Name, n.ClassName, n.BackgroundTransparency,
									c.R, c.G, c.B, sz.X, sz.Y,
									tostring(n.Visible), tostring(onScreen(n)),
									shuntName(n.Name) and "  <-- shunt-ish name" or "",
									(n:IsA("TextLabel") and ("  text=" .. tostring(n.Text)) or ""))
						end)
						print(ok and line or ("  " .. n.Name .. " (unreadable)"))
					end
				end

				local lit, name = whiteLit()
				local stale = aspectColumnStale()
				print(("[white] condition 1, aspect column stale: %s"):format(tostring(stale)))
				print(("[white] condition 2, white light lit: %s%s")
					:format(tostring(lit), name and (" (" .. name .. ")") or ""))
				print(("[white] would release: %s | signal %s mi | next stop %s mi")
					:format(tostring(stale and lit), tostring(signalMiles()), tostring(nextStopMiles())))
				if type(getSignal) == "function" then
					local ok, s = pcall(getSignal)
					print("[white] the original reads this signal as: " .. (ok and tostring(s) or "error"))
				end
				return lit, name
			end,

			set = function(mph)
				local v = tonumber(mph)
				v = v and math.floor(v) or nil
				-- Floor FIRST. set(0.5) validating as "> 0" and then flooring
				-- to 0 would look like it worked and silently release to a
				-- stop command every time.
				if not v or v < 1 or v > 40 then
					warn("[white] usage: _G.SCRWhite.set(15) — whole mph, 1 to 40")
					return false
				end
				SHUNT_SPEED = v
				log("shunt speed now %.0f mph", SHUNT_SPEED)
				return true
			end,

			enable  = function() ENABLED = true  ; log("armed") end,
			disable = function() ENABLED = false ; unlatch()
				log("off — white lights are the original's problem again") end,

			status = function()
				local lit, name = whiteLit()
				return ("[white] %s | %.0f release(s) | column stale: %s | white now: %s%s | signal %s mi | shunt %.0f mph")
					:format(installed and (ENABLED and "armed" or "disabled") or "NOT installed",
						shunts, tostring(aspectColumnStale()), tostring(lit),
						name and (" " .. name) or "",
						tostring(signalMiles()), shuntSpeed())
			end,
		}

		installed = true
		log("armed — a stale aspect column plus a lit white light releases the stop at %.0f mph",
			SHUNT_SPEED)
	end

	-- After the stop-hold, before the buffer approach.
	task.spawn(function()
		local t0 = os.clock()
		repeat
			task.wait(0.1)
		until (_G.SCRStop and type(target) == "function") or (os.clock() - t0 > 35)

		if type(target) == "function" then
			install()
		else
			warn("[white] target() never appeared — white-light handling is NOT active.")
		end
	end)
end
-- ================== END WHITE LIGHT / SHUNT =============================


--[[ ======================================================================
     PLATFORM ALIGNMENT  —  self-contained add-on, above the original.

     THE PROBLEM
     -----------
     The original stops when the next-stop counter reads 0.00 mi. That point
     does not know how long your train is, so the stop can leave the back of
     the train off the platform and SCR asks for more:

         "Move forward until the train is fully alongside the platform"

     and the run sits there until somebody drives it forward by hand.

     WHAT THIS DOES
     --------------
     Once the train has COME TO A STAND at a platform and SCR is still asking
     for more, it rolls forward slowly and stops the instant the banner turns
     into the doors prompt. One continuous movement, not a series of nudges.

     WHY IT WAITS FOR THE TRAIN TO STOP FIRST
     ----------------------------------------
     An earlier version took the train the moment b() commanded its stop.
     That command lands while the train is still doing sixty, so the block
     inherited a moving train, timed out waiting for it to settle, treated
     the timeout as "stopped", and then commanded 5 mph into forty mph of
     momentum — and rolled straight through the platform. Three separate
     things had to be wrong for that, and all three are now fixed:

       * it never engages a moving train — the train must be measurably
         stationary, and that is measured from its POSITION, not from a
         settle routine that can time out;
       * every movement it makes has a hard distance budget as well as a
         time limit, so it cannot run away even if the prompt never arrives;
       * it aborts the moment the platform is behind us.

     Braking from line speed stays entirely with the original. This block
     only ever moves the train at walking pace, and never more than
     MAX_TRAVEL studs in one go.

     THE CAR-STOP BOARDS
     -------------------
     Off by default, and deliberately. The boards are not the simple car
     counts they looked like — real ones read "S", "S HST", "9 10 Class 80x"
     — so which board a given train belongs at is not something to guess at
     while driving. The scanner and the reporting are here so we can work out
     the rule from real data; turn it on with _G.SCRPlatform.markers(true)
     once we know what we are reading. Even then, driving to a board uses the
     same bounded walking-pace roll as everything else here.

       _G.SCRPlatform.probe()      -- every board it can see, and how it read it
       _G.SCRPlatform.status()     -- arrivals, rolls, what it has found
       _G.SCRPlatform.align()      -- run the forward roll by hand, now
       _G.SCRPlatform.markers(b)   -- turn board-seeking on or off
       _G.SCRPlatform.setCars(3)   -- if it guesses your train length wrong
       _G.SCRPlatform.disable()    -- and .enable()
====================================================================== ]]
do
	----------------------------------------------------------------------
	local ENABLED       = true
	local USE_MARKERS   = false  -- see above; opt in with .markers(true)

	local CARS          = 3
	local ROLL_SPEED    = 5      -- mph for the forward roll
	local ROLL_MAX      = 10     -- mph it may escalate to if it will not budge

	-- SAFETY, all of it. Nothing here moves the train outside these.
	local STILL_STUDS   = 1.2    -- movement under this counts as stationary
	local STILL_FOR     = 1.5    -- s of that before we believe it
	local MAX_TRAVEL    = 200    -- studs — hard budget on one roll, no exceptions
	local ROLL_LIMIT    = 30     -- s — hard time limit on one roll
	local SETTLE_LIMIT  = 10     -- s — waiting for a stand after we stop it
	local PROMPT_WAIT   = 2.5    -- s to let SCR react once we stop

	local SIDE_MAX      = 45     -- studs off our centreline = our platform
	local AHEAD_MIN     = 4
	local AHEAD_MAX     = 400    -- a board further than this is another train's
	local KEEP_RADIUS   = 3000
	local RESCAN_GAP    = 15
	local SCAN_CAP      = 500000

	local RESTART_LOCK  = 25     -- s before the same stop may be worked again
	local GRACE         = 10     -- s after a roll where we still report busy

	local START_BAND    = 1.8
	local MAX_HOLD      = 3.0
	local HOLD_REST     = 0.4

	local VERBOSE       = true
	----------------------------------------------------------------------

	local Players = game:GetService("Players")
	local VIM     = game:GetService("VirtualInputManager")
	local player  = Players.LocalPlayer

	local DIST_PATH  = { "Additional", "DetailsStack", "AdvanceContainer", "Main",
	                     "ScheduleDetails", "Counters", "Distance" }
	local SCHED_PATH = { "Additional", "DetailsStack", "AdvanceContainer",
	                     "Main", "ScheduleDetails" }
	local MSG_PATH   = { "Additional", "DetailsStack", "MessageContainer" }
	local BANNER_PATH= { "Cluster", "Activity", "ActivityMessage" }

	local realTarget = nil
	local installed  = false
	local owning     = false
	local settledAt  = -math.huge
	local settledKey = nil

	local markers   = {}
	local lastScan  = -math.huge
	local scanCount = 0

	local rolls, alignedOk, missed = 0, 0, 0
	local rollKey, rollCount = nil, 0
	local MAX_ROLLS = 3          -- rolls at one stop before it gives up
	local lastLine = "nothing yet"
	local carsAuto = nil

	local function log(fmt, ...)
		if not VERBOSE then return end
		print("[platform] " .. (select("#", ...) > 0 and fmt:format(...) or fmt))
	end

	----------------------------------------------------------------------
	-- HUD
	----------------------------------------------------------------------
	local function driveGui()
		local pg = player:FindFirstChild("PlayerGui")
		return pg and pg:FindFirstChild("DriveGui") or nil
	end

	local function descend(root, path)
		local node = root
		for _, name in ipairs(path) do
			if not node then return nil end
			node = node:FindFirstChild(name)
		end
		return node
	end

	local function onScreen(obj)
		local node = obj
		while node and node ~= game do
			if node:IsA("LayerCollector") then return node.Enabled end
			if node:IsA("GuiObject") and not node.Visible then return false end
			node = node.Parent
		end
		return false
	end

	local function nextStopMiles()
		local gui = driveGui()
		local n = gui and descend(gui, DIST_PATH)
		if not n then return nil end
		local ok, txt = pcall(function() return n.Text end)
		if not ok then return nil end
		return tonumber(tostring(txt):match("%d+%.?%d*"))
	end

	local function stationKey()
		local gui = driveGui()
		local sd  = gui and descend(gui, SCHED_PATH)
		if not sd then return nil end
		local st = sd:FindFirstChild("NextStop")
		local pl = sd:FindFirstChild("Platform")
		if not (st and pl) then return nil end
		local ok, key = pcall(function()
			return tostring(st.Text) .. "|" .. (tostring(pl.Text):gsub("Platform%s*", ""))
		end)
		return ok and key or nil
	end

	local function notchMph()
		local gui = driveGui()
		local a = gui and descend(gui, { "Cluster", "Spedometer", "TargetIndicator" })
		if not a then return nil end
		local ok, rot = pcall(function() return a.Rotation end)
		if not ok or type(rot) ~= "number" then return nil end
		return (rot + 31) / 1.2
	end

	----------------------------------------------------------------------
	-- WHAT SCR IS ASKING FOR
	--
	-- There are two channels and they contradict each other, which is the
	-- whole problem.
	--
	--   THE BANNER reads "Unlock doors to begin loading passengers". It reads
	--   that at EVERY stand, aligned or not — it is the game waiting for the
	--   door button, not the game accepting the stop. Taking "doors" in that
	--   string as proof of alignment is why a train stood at Westercoast with
	--   eight "Move forward until the train is fully alongside the platform."
	--   messages on screen while this block reported everything was fine and
	--   did nothing for the rest of the night.
	--
	--   THE DRIVER MESSAGES are the complaint, and they are the authority.
	--   But they are read on ChildAdded and never by sweeping labels: those
	--   eight messages stay on screen after the problem is fixed, so a sweep
	--   would keep asking for another roll forever. A timestamp cannot.
	--
	-- Alignment counts as accepted only when the doors are actually OPEN —
	-- loading, close the doors, ready to depart. That is the one state the
	-- game will not reach with the train in the wrong place.
	----------------------------------------------------------------------
	local forwardAt   = -math.huge   -- when SCR last asked for more forward
	local FORWARD_WIN = 20           -- s a complaint stands for
	local ROLL_QUIET  = 4            -- s of silence that ends a roll

	task.spawn(function()
		local hooked = nil
		while true do
			local gui = driveGui()
			local box = gui and descend(gui, MSG_PATH)
			if box and box ~= hooked then
				hooked = box
				box.ChildAdded:Connect(function(child)
					local ok, txt = pcall(function()
						local lbl = child:FindFirstChildWhichIsA("TextLabel", true)
						return lbl and lbl.Text or child.Name
					end)
					if ok and txt then
						local t = tostring(txt):lower()
						if t:find("move forward") or t:find("fully alongside")
							or t:find("alongside the platform") then
							forwardAt = os.clock()
						end
					end
				end)
			end
			task.wait(5)
		end
	end)

	local function askingForward(window)
		return (os.clock() - forwardAt) < (window or FORWARD_WIN)
	end

	local function bannerText()
		local gui = driveGui()
		local banner = gui and descend(gui, BANNER_PATH)
		if not banner or not onScreen(banner) then return nil end
		local ok, bt = pcall(function()
			if banner:IsA("TextLabel") then return banner.Text end
			local lbl = banner:FindFirstChildWhichIsA("TextLabel", true)
			return lbl and lbl.Text or nil
		end)
		if not ok or not bt then return nil end
		return tostring(bt):lower()
	end

	-- Doors actually open, as against the game asking us to open them.
	-- "Unlock doors to begin loading passengers" contains both "doors" and
	-- "loading" and means neither, so that word is checked first.
	local function doorsOpen(bs)
		if not bs then return false end
		if bs:find("unlock") then return false end
		return (bs:find("loading") ~= nil) or (bs:find("doors are open") ~= nil)
			or (bs:find("close the doors") ~= nil)
			or (bs:find("ready to depart") ~= nil)
	end

	local promptAt, promptState = -math.huge, "unknown"

	local function readPrompt()
		if (os.clock() - promptAt) < 0.2 then return promptState end
		local bs = bannerText()
		local state
		if doorsOpen(bs) then
			state = "aligned"
		elseif askingForward() then
			state = "forward"
		elseif bs and bs:find("alongside") then
			state = "stop"
		else
			state = "unknown"
		end
		promptAt, promptState = os.clock(), state
		return state
	end

	----------------------------------------------------------------------
	-- POSITION
	----------------------------------------------------------------------
	local function here()
		local cam = workspace.CurrentCamera
		if cam then
			local ok, p = pcall(function() return cam.Focus.Position end)
			if ok and p then return p end
		end
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		return root and root.Position or nil
	end

	-- Stationary is measured from where the train actually IS. A settle
	-- routine that gives up after N seconds reports "stopped" for a train
	-- doing forty, which is what caused the overshoot.
	local stillFrom, stillSince, lastSample = nil, os.clock(), -math.huge

	local function trackStillness()
		local p = here()
		if not p then return end            -- no reading: lastSample goes stale
		lastSample = os.clock()
		if not stillFrom or (p - stillFrom).Magnitude > STILL_STUDS then
			stillFrom, stillSince = p, os.clock()
		end
	end

	-- "Stopped" has to mean "I have been watching, and it has not moved".
	-- Without the freshness check a GAP in sampling reads identically to a
	-- stationary train, because stillSince simply never advances — and the
	-- gaps are real: a respawn makes here() nil, and scanWorld's
	-- GetDescendants() over the whole SCR map is a multi-second freeze.
	-- A moving train that reads as stopped is how this block drove one
	-- through a platform once already.
	local function isStopped()
		if stillFrom == nil then return false end
		if (os.clock() - lastSample) > 1.0 then return false end
		return (os.clock() - stillSince) >= STILL_FOR
	end

	local travelDir, travelFrom = nil, nil

	local function updateTravel()
		local p = here()
		if not p then return end
		if travelFrom then
			local d = p - travelFrom
			if d.Magnitude > 6 then travelDir, travelFrom = d.Unit, p end
		else
			travelFrom = p
		end
	end

	local function facing()
		if travelDir then return travelDir end
		local cam = workspace.CurrentCamera
		if cam then
			local ok, v = pcall(function() return cam.CFrame.LookVector end)
			if ok and v then return v end
		end
		return Vector3.new(0, 0, -1)
	end

	----------------------------------------------------------------------
	-- THE NOTCH — driven directly, so nothing can strand a half-finished ramp
	----------------------------------------------------------------------
	local keyDown, keySince, keyPause, lastHave, frozenSince = nil, 0, 0, nil, 0

	local function hold(k)
		if keyDown == k then return end
		if keyDown then
			pcall(function() VIM:SendKeyEvent(false, keyDown, false, nil) end)
		end
		keyDown = k
		if k then
			keySince, frozenSince = os.clock(), os.clock()
			pcall(function() VIM:SendKeyEvent(true, k, false, nil) end)
		end
	end

	local function releaseKeys()
		keyDown, keyPause, lastHave = nil, 0, nil
		pcall(function()
			VIM:SendKeyEvent(false, Enum.KeyCode.W, false, nil)
			VIM:SendKeyEvent(false, Enum.KeyCode.S, false, nil)
		end)
	end

	local function repress()
		local k = keyDown
		if not k then return end
		frozenSince = os.clock()
		pcall(function()
			VIM:SendKeyEvent(false, k, false, nil)
			VIM:SendKeyEvent(true, k, false, nil)
		end)
	end

	local function pump(want)
		local now = os.clock()
		if keyDown and (now - keySince) > MAX_HOLD then
			hold(nil)
			keyPause = now
		end
		if (now - keyPause) < HOLD_REST then return end

		local have = notchMph()
		if have == nil then
			if want <= 0 then hold(Enum.KeyCode.S) else hold(nil) end
			return
		end

		if keyDown and lastHave and math.abs(have - lastHave) > 0.2 then
			frozenSince = now
		end
		lastHave = have
		if keyDown and (now - frozenSince) > 0.6 then repress() end

		local err = want - have
		if keyDown == Enum.KeyCode.W then
			if err <= 0 then hold(nil) else hold(Enum.KeyCode.W) end
		elseif keyDown == Enum.KeyCode.S then
			if err >= 0 then hold(nil) else hold(Enum.KeyCode.S) end
		else
			if err >= START_BAND then
				hold(Enum.KeyCode.W)
			elseif err <= -START_BAND then
				hold(Enum.KeyCode.S)
			end
		end
	end

	-- Winds the notch down to zero AND waits for the train to stand.
	--
	-- Both halves matter. pump(0) with W held only RELEASES W — it does not
	-- press S — so on the first iteration the notch is still wherever the
	-- roll left it while keyDown is already nil and the train has not moved
	-- yet, which reads as "stopped, nothing held, done". That exit leaves
	-- the throttle open and the train pulls out of the platform by itself.
	-- So the notch has to be confirmed at zero, not merely unattended.
	local function brakeToStand()
		local t0 = os.clock()
		while os.clock() - t0 < SETTLE_LIMIT do
			pump(0)
			trackStillness()
			local have = notchMph()
			local shut = (have ~= nil) and (have <= START_BAND)
			if shut and isStopped() and keyDown == nil then return true end
			task.wait(0.1)
		end
		-- Out of time: put the notch down regardless of what the indicator
		-- says, because a readable zero is not worth more than a held brake.
		pcall(function()
			VIM:SendKeyEvent(false, Enum.KeyCode.W, false, nil)
			VIM:SendKeyEvent(true, Enum.KeyCode.S, false, nil)
			task.wait(1.5)
			VIM:SendKeyEvent(false, Enum.KeyCode.S, false, nil)
		end)
		keyDown = nil
		return isStopped()
	end

	----------------------------------------------------------------------
	-- CAR-STOP BOARDS
	--
	-- Strict parsing only. A board reading "S", "S HST" or "9 10 Class 80x"
	-- must come back as "not a plain car count" rather than be squeezed into
	-- one, because acting on a misread board means driving to the wrong place.
	----------------------------------------------------------------------
	local function parseRange(txt)
		local s = tostring(txt):gsub("%s+", "")
		if s == "" then return nil end
		local lo, hi = s:match("^(%d+)%-(%d+)$")
		if not lo then lo, hi = s:match("^(%d+)\226\128\147(%d+)$") end
		if lo then
			local a, b = tonumber(lo), tonumber(hi)
			if a and b and a >= 1 and b <= 16 and a <= b then return a, b end
			return nil
		end
		local one = s:match("^(%d+)$")
		if one then
			local n = tonumber(one)
			if n and n >= 1 and n <= 16 then return n, n end
		end
		return nil
	end

	local function anchorOf(inst)
		local n = inst
		while n and n ~= workspace do
			if n:IsA("BasePart") then return n.Position end
			if n:IsA("Model") then
				local ok, cf = pcall(function() return n:GetPivot() end)
				if ok and cf then return cf.Position end
			end
			n = n.Parent
		end
		return nil
	end

	local function scanWorld(force)
		local now = os.clock()
		if not force and (now - lastScan) < RESCAN_GAP then return end
		lastScan = now
		scanCount = scanCount + 1

		local found, scanned = {}, 0
		local ok = pcall(function()
			for _, inst in ipairs(workspace:GetDescendants()) do
				scanned = scanned + 1
				if scanned > SCAN_CAP then break end

				if inst:IsA("TextLabel") or inst:IsA("TextBox") then
					local ok2, t = pcall(function() return inst.Text end)
					if ok2 and t then
						local s = tostring(t):lower()
						if s:find("car stop") or s:find("carstop") then
							-- The caption. Its siblings carry what the board says.
							local par = inst.Parent
							if par then
								for _, sib in ipairs(par:GetChildren()) do
									if sib ~= inst and (sib:IsA("TextLabel") or sib:IsA("TextBox")) then
										local ok3, st = pcall(function() return sib.Text end)
										if ok3 and st and tostring(st):match("%S") then
											local p = anchorOf(sib)
											if p then
												local a, b = parseRange(st)
												found[#found + 1] = {
													pos = p,
													lo = a, hi = b,
													tag = (tostring(st):gsub("%s+", " ")),
													usable = (a ~= nil),
												}
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end)

		if ok then
			markers = found
			local usable = 0
			for _, m in ipairs(found) do if m.usable then usable = usable + 1 end end
			log("scan #%.0f — %.0f instance(s), %.0f board(s), %.0f with a plain car count",
				scanCount, scanned, #found, usable)
		else
			log("world scan failed")
		end
	end

	local function carsNow()
		return tonumber(carsAuto) or tonumber(CARS) or 3
	end

	local function pickMarker()
		local origin = here()
		if not origin then return nil, nil, "no position" end

		local dir = facing()
		local n   = carsNow()
		local best, bestAhead = nil, math.huge
		local nBehind, nFar, nSide, nRange, nUnreadable = 0, 0, 0, 0, 0

		for _, m in ipairs(markers) do
			local rel     = m.pos - origin
			local ahead   = rel:Dot(dir)
			local lateral = (rel - dir * ahead).Magnitude

			if not m.usable then
				nUnreadable = nUnreadable + 1
			elseif ahead < AHEAD_MIN then
				nBehind = nBehind + 1
			elseif ahead > AHEAD_MAX then
				nFar = nFar + 1
			elseif lateral > SIDE_MAX then
				nSide = nSide + 1
			elseif n < m.lo or n > m.hi then
				nRange = nRange + 1
			elseif ahead < bestAhead then
				best, bestAhead = m, ahead
			end
		end

		local why = ("%.0f board(s): %.0f not a plain car count, %.0f behind, " ..
			"%.0f too far, %.0f off to the side, %.0f not rated for %.0f cars")
			:format(#markers, nUnreadable, nBehind, nFar, nSide, nRange, n)

		return best, bestAhead, why
	end

	----------------------------------------------------------------------
	-- WHO ELSE HAS THE TRAIN
	--
	-- This has to be declared ABOVE rollForward. It used to sit below the
	-- install section, which meant the call inside rollForward compiled as a
	-- global lookup, resolved to nil, and threw "attempt to call a nil value"
	-- on the first tick of every roll — caught by the pcall around runArrival,
	-- so the only symptom was "[platform] arrival failed" and a block that
	-- had never once aligned a train.
	----------------------------------------------------------------------
	local function bufferBusy()
		for _, name in ipairs({ "SCRBuffer" }) do
			local api = _G[name]
			if api and api.busy then
				local ok, busy = pcall(api.busy)
				if ok and busy then return true end
			end
		end
		return false
	end

	----------------------------------------------------------------------
	-- THE ROLL
	--
	-- The only thing in this block that moves the train. Bounded three ways:
	-- distance from where it started, wall-clock time, and the platform
	-- still being the platform. It refuses outright to start on a train that
	-- is not already at a stand.
	----------------------------------------------------------------------
	local function rollForward(reason, targetPos)
		if not isStopped() then
			log("refusing to roll — the train is still moving")
			return false
		end

		local origin = here()
		if not origin then return false end

		rolls = rolls + 1
		log("rolling forward at %.0f mph (%s)", ROLL_SPEED, reason)

		local t0     = os.clock()
		local speed  = ROLL_SPEED
		-- The loop breaks when the budget is REACHED and then still has to
		-- stop, so the real distance travelled overruns by the stopping
		-- distance. Take that off up front and MAX_TRAVEL is a ceiling on
		-- where the train ends up, which is what the header claims.
		local budget = MAX_TRAVEL - 20
		if targetPos then
			local d = (targetPos - origin).Magnitude
			if d + 10 < budget then budget = d + 10 end
		end
		if budget < 15 then budget = 15 end

		local nudgeFrom, nudgeSince = origin, os.clock()
		local why = "time limit"

		while true do
			if os.clock() - t0 > ROLL_LIMIT then break end

			if readPrompt() == "aligned" then why = "the doors opened" break end
			if not askingForward(ROLL_QUIET) then
				why = "SCR stopped asking"
				break
			end

			local stopMi = nextStopMiles()
			if stopMi ~= nil and stopMi ~= 0 then why = "platform is behind us" break end

			-- Checked every tick, not just at the start. The buffer approach
			-- can wake up mid-roll — it has its own retry that re-runs b() —
			-- and two blocks driving the same two keys with their own idea of
			-- what the notch should be is worse than either one alone.
			if bufferBusy() then why = "another block took the train" break end

			local p = here()
			if not p then why = "lost position" break end

			local gone = (p - origin).Magnitude
			if gone >= budget then
				why = ("travel budget of %.0f studs"):format(budget)
				break
			end

			if targetPos and (p - targetPos).Magnitude <= 6 then
				why = "reached the board"
				break
			end

			-- It is not budging: ask for a little more, within the cap.
			if (p - nudgeFrom).Magnitude > 1.5 then
				nudgeFrom, nudgeSince = p, os.clock()
			elseif os.clock() - nudgeSince > 5 and speed < ROLL_MAX then
				speed = speed + 1
				nudgeSince = os.clock()
			end

			pump(speed)
			task.wait(0.05)
		end

		brakeToStand()
		log("roll ended — %s", why)

		local w = os.clock()
		while os.clock() - w < PROMPT_WAIT do
			if readPrompt() == "aligned" then break end
			pump(0)
			task.wait(0.1)
		end

		-- Success is the doors opening, or SCR having gone quiet. A roll that
		-- ran its budget out with the complaint still coming is a failure and
		-- has to read as one.
		return (readPrompt() == "aligned") or (not askingForward(ROLL_QUIET))
	end

	----------------------------------------------------------------------
	-- THE ARRIVAL
	----------------------------------------------------------------------
	local function runArrival(key)
		releaseKeys()

		local target1, why = nil, nil
		if USE_MARKERS then
			scanWorld(true)
			do
				local p = here()
				if p then
					local near = {}
					for _, m in ipairs(markers) do
						if (m.pos - p).Magnitude <= KEEP_RADIUS then near[#near + 1] = m end
					end
					markers = near
				end
			end
			local m, ahead
			m, ahead, why = pickMarker()
			if m then
				target1 = m.pos
				log("board \"%s\" is %.0f studs ahead", tostring(m.tag), ahead or -1)
			else
				log("no board taken — %s", tostring(why))
			end
		end

		local ok
		if target1 then
			ok = rollForward("driving to the board", target1)
		elseif readPrompt() == "forward" then
			ok = rollForward("SCR wants the train further forward", nil)
		else
			ok = (readPrompt() == "aligned")
		end

		if ok then
			alignedOk = alignedOk + 1
			lastLine = ("aligned at %s"):format(key or "unknown")
		else
			missed = missed + 1
			lastLine = ("still not aligned at %s"):format(key or "unknown")
			warn("[platform] " .. lastLine .. " — run _G.SCRPlatform.probe() and send it to me.")
		end
		log(lastLine)

		releaseKeys()
		return true
	end

	----------------------------------------------------------------------
	-- INSTALL
	----------------------------------------------------------------------
	local function install()
		realTarget = target

		-- While we own the train nothing else may command a speed. We do NOT
		-- hijack b()'s stop any more: braking from line speed belongs to the
		-- original, and taking a moving train was what caused the overshoot.
		target = function(speed)
			if owning then return end
			return realTarget(speed)
		end

		task.spawn(function()
			while true do
				pcall(trackStillness)
				pcall(updateTravel)
				task.wait(0.25)
			end
		end)

		-- The trigger. Every condition here has to hold: at a platform, at a
		-- stand, not the buffer approach's business, and something actually
		-- to fix.
		task.spawn(function()
			while true do
				task.wait(0.5)
				if ENABLED and not owning and installed then
					local ok = pcall(function()
						if bufferBusy() then return end
						local stopMi = nextStopMiles()
						if stopMi ~= 0 then return end
						if not isStopped() then return end

						local state = readPrompt()
						if state == "aligned" then return end

						local key = stationKey()

						-- BOTH keys must be real to count as a different
						-- station. stationKey() reads nil whenever the
						-- schedule panel is momentarily unresolvable, which
						-- is common right around an arrival, and a nil/key
						-- alternation would otherwise pass this test every
						-- other tick and roll again immediately.
						local fresh = (os.clock() - settledAt) >= RESTART_LOCK
							or (key ~= nil and settledKey ~= nil and key ~= settledKey)
						if not fresh then return end

						-- However many times SCR asks, there is a limit to
						-- how far forward the answer can be. Without this the
						-- block rolls another MAX_TRAVEL studs every
						-- RESTART_LOCK seconds for as long as the prompt
						-- stands.
						if key ~= nil and key == rollKey and rollCount >= MAX_ROLLS then
							return
						end

						-- "unknown" is the ordinary state at a perfectly good
						-- stop whose banner this does not recognise, so it
						-- never counts as a reason to move — not even with
						-- boards on, where it would otherwise drive a
						-- correctly-stopped train off to a board.
						local worthIt = (state == "forward")
							or (USE_MARKERS and state == "stop")
						if not worthIt then return end

						if key ~= rollKey then rollKey, rollCount = key, 0 end
						rollCount = rollCount + 1

						owning = true
						task.spawn(function()
							local ok2, err = pcall(runArrival, key)
							if not ok2 then
								warn("[platform] arrival failed: " .. tostring(err))
								pcall(releaseKeys)
							end
							settledAt = os.clock()
							if key ~= nil then settledKey = key end
							owning = false
						end)
					end)
					if not ok then owning = false end
				end
			end
		end)

		task.spawn(function()
			task.wait(3)
			pcall(function()
				local char = player.Character
				local hum  = char and char:FindFirstChildOfClass("Humanoid")
				local seat = hum and hum.SeatPart
				if not seat then return end
				local unit = seat
				for _ = 1, 6 do
					if unit.Parent and unit.Parent ~= workspace then unit = unit.Parent else break end
				end
				local n = 0
				for _, c in ipairs(unit:GetChildren()) do
					if c:IsA("Model") then n = n + 1 end
				end
				if n >= 1 and n <= 16 then
					carsAuto = n
					log("train looks like %.0f car(s) — override with _G.SCRPlatform.setCars(n)", n)
				end
			end)
		end)

		_G.SCRPlatform = {
			busy = function()
				return owning or (os.clock() - settledAt) < GRACE
			end,

			markers = function(on)
				USE_MARKERS = on and true or false
				log("car-stop boards %s", USE_MARKERS and "ON" or "off")
				return USE_MARKERS
			end,

			setCars = function(n)
				local v = tonumber(n)
				v = v and math.floor(v) or nil
				if not v or v < 1 or v > 16 then
					warn("[platform] usage: _G.SCRPlatform.setCars(3)")
					return false
				end
				CARS, carsAuto = v, v
				log("train length set to %.0f car(s)", v)
				return true
			end,

			align = function()
				if owning then return false end
				if bufferBusy() then
					warn("[platform] another block has the train — not rolling")
					return false
				end
				owning = true
				local ok, res = pcall(rollForward, "asked by hand", nil)
				-- Always put the keys back, and always claim the station, or
				-- the monitor sees a different key half a second later and
				-- starts its own roll on top of this one.
				pcall(releaseKeys)
				settledAt = os.clock()
				local k = stationKey()
				if k ~= nil then settledKey = k end
				owning = false
				if not ok then
					warn("[platform] manual align failed: " .. tostring(res))
					return false
				end
				return res and true or false
			end,

			probe = function()
				scanWorld(true)
				local origin, dir = here(), facing()
				print(("[platform] %.0f board(s) | train %.0f car(s) | prompt: %s | stopped: %s")
					:format(#markers, carsNow(), readPrompt(), tostring(isStopped())))
				if not origin then print("[platform] no position") return end

				local rows = {}
				for _, m in ipairs(markers) do
					local rel     = m.pos - origin
					local ahead   = rel:Dot(dir)
					local lateral = (rel - dir * ahead).Magnitude
					if math.abs(ahead) <= 600 and lateral <= 150 then
						rows[#rows + 1] = { m = m, ahead = ahead, lateral = lateral }
					end
				end
				table.sort(rows, function(a, b) return math.abs(a.ahead) < math.abs(b.ahead) end)

				for i = 1, math.min(#rows, 25) do
					local r = rows[i]
					print(("[platform]  %-16s  ahead %7.1f  side %6.1f  %s")
						:format('"' .. tostring(r.m.tag) .. '"', r.ahead, r.lateral,
							r.m.usable and ("cars " .. tostring(r.m.lo) .. "-" .. tostring(r.m.hi))
							or "NOT a plain car count"))
				end
				if #rows == 0 then
					print("[platform] no boards in range — they may not be text objects")
				end
				local pick, ah, why = pickMarker()
				print(("[platform] would drive to: %s"):format(
					pick and ('"' .. tostring(pick.tag) .. '" ' .. ("%.0f studs ahead"):format(ah or -1))
					or ("nothing — " .. tostring(why))))
				print(("[platform] board-seeking is %s"):format(USE_MARKERS and "ON" or "OFF"))
			end,

			enable  = function() ENABLED = true  ; log("armed") end,
			disable = function() ENABLED = false ; log("off") end,

			status = function()
				return ("[platform] %s | boards %s | %.0f roll(s), %.0f aligned, %.0f missed | " ..
				        "%.0f board(s) cached | %.0f car(s) | stopped: %s\n           last: %s")
					:format(installed and (ENABLED and "armed" or "disabled") or "NOT installed",
						USE_MARKERS and "ON" or "off",
						rolls, alignedOk, missed, #markers, carsNow(),
						tostring(isStopped()), lastLine)
			end,
		}

		installed = true
		log("armed — forward roll only, max %.0f studs, and never on a moving train",
			MAX_TRAVEL)
	end

	task.spawn(function()
		local t0 = os.clock()
		repeat
			task.wait(0.1)
		until (_G.SCRStop and _G.SCRWhite and type(target) == "function")
			or (os.clock() - t0 > 38)

		if type(target) == "function" then
			install()
		else
			warn("[platform] target() never appeared — platform alignment is NOT active.")
		end
	end)
end
-- ================== END PLATFORM ALIGNMENT ==============================
--[[ ======================================================================
     LONGEVITY  —  self-contained add-on for overnight / multi-hour shifts.

     Four things that only go wrong once a run has been going for hours:

       1. PRINT THROTTLE. The original prints on nearly every signal read and
          distance tick. Over eight hours that is hundreds of thousands of
          console lines, and executors that keep unbounded history will chew
          memory and start to stutter. Identical lines inside a short window
          collapse into one. warn() is left alone so real problems still show.

       2. HEARTBEAT. Detects "commanded to move, but not actually moving".
          Movement is measured from the character's position, not from any
          HUD label, so it cannot be fooled by a stale or misread readout.
          A stop at a station or a red signal commands 0 mph, so those are
          not flagged — only the states nothing else notices.

       3. DEFIBRILLATOR. Releases W and S and re-runs the original's b() —
          on a long timer, and on demand when the heartbeat says stuck. This
          clears a latched key and re-derives the correct speed from scratch.

       4. REBIND. If the DriveGui is ever rebuilt (respawn, leaving the cab),
          every one of the original's cached references dies and the whole
          script silently stops driving. This detects that, calls SCR_BindHUD()
          to re-resolve them, and reconnects b / under / clockTick to the new
          objects.

     Needs the patched original (SCR_BindHUD and clockTick). Everything else
     degrades gracefully and says so.

       _G.SCRLong.status()   -- uptime, last movement, suppressed lines
       _G.SCRLong.defib()    -- force one now
       _G.SCRLong.rebind()   -- force a rebind now
====================================================================== ]]
do
	----------------------------------------------------------------------
	local THROTTLE          = true
	local THROTTLE_WINDOW   = 3.0    -- identical line within this = dropped
	local THROTTLE_PURGE    = 60     -- clear the seen-table this often

	local HEARTBEAT         = true
	local HB_INTERVAL       = 5      -- how often to sample position
	local HB_MOVE_STUDS     = 8      -- less than this = "not moving"
	local HB_STUCK_AFTER    = 60     -- s commanded-but-stationary before acting
	local HB_MIN_MPH        = 3      -- commanded speed that counts as "should move"

	local DEFIB             = true
	local DEFIB_INTERVAL    = 900    -- routine defib every 15 min
	local DEFIB_COOLDOWN    = 120    -- never two defibs closer than this

	local REBIND            = true
	local REBIND_CHECK      = 5

	local REPORT_INTERVAL   = 1800   -- console status line every 30 min
	----------------------------------------------------------------------

	local Players = game:GetService("Players")
	local VIM     = game:GetService("VirtualInputManager")
	local player  = Players.LocalPlayer

	local realPrint = print
	local realWarn  = warn

	local startTime   = os.clock()
	local suppressed  = 0
	local defibs      = 0
	local rebinds     = 0
	local stuckEvents = 0
	local lastDefib   = -math.huge
	local lastMoved   = os.clock()

	local function log(fmt, ...)
		realPrint("[long] " .. (select("#", ...) > 0 and fmt:format(...) or fmt))
	end

	local function hhmm(sec)
		return ("%dh%02dm"):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
	end

	----------------------------------------------------------------------
	-- 1. PRINT THROTTLE
	----------------------------------------------------------------------
	if THROTTLE then
		local seen, lastPurge = {}, os.clock()
		print = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				parts[i] = tostring((select(i, ...)))
			end
			local msg = table.concat(parts, " ")
			local now = os.clock()

			if now - lastPurge > THROTTLE_PURGE then
				seen, lastPurge = {}, now
			end

			local last = seen[msg]
			if last and (now - last) < THROTTLE_WINDOW then
				suppressed = suppressed + 1
				return
			end
			seen[msg] = now
			return realPrint(...)
		end
		log("print throttle on — identical lines collapsed within %.0fs", THROTTLE_WINDOW)
	end

	----------------------------------------------------------------------
	-- SENSORS (resolved independently of the original's locals)
	----------------------------------------------------------------------
	local function driveGui()
		local pg = player:FindFirstChild("PlayerGui")
		return pg and pg:FindFirstChild("DriveGui") or nil
	end

	local function descend(root, path)
		local node = root
		for _, name in ipairs(path) do
			if not node then return nil end
			node = node:FindFirstChild(name)
		end
		return node
	end

	-- Where the train physically is. Independent of every HUD label, so a
	-- misread or frozen readout cannot make a stopped train look like it is
	-- moving.
	local function position()
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then return root.Position end
		local cam = workspace.CurrentCamera
		return cam and cam.Focus.Position or nil
	end

	-- Commanded notch, read off the same indicator the original drives.
	-- Mirrors its speed_angle(): rotation = mph * 1.2 - 31.
	local function commandedMph()
		local gui = driveGui()
		local a = gui and descend(gui, { "Cluster", "Spedometer", "TargetIndicator" })
		if not a then return nil end
		local ok, rot = pcall(function() return a.Rotation end)
		if not ok then return nil end
		return (rot + 31) / 1.2
	end

	----------------------------------------------------------------------
	-- 3. DEFIBRILLATOR
	----------------------------------------------------------------------
	-- The buffer approach drives a braking curve it computed itself. A defib
	-- in the middle of that releases the brake and re-derives a speed from
	-- the HUD, which is exactly the wrong thing a few studs from a buffer.
	local function approachBusy()
		for _, name in ipairs({ "SCRBuffer" }) do
			local api = _G[name]
			if api and api.busy then
				local ok, busy = pcall(api.busy)
				if ok and busy then return true end
			end
		end
		return false
	end

	local function defib(why)
		local now = os.clock()
		if approachBusy() then
			log("defib (%s) held off — buffer approach is driving", why)
			return false
		end
		if now - lastDefib < DEFIB_COOLDOWN then return false end
		lastDefib = now
		defibs = defibs + 1

		pcall(function()
			VIM:SendKeyEvent(false, Enum.KeyCode.W, false, nil)
			VIM:SendKeyEvent(false, Enum.KeyCode.S, false, nil)
		end)

		-- Let the re-derived speed through the dedupe guard; re-asserting
		-- the same speed is exactly what a defib is for.
		if _G.SCRFix and _G.SCRFix.resetDedupe then
			pcall(_G.SCRFix.resetDedupe)
		end

		task.wait(0.2)
		if type(b) == "function" then
			local ok, err = pcall(b)
			log("defib #%d (%s): keys released, b() %s", defibs, why,
				ok and "re-run" or ("failed — " .. tostring(err)))
		else
			log("defib #%d (%s): keys released, no b() to re-run", defibs, why)
		end
		return true
	end

	----------------------------------------------------------------------
	-- 4. REBIND
	----------------------------------------------------------------------
	local myConns = {}

	local function rebind()
		if type(SCR_BindHUD) ~= "function" then
			realWarn("[long] SCR_BindHUD missing — running the unpatched original? " ..
			         "Cannot recover from a HUD rebuild.")
			return false
		end

		local ok, err = pcall(SCR_BindHUD)
		if not ok then
			realWarn("[long] rebind failed: " .. tostring(err))
			return false
		end

		for _, c in ipairs(myConns) do pcall(function() c:Disconnect() end) end
		myConns = {}

		local gui = driveGui()
		if not gui then return false end

		local function hook(node, signal, handler, label)
			if not (node and type(handler) == "function") then
				realWarn("[long] could not reconnect " .. label)
				return
			end
			local sig = (signal == "ChildAdded") and node.ChildAdded
				or node:GetPropertyChangedSignal("Text")
			myConns[#myConns + 1] = sig:Connect(handler)
		end

		hook(descend(gui, { "Additional", "DetailsStack", "AdvanceContainer", "Main",
		                    "ScheduleDetails", "Counters", "Distance" }), "Text", b, "distance")
		hook(descend(gui, { "Additional", "DetailsStack", "AdvanceContainer",
		                    "Signal", "Distance" }), "Text", b, "signal distance")
		hook(descend(gui, { "Cluster", "Stats", "CurrentState", "SpeedLimit",
		                    "Limit" }), "Text", b, "speed limit")
		hook(descend(gui, { "Additional", "DetailsStack", "MessageContainer" }),
		     "ChildAdded", under, "driver messages")
		hook(descend(gui, { "Clock", "TextLabel" }), "Text", clockTick, "clock")

		rebinds = rebinds + 1
		log("rebind #%d complete — %d handler(s) reconnected", rebinds, #myConns)
		task.spawn(function() task.wait(1) ; defib("after rebind") end)
		return true
	end

	if REBIND then
		task.spawn(function()
			local known = nil
			while true do
				task.wait(REBIND_CHECK)
				local gui = driveGui()
				if gui and known and gui ~= known then
					log("DriveGui was rebuilt — the original's references are stale")
					rebind()
					known = gui
				elseif known and not known.Parent and gui then
					log("DriveGui lost its parent — rebinding")
					rebind()
					known = gui
				elseif gui and not known then
					known = gui
				end
			end
		end)
	end

	----------------------------------------------------------------------
	-- 2. HEARTBEAT
	----------------------------------------------------------------------
	if HEARTBEAT then
		task.spawn(function()
			local anchor = position()
			while true do
				task.wait(HB_INTERVAL)
				local pos = position()
				if pos then
					if not anchor or (pos - anchor).Magnitude > HB_MOVE_STUDS then
						anchor, lastMoved = pos, os.clock()
					end
				end

				local mph  = commandedMph()
				local idle = os.clock() - lastMoved

				if mph and mph > HB_MIN_MPH and idle > HB_STUCK_AFTER
					and not approachBusy() then
					stuckEvents = stuckEvents + 1
					realWarn(("[long] STUCK — %d mph commanded but no movement for %ds")
						:format(math.floor(mph + 0.5), math.floor(idle)))
					if DEFIB then defib("heartbeat stuck") end
					lastMoved = os.clock()  -- don't re-fire every interval
				end
			end
		end)
	end

	----------------------------------------------------------------------
	-- ROUTINE DEFIB + PERIODIC REPORT
	----------------------------------------------------------------------
	if DEFIB then
		task.spawn(function()
			while true do
				task.wait(DEFIB_INTERVAL)
				defib("routine")
			end
		end)
	end

	task.spawn(function()
		while true do
			task.wait(REPORT_INTERVAL)
			local mph = commandedMph()
			log("uptime %s | %d mph commanded | moved %ds ago | %d defib(s), %d stuck, %d rebind(s) | %d lines suppressed",
				hhmm(os.clock() - startTime),
				mph and math.floor(mph + 0.5) or -1,
				math.floor(os.clock() - lastMoved),
				defibs, stuckEvents, rebinds, suppressed)
		end
	end)

	_G.SCRLong = {
		defib  = function() lastDefib = -math.huge ; return defib("manual") end,
		rebind = function() return rebind() end,
		status = function()
			local mph = commandedMph()
			return ("[long] up %s | %d mph commanded | last moved %ds ago | %d defib(s) | %d stuck | %d rebind(s) | %d lines suppressed")
				:format(hhmm(os.clock() - startTime),
					mph and math.floor(mph + 0.5) or -1,
					math.floor(os.clock() - lastMoved),
					defibs, stuckEvents, rebinds, suppressed)
		end,
	}

	log("longevity guards armed")
end
-- ================== END LONGEVITY =======================================


--[[ ======================================================================
     AUTO NEXT LEG  —  self-contained add-on, sits above the original script.

     At the end of a schedule the game shows the Schedule Summary screen with
     Quit to Menu / Change Route / Next Leg. This block waits for that screen,
     clicks Next Leg, and lets the autopilot below carry on with the new leg.

     The original script already binds this button —
         local nl = drive.Summary.SummaryPage.Controls.NextLeg
     — and has a commented-out `--clickButton(nl)` where the click was meant
     to go, but clickButton was never written. This is that missing piece,
     kept outside the original so nothing in it has to change.

     Scoped inside `do ... end`: no globals except `_G.AutoNextLeg`. It sends
     no keystrokes, so it can never fight `target()` for W and S. The only
     input it produces is one left-click on that one button.

       _G.AutoNextLeg.click()    -- click it right now, by hand
       _G.AutoNextLeg.status()   -- armed? how many legs advanced?
       _G.AutoNextLeg.disable()  -- stop watching (and .enable() again)
====================================================================== ]]
do
	local ENABLED     = true   -- master switch
	local CLICK_DELAY = 2.0    -- seconds to let the summary settle before clicking
	local POLL        = 0.5    -- how often to look for the summary screen
	local VERIFY_WAIT = 1.5    -- how long to wait to see if the click landed
	local ATTEMPTS    = 3      -- tries before giving up and telling you
	local KICK        = true   -- re-run the original's b() after the leg change,
	                           -- in case the new leg doesn't fire it on its own
	local KICK_WAIT   = 20.0   -- max seconds to wait for the new leg's distance
	                           -- to become non-zero before kicking
	local VERBOSE     = true

	local Players    = game:GetService("Players")
	local GuiService = game:GetService("GuiService")
	local VIM        = game:GetService("VirtualInputManager")
	local player     = Players.LocalPlayer

	local PATH = { "Summary", "SummaryPage", "Controls", "NextLeg" }

	local legs    = 0
	local enabled = ENABLED
	local busy    = false

	local function log(fmt, ...)
		if not VERBOSE then return end
		local body = select("#", ...) > 0 and fmt:format(...) or fmt
		print("[next-leg] " .. body)
	end

	-- Resolved fresh every poll rather than cached once. If SCR ever rebuilds
	-- the HUD between legs, a cached reference would go stale and this block
	-- would quietly stop working.
	local function findButton()
		local pg  = player:FindFirstChild("PlayerGui")
		local gui = pg and pg:FindFirstChild("DriveGui")
		if not gui then return nil end
		local node = gui
		for _, name in ipairs(PATH) do
			node = node:FindFirstChild(name)
			if not node then return nil end
		end
		return node:IsA("GuiButton") and node or nil
	end

	-- The original's own distance label, read independently of its locals.
	local DIST_PATH = { "Additional", "DetailsStack", "AdvanceContainer", "Main",
	                    "ScheduleDetails", "Counters", "Distance" }

	local function distanceMiles()
		local pg  = player:FindFirstChild("PlayerGui")
		local gui = pg and pg:FindFirstChild("DriveGui")
		if not gui then return nil end
		local node = gui
		for _, name in ipairs(DIST_PATH) do
			node = node:FindFirstChild(name)
			if not node then return nil end
		end
		local ok, txt = pcall(function() return node.Text end)
		if not ok then return nil end
		return tonumber(tostring(txt):match("%d+%.?%d*"))
	end

	local function layerOf(obj)
		local node = obj
		while node and node ~= game do
			if node:IsA("LayerCollector") then return node end
			node = node.Parent
		end
		return nil
	end

	-- Visible in its own right AND not hidden by any ancestor, on an enabled
	-- ScreenGui. A destroyed button has no parent chain, so this reads false —
	-- which is exactly what we want after a successful click.
	local function onScreen(obj)
		if not obj then return false end
		local node = obj
		while node and node ~= game do
			if node:IsA("LayerCollector") then return node.Enabled end
			if node:IsA("GuiObject") and not node.Visible then return false end
			node = node.Parent
		end
		return false
	end

	--------------------------------------------------------------------
	-- Click methods. Two of them, because either can fail on its own.
	--------------------------------------------------------------------

	-- A real synthetic mouse click at the button's centre. Same family of API
	-- the autopilot already uses for keys, so if keys work here, this should.
	local function virtualClick(btn)
		local pos, size = btn.AbsolutePosition, btn.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then return false, "button has zero size" end

		-- AbsolutePosition is measured from under the topbar unless the
		-- ScreenGui ignores the inset; mouse events are in real window pixels.
		-- Getting this wrong puts the click ~36px above the button.
		local ox, oy = 0, 0
		local layer = layerOf(btn)
		if layer and layer:IsA("ScreenGui") and not layer.IgnoreGuiInset then
			local inset = GuiService:GetGuiInset()
			ox, oy = inset.X, inset.Y
		end

		local x = math.floor(pos.X + size.X / 2 + ox)
		local y = math.floor(pos.Y + size.Y / 2 + oy)

		local ok, err = pcall(function()
			VIM:SendMouseMoveEvent(x, y, game)
			task.wait(0.05)
			VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
			task.wait(0.05)
			VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
		end)
		return ok, ok and ("mouse click at %d,%d"):format(x, y)
			or ("mouse click failed: " .. tostring(err))
	end

	-- Fallback: invoke the game's own click handlers directly. Doesn't care
	-- about cursor position, window focus or the inset maths — but needs an
	-- executor that exposes getconnections.
	local function fireHandlers(btn)
		if not getconnections then return false, "getconnections unavailable" end
		local ok, count = pcall(function()
			local n = 0
			for _, signal in ipairs({ btn.MouseButton1Click, btn.Activated }) do
				for _, conn in ipairs(getconnections(signal)) do
					if conn.Fire then
						pcall(function() conn:Fire() end)
						n = n + 1
					end
				end
			end
			return n
		end)
		if not ok then return false, "getconnections error: " .. tostring(count) end
		if count == 0 then return false, "no handlers connected to the button" end
		return true, ("fired %d handler(s) directly"):format(count)
	end

	--------------------------------------------------------------------
	-- Kick: nudge the autopilot if the new leg doesn't start it by itself.
	--------------------------------------------------------------------
	-- b() is the original's own re-evaluate-and-set-speed function. Calling it
	-- changes nothing about the original; normally the distance label changing
	-- fires it anyway, so this is just insurance for the case where it doesn't.
	-- Waits for the new leg to actually load before touching b().
	--
	-- This gate matters: b() reads the distance label, and while it still says
	-- 0.00 mi b() takes the "we have arrived" branch and starts creeping to the
	-- buffer of the leg we just finished. Kicking too early is what pinned the
	-- train at 15 mph. Only kick once a real distance is showing.
	local function kick()
		if type(b) ~= "function" then
			log("no b() to kick — autopilot will have to start itself")
			return
		end
		local t0 = os.clock()
		while os.clock() - t0 < KICK_WAIT do
			local mi = distanceMiles()
			if mi and mi > 0 then
				task.wait(0.5)
				local ok, err = pcall(b)
				log("kicked at %.2f mi to go: %s", mi, ok and "ok" or ("error — " .. tostring(err)))
				return
			end
			task.wait(0.5)
		end
		log("distance never became non-zero in %.0fs — skipping the kick", KICK_WAIT)
	end

	--------------------------------------------------------------------
	-- The actual sequence.
	--------------------------------------------------------------------
	local function advance(btn)
		if not btn then log("Next Leg button not found right now") return false end

		log("summary screen up — clicking Next Leg in %.1fs", CLICK_DELAY)
		task.wait(CLICK_DELAY)

		if not onScreen(btn) then
			log("summary closed on its own, nothing to do")
			return false
		end

		for attempt = 1, ATTEMPTS do
			-- Alternate methods: mouse, then handlers, then mouse again.
			local ok, how = (attempt == 2 and fireHandlers or virtualClick)(btn)
			log("attempt %d/%d — %s", attempt, ATTEMPTS, tostring(how))

			if ok then
				task.wait(VERIFY_WAIT)
				if not onScreen(btn) then
					legs = legs + 1
					log("accepted — leg %d starting", legs)

					-- Tell the creep guard the buffer we were approaching is
					-- now behind us, and drop any key a stranded target()
					-- thread left held down.
					if _G.SCRFix then
						pcall(_G.SCRFix.legChanged)
						-- Not while the buffer approach is driving: it holds
						-- W or S to move the notch, and yanking that key out
						-- from under it stalls the ramp mid-travel.
						local driving = false
						for _, nm in ipairs({ "SCRBuffer" }) do
							local api = _G[nm]
							if api and api.busy then
								local ok2, b2 = pcall(api.busy)
								if ok2 and b2 then driving = true end
							end
						end
						if not driving then pcall(_G.SCRFix.releaseKeys) end
					else
						warn("[next-leg] creep guard not installed — the 15 mph " ..
						     "buffer-creep bug is not protected against.")
					end

					if KICK then task.spawn(kick) end
					return true
				end
				log("summary still up, trying again")
			end
		end

		warn("[next-leg] could not dismiss the summary after " .. ATTEMPTS ..
		     " attempts — click Next Leg manually. Console above shows which methods failed.")
		return false
	end

	--------------------------------------------------------------------
	-- Watcher.
	--------------------------------------------------------------------
	task.spawn(function()
		while true do
			task.wait(POLL)
			if enabled and not busy then
				local btn = findButton()
				if onScreen(btn) then
					busy = true
					task.spawn(function()
						pcall(advance, btn)
						-- Don't re-arm until the screen is actually gone, so a
						-- failed click can't turn into a click every half second.
						repeat task.wait(1) until not onScreen(findButton())
						busy = false
					end)
				end
			end
		end
	end)

	_G.AutoNextLeg = {
		enable  = function() enabled = true;  log("enabled") end,
		disable = function() enabled = false; log("disabled") end,
		click   = function() return advance(findButton()) end,
		status  = function()
			local btn = findButton()
			return ("[next-leg] %s | button %s | summary %s | %d leg(s) advanced"):format(
				enabled and "armed" or "disabled",
				btn and "found" or "NOT FOUND",
				onScreen(btn) and "showing" or "hidden",
				legs)
		end,
	}

	log("armed — watching for the Schedule Summary every %.1fs", POLL)
end
-- ================== END AUTO NEXT LEG ==================================


--[[ ======================================================================
     TERMINAL BUFFER APPROACH  —  self-contained add-on, above the original.

     WHAT IT REPLACES
     ----------------
     The original ends a terminating leg with an open-loop guess:

         while getD(buf[st][plat]) >= BUFFERSTOP do
             cs:Fire(15)
             task.wait(0.1)
         end
         cs:Fire(0)

     One speed, 15 mph, held until a fixed 100-stud line is crossed, then a
     dead stop. If 100 studs is too far out for SCR to accept the trip you
     stop, nothing happens, you nudge forward, stop again, and repeat. That
     is the stop-start crawl this block gets rid of.

     WHAT IT DOES INSTEAD
     --------------------
     It reads the real distance to the buffer and steps the speed down a
     fixed ladder as it closes:

         700 studs out  35 mph        90  10
         500            30            45   7
         350            25            18   5
         240            20             0   3
         150            15        arrive   0

     A table rather than a formula, on purpose: a formula has to be trusted,
     a table can be read, argued with and edited. Two things still have to
     hold up in a game whose units nobody wrote down:

       * SPEED CALIBRATION. Nothing anywhere says how many studs per second
         one mph is. So it measures: closing speed divided by commanded mph,
         averaged over the run-in. The curve is in true studs from the first
         approach onward, and gets tighter every time.

       * STOP-POINT LEARNING. It does not have to guess how close SCR wants
         you. The Summary screen appearing IS the game accepting the stop, so
         it watches for that and records the distance it happened at, keyed by
         station and platform. Every later arrival there aims straight for
         that known-good spot.

     The first arrival at a new platform may still roll the last few studs —
     but as ONE slow continuous movement that stops the instant the trip is
     accepted, not a series of stops. After that the platform is learned and
     the whole thing is a single approach.

     DRIVING THE NOTCH DIRECTLY
     --------------------------
     The approach does not command speed through the original's target().
     That function holds a key and blocks until the notch arrives, and it
     abandons the ramp the moment anything else fires cs — which b() does
     constantly at a terminus. A call cut off half way leaves the notch
     stranded in between, and there is no way from outside to cancel it: it
     stays parked in its own loop and releases the key out from under
     whatever came next.

     Since the notch is only W and S against an indicator this block already
     reads, it drives it itself — hold a key until the notch crosses the value
     asked for, then let go. Nothing blocks and nothing needs cancelling, and
     a key stamped on by another part of the script shows up as a notch that
     has stopped moving, which it can see and press again.

     SAFETY
       * Hard floor in studs that it will not cross whatever the maths says,
         with the stopping distance of the current speed added on top.
       * Comes in at 35 and steps down a fixed distance ladder, and does NOT
         obey the line speed limit doing it — this is the run into the last
         station and the platform is the end of the line.
       * Reads SCR's driver messages rather than pattern-matching them.
         "Stop closer to the buffer to terminate" means come FORWARD and is
         acted on as such; only a message that actually warns about the
         buffer stops the train.
       * Never commands more than the line speed limit.
       * Aborts if the buffer starts receding — the post-Next-Leg case where
         the buffer it was handed is now behind the train.
       * Bounded everywhere: run-in, roll-in and every wait have a timeout,
         and it cannot hold the train past the end of an approach.

       _G.SCRBuffer.status()       -- what it has learned and done
       _G.SCRBuffer.probe()        -- distance to the last buffer, right now
       _G.SCRBuffer.set{...}       -- aim = 45, floor = 10, cap = 25, crawl = 3,
                                   -- closerFloor = 4
       _G.SCRBuffer.learned()      -- the per-platform stop points
       _G.SCRBuffer.forget()       -- drop everything learned
       _G.SCRBuffer.disable()      -- and .enable(); off = the original's creep
====================================================================== ]]
do
	----------------------------------------------------------------------
	local ENABLED       = true

	local AIM_DEFAULT   = 45     -- studs from the buffer to stop at, before
	                             -- anything has been learned
	local HARD_FLOOR    = 10     -- studs — never closer than this, ever
	local CLOSER_FLOOR  = 25     -- studs — the floor once SCR has ASKED us to
	                             -- come closer. Its complaint outranks our
	                             -- guess, but not by enough to reach the
	                             -- buffer: at Llyn a floor of 4 let the
	                             -- come-closer ratchet drive into it.
	local APPROACH_CAP  = 35     -- mph ceiling for the whole approach

	-- THE LADDER. Studs remaining to the aim point, and the speed to ask for
	-- at that distance. Read top down; the first row whose distance we are
	-- still outside of wins. Deliberately a table and not a formula: a
	-- formula has to be trusted, a table can be read, argued with and edited.
	--
	-- The gaps widen towards the top because the notch is a TARGET speed, not
	-- a brake demand — dropping from 35 to 30 applies the service brake until
	-- the train is at 30, and it needs room to get there. Braking early is
	-- free; braking late is a buffer strike.
	local LADDER = {
		{ 700, 35 },
		{ 500, 30 },
		{ 350, 25 },
		{ 240, 20 },
		{ 150, 15 },
		{  90, 10 },
		{  45,  7 },
		{  18,  5 },
		{   0,  3 },
	}
	local MIN_MOVE      = 3      -- mph — under this an SCR train will not roll
	local CRAWL_SPEED   = 3      -- mph for the find-the-line roll
	local CRAWL_MAX     = 6      -- mph — the roll never escalates past this

	local DECEL         = 3.2    -- studs/s^2, assumed service brake rate
	local SAFETY        = 0.75   -- the floor test plans for this fraction of it
	local K_DEFAULT     = 1.6    -- studs/s per mph, starting guess
	local K_MIN, K_MAX  = 0.4, 6.0

	local TICK          = 0.05
	-- One-sided hysteresis. The key goes down when the notch is off by
	-- START_BAND and comes back up the moment the notch CROSSES the value
	-- asked for — not when it is merely close. A symmetric tolerance would
	-- settle short on whichever side it came from, and short of MIN_MOVE is
	-- a train that does not move at all.
	local START_BAND    = 1.8    -- mph off before a key goes down
	local ARRIVE_BAND   = 5      -- studs — inside this, command 0 and roll in

	local MAX_HOLD      = 3.0    -- s — longest one continuous key hold
	local HOLD_REST     = 0.4    -- s to let go for before taking it again

	local MAX_ACQUIRE   = 2000   -- studs — further than this is not our stop
	local RECEDE_ABORT  = 60     -- studs of moving AWAY = wrong-end buffer
	local APPROACH_LIMIT= 150    -- s — hard timeout on the run-in
	local CRAWL_LIMIT   = 30     -- s — hard timeout on the roll-in
	local SETTLE_LIMIT  = 15     -- s — hard timeout on coming to a stand
	local ACCEPT_WAIT   = 3.0    -- s to let SCR accept the stop before rolling
	local BORROW_MARGIN = 10     -- studs of extra room when using another
	                             -- platform's stop point
	local LEG_SUPPRESS  = 30     -- s after a leg change where we refuse to run
	local RESTART_LOCK  = 25     -- s before the same platform may be driven again
	local GRACE         = 35     -- s after an approach where nothing else may
	                             -- touch the train

	local VERBOSE       = true
	----------------------------------------------------------------------

	local Players = game:GetService("Players")
	local VIM     = game:GetService("VirtualInputManager")
	local player  = Players.LocalPlayer

	local NEXTLEG_PATH = { "Summary", "SummaryPage", "Controls", "NextLeg" }
	local SCHED_PATH   = { "Additional", "DetailsStack", "AdvanceContainer",
	                       "Main", "ScheduleDetails" }
	local MSG_PATH     = { "Additional", "DetailsStack", "MessageContainer" }
	local NOTCH_PATH   = { "Cluster", "Spedometer", "TargetIndicator" }

	local learned      = {}          -- "Station|4" -> studs the trip completed at
	local learnedAny   = nil         -- most recent accepted distance, any platform
	local K            = K_DEFAULT

	local owning       = false       -- we are driving; outside speed commands are ignored
	local settledAt    = -math.huge  -- when the last approach let go
	local settledKey   = nil         -- and which platform it was
	local lastBuffer   = nil         -- Vector3, for probe()
	local bufferHazardAt = -math.huge -- when SCR last WARNED about the buffer
	local closerAt     = -math.huge  -- when SCR last asked us to come CLOSER
	local lastMsg      = ""          -- the last buffer message, verbatim
	local realTarget   = nil
	local installed    = false

	local runs, rolled, accepted, aborted, timedOut = 0, 0, 0, 0, 0
	local retries, retryKey = 0, nil
	local MAX_RETRIES = 2
	-- Approaches, not retries. The retry counter only bounds the b() kicks
	-- this block fires itself; b() runs on every label change as well, so
	-- without this a platform can be driven at over and over, each one a
	-- little closer than the last, for as long as the trip stays open.
	local tries, triesKey = 0, nil
	local MAX_TRIES = 3
	local lastLine = "nothing yet"

	local function log(fmt, ...)
		if not VERBOSE then return end
		print("[buffer] " .. (select("#", ...) > 0 and fmt:format(...) or fmt))
	end

	----------------------------------------------------------------------
	-- HUD, resolved fresh each time so a rebuilt DriveGui cannot strand us
	----------------------------------------------------------------------
	local function driveGui()
		local pg = player:FindFirstChild("PlayerGui")
		return pg and pg:FindFirstChild("DriveGui") or nil
	end

	local function descend(root, path)
		local node = root
		for _, name in ipairs(path) do
			if not node then return nil end
			node = node:FindFirstChild(name)
		end
		return node
	end

	-- Visible in its own right and not hidden by any ancestor. A destroyed
	-- node has no parent chain, so this reads false.
	local function onScreen(obj)
		if not obj then return false end
		local node = obj
		while node and node ~= game do
			if node:IsA("LayerCollector") then return node.Enabled end
			if node:IsA("GuiObject") and not node.Visible then return false end
			node = node.Parent
		end
		return false
	end

	-- The Summary screen is SCR accepting the stop. This is the only
	-- unambiguous "close enough" signal in the whole HUD, so the approach
	-- closes its loop on it rather than on a number someone guessed.
	local function tripComplete()
		local gui = driveGui()
		if not gui then return false end
		return onScreen(descend(gui, NEXTLEG_PATH))
	end

	local function stationKey()
		local gui = driveGui()
		local sd  = gui and descend(gui, SCHED_PATH)
		if not sd then return nil end
		local st = sd:FindFirstChild("NextStop")
		local pl = sd:FindFirstChild("Platform")
		if not (st and pl) then return nil end
		local ok, key = pcall(function()
			return tostring(st.Text) .. "|" ..
			       (tostring(pl.Text):gsub("Platform%s*", ""))
		end)
		return ok and key or nil
	end

	-- Where the notch actually is, in mph. The inverse of the original's
	-- speed_angle(): rotation = mph * 1.2 - 31.
	local function notchMph()
		local gui = driveGui()
		local a   = gui and descend(gui, NOTCH_PATH)
		if not a then return nil end
		local ok, rot = pcall(function() return a.Rotation end)
		if not ok or type(rot) ~= "number" then return nil end
		return (rot + 31) / 1.2
	end

	-- What the ladder asks for at this distance.
	local function ladderMph(rem)
		for _, row in ipairs(LADDER) do
			if rem >= row[1] then return row[2] end
		end
		return LADDER[#LADDER][2]
	end

	-- SCR's driver messages about the buffer say two OPPOSITE things, and
	-- which one it is decides whether the train brakes or closes up.
	--
	--   "Stop closer to the buffer to terminate."  -> we are too far OUT
	--   "Stop alongside the platform"              -> move forward
	--   anything else naming the buffer            -> treat as a warning
	--
	-- This used to match "uffer" or "longside" and treat every hit as a stop
	-- line. Both of those strings mean COME FORWARD. So at a terminus where
	-- SCR wanted another twenty studs, the block read the complaint as "you
	-- are too close", refused its own roll-in on the strength of it, and sat
	-- there until the original's under() handler drove blind into the buffer.
	-- Read the text properly and that whole failure disappears.
	local function classifyMsg(txt)
		local raw = tostring(txt)
		local s   = raw:lower()
		if not (s:find("uffer") or s:find("longside") or s:find("terminat")) then
			return
		end
		lastMsg = raw
		if s:find("closer") or s:find("longside") or s:find("further")
			or s:find("forward") then
			closerAt = os.clock()
		else
			-- Named the buffer and did not ask us forward. The cautious
			-- reading of anything else is the one that stops the train.
			bufferHazardAt = os.clock()
		end
	end

	task.spawn(function()
		local hooked = nil
		while true do
			local gui = driveGui()
			local box = gui and descend(gui, MSG_PATH)
			if box and box ~= hooked then
				hooked = box
				box.ChildAdded:Connect(function(child)
					local ok, txt = pcall(function()
						local lbl = child:FindFirstChildWhichIsA("TextLabel", true)
						return lbl and lbl.Text or child.Name
					end)
					if ok and txt then pcall(classifyMsg, txt) end
				end)
			end
			task.wait(5)
		end
	end)

	----------------------------------------------------------------------
	-- Distance. The camera focus twitches when the driver looks around, and
	-- one bad sample inside a braking curve is a lurch, so the approach
	-- takes a median of three. probe() gets its own raw reading rather than
	-- pushing into the running approach's window.
	----------------------------------------------------------------------
	local function rawDist(v)
		local cam = workspace.CurrentCamera
		if not cam then return nil end
		local ok, dist = pcall(function()
			return (cam.Focus.Position - v).Magnitude
		end)
		if not ok or type(dist) ~= "number" or dist ~= dist then return nil end
		return dist
	end

	local function newSampler()
		local h = {}
		return function(v)
			local dist = rawDist(v)
			if not dist then return nil end
			h[#h + 1] = dist
			if #h > 3 then table.remove(h, 1) end
			if #h < 3 then return dist end
			local p, q, r = h[1], h[2], h[3]
			return math.max(math.min(p, q), math.min(math.max(p, q), r))
		end
	end

	-- How far a train doing this many studs/s needs to stop, planned against
	-- the same weakened brake the curve uses. This sets the roll-in's stop
	-- line, so that line is a floor for the TRAIN and not just for the
	-- instant the check happens to run.
	--
	-- The run-in's floor test does NOT use this. It has to plan against the
	-- full brake rate, and it has to take a measured speed rather than the
	-- one the curve derived from the same distance — that would be circular,
	-- since the curve solves v = sqrt(2 a s) for exactly that s.
	local function stopNeed(studsPerSec)
		return (studsPerSec * studsPerSec) / (2 * DECEL * SAFETY)
	end

	local function stopNeedMph(mph)
		return stopNeed(mph * K)
	end

	----------------------------------------------------------------------
	-- THE DRIVER
	--
	-- The approach does NOT go through the original's target(). That function
	-- holds a key and spins until the notch arrives, and it gives up the
	-- instant anything else fires cs — which b() does constantly at a
	-- terminus. Worse, a call that gets cut off cannot be cancelled: it stays
	-- parked in its own loop and, whenever it eventually exits, releases the
	-- key whoever came after it is holding. From outside there is no way to
	-- reach in and stop it.
	--
	-- So the approach drives the notch itself. The notch is just W and S
	-- against an indicator this block can already read, and that turns the
	-- whole thing into an ordinary bang-bang loop: hold a key until the notch
	-- crosses the value asked for, let go, and do not touch it again until it
	-- is off by more than START_BAND. Nothing blocks and nothing needs
	-- cancelling; if a key is stamped on by something else the notch stops
	-- moving, which this can see, and it re-presses.
	----------------------------------------------------------------------
	local keyDown, keySince, keyPause = nil, 0, 0
	local lastHave, frozenSince = nil, 0

	local function hold(k)
		if keyDown == k then return end
		if keyDown then
			pcall(function() VIM:SendKeyEvent(false, keyDown, false, nil) end)
		end
		keyDown = k
		if k then
			keySince, frozenSince = os.clock(), os.clock()
			pcall(function() VIM:SendKeyEvent(true, k, false, nil) end)
		end
	end

	-- Something else sending a KeyUp for the key we think we are holding is
	-- invisible from here — the only symptom is a notch that stops moving.
	-- So re-press it, and only then: a timer-driven re-press would stack
	-- KeyDowns against a single KeyUp, and if SCR counts presses rather than
	-- tracking a boolean that is how a key gets stuck down for good.
	local function repress()
		local k = keyDown
		if not k then return end
		frozenSince = os.clock()
		pcall(function()
			VIM:SendKeyEvent(false, k, false, nil)
			VIM:SendKeyEvent(true, k, false, nil)
		end)
	end

	local function pump(want)
		-- Never lean on a key indefinitely. If the indicator this reads has
		-- gone stale while the real notch keeps climbing, the hold cap is the
		-- only thing between the approach and a runaway. Checked before the
		-- reading, so a reading that fails cannot skip it.
		local now = os.clock()
		if keyDown and (now - keySince) > MAX_HOLD then
			hold(nil)
			keyPause = now
		end
		if (now - keyPause) < HOLD_REST then return end

		local have = notchMph()

		if have == nil then
			-- No feedback. Winding the notch UP blind is how it ends up at
			-- full throttle pointed at a buffer, so that never happens. But
			-- braking blind is safe — S only ever winds the notch down and
			-- its floor is a standstill — and refusing to brake because the
			-- HUD blinked would leave the train rolling at the buffer with
			-- nothing else able to stop it: the swallow is eating b()'s
			-- commands and under() is muted for the duration.
			if want <= 0 then hold(Enum.KeyCode.S) else hold(nil) end
			return
		end

		-- A held key with a notch that is not moving means the key is not
		-- really down. Nothing else can tell us that.
		if keyDown and lastHave and math.abs(have - lastHave) > 0.2 then
			frozenSince = now
		end
		lastHave = have
		if keyDown and (now - frozenSince) > 0.6 then repress() end

		local err = want - have
		if keyDown == Enum.KeyCode.W then
			-- Winding up: run it in until the notch has actually reached the
			-- value. Releasing on a symmetric tolerance instead would settle
			-- short every time, and short of 3 mph is a train that will not
			-- move at all.
			if err <= 0 then hold(nil) else hold(Enum.KeyCode.W) end
		elseif keyDown == Enum.KeyCode.S then
			if err >= 0 then hold(nil) else hold(Enum.KeyCode.S) end
		else
			-- At rest: only start again once it is off by more than the slop
			-- the last correction left behind. This is the hysteresis.
			if err >= START_BAND then
				hold(Enum.KeyCode.W)
			elseif err <= -START_BAND then
				hold(Enum.KeyCode.S)
			end
		end
	end

	-- Hands the notch back and makes sure neither key is left down.
	local function releaseKeys()
		keyDown, keyPause, lastHave = nil, 0, nil
		pcall(function()
			VIM:SendKeyEvent(false, Enum.KeyCode.W, false, nil)
			VIM:SendKeyEvent(false, Enum.KeyCode.S, false, nil)
		end)
	end

	-- Command a stop and wait until the train is genuinely stationary, so
	-- what gets measured (and learned) is where it came to rest and not
	-- where it happened to be when the brake went on.
	local function stopAndSettle(measure, bufferPos)
		local t0   = os.clock()
		local from = measure(bufferPos)
		local since = os.clock()
		while os.clock() - t0 < SETTLE_LIMIT do
			pump(0)
			local dist = measure(bufferPos)
			if not dist or not from then
				from, since = dist, os.clock()
			elseif math.abs(dist - from) > 1.0 then
				from, since = dist, os.clock()
			elseif (os.clock() - since) > 1.5 and keyDown == nil then
				return dist
			end
			task.wait(0.1)
		end
		return measure(bufferPos)
	end

	----------------------------------------------------------------------
	-- THE APPROACH
	----------------------------------------------------------------------
	local function runApproach(bufferPos)
		runs = runs + 1
		lastBuffer  = bufferPos
		bufferHazardAt = -math.huge
		-- Deliberately NOT clearing closerAt if it is recent. The retry path
		-- re-enters here seconds after SCR asked for a closer stop, and
		-- wiping the request on entry is how the same too-far stop gets made
		-- twice. Anything older than a station's worth of time still goes.
		if (os.clock() - closerAt) > 45 then closerAt = -math.huge end

		local measure = newSampler()

		local key   = stationKey()
		-- Retries are per stop, not per session. Only a REAL key resets the
		-- budget: stationKey() reads nil whenever the schedule panel is
		-- momentarily unresolvable, which is common around an arrival, and a
		-- nil/key alternation would refill the budget every other approach
		-- and turn a bounded retry into an endless one.
		if key and key ~= retryKey then retries, retryKey = 0, key end

		local aim   = AIM_DEFAULT
		local how   = "default"
		if key and learned[key] then
			aim, how = learned[key], "learned"
		elseif learnedAny then
			-- Another platform's number. Geometry differs, so give it extra
			-- room: stopping too far out costs a slow roll-in, stopping too
			-- close costs a buffer.
			aim, how = learnedAny + BORROW_MARGIN, "borrowed"
		end
		if aim < HARD_FLOOR then aim = HARD_FLOOR end

		-- SCR has already told us this platform wants a closer stop. Aim there
		-- on the curve instead of parking short and crawling the difference.
		if (os.clock() - closerAt) < 45 then
			local want = CLOSER_FLOOR + 4
			if want < aim then aim, how = want, "SCR asked for closer" end
		end

		local d0 = measure(bufferPos)
		if not d0 then
			lastLine = "no camera reading — handed back to the original"
			log(lastLine)
			return false
		end
		if d0 > MAX_ACQUIRE then
			aborted = aborted + 1
			lastLine = ("buffer %.0f studs away — not our stop"):format(d0)
			log(lastLine)
			return false
		end

		log("approach #%.0f to %s — %.0f studs out, aiming for %.0f (%s)",
			runs, key or "(unknown platform)", d0, aim, how)

		local t0      = os.clock()
		local minSeen = d0
		local lastD, lastT = d0, os.clock()
		local reason  = "reached the aim point"

		-- Stall watch. Two different things look identical from here — the
		-- train has come to rest on the aim point (fine, we are done), or it
		-- is refusing to roll at the speed asked for (not fine, ask for
		-- more). What separates them is whether we are commanding zero.
		local stillFrom, stillSince = d0, os.clock()
		local floorMph = MIN_MOVE
		local want = 0
		-- Seeded from the notch rather than zero, so the floor test below has
		-- a realistic speed to work with before the first measurement lands
		-- rather than believing the train is stationary.
		local closingNow = (notchMph() or 0) * K
		if closingNow < 0 then closingNow = 0 end
		local flooredAt = -math.huge
		-- Once the floor test has fired it STAYS fired for the rest of the
		-- run-in. Without the latch the floor test and the ladder take turns:
		-- inside the floor the test commands 0, the train slows, the test
		-- clears, the ladder commands 5 again, the train creeps a little
		-- closer, and round it goes. That oscillation is what walked a train
		-- into the buffer at Llyn-by-the-Sea — twitching between 5 and 0 the
		-- whole way in. The floor firing means "this is as close as you are
		-- allowed to get", and that is not a thing that should un-fire.
		local floorLatched = false
		local contact = false

		releaseKeys()               -- this approach drives the notch from scratch

		------------------------------------------------------------------
		-- PHASE 1 — the profiled run-in
		------------------------------------------------------------------
		while true do
			local now = os.clock()

			if tripComplete() then reason = "trip accepted on the way in" break end
			if now - t0 > APPROACH_LIMIT then
				timedOut = timedOut + 1
				reason = "run-in timed out"
				break
			end

			local dist = measure(bufferPos)
			if not dist then reason = "lost the camera reading" break end

			if dist < minSeen then minSeen = dist end
			if dist > minSeen + RECEDE_ABORT then
				aborted = aborted + 1
				reason = ("buffer receding — closest %.0f, now %.0f"):format(minSeen, dist)
				break
			end

			-- Live speed calibration. Only while genuinely rolling, so a
			-- stationary sample cannot drag the estimate to zero.
			local dt = now - lastT
			if dt >= 0.3 then
				local closing = (lastD - dist) / dt          -- studs/s
				if closing < 0 then closing = 0 end
				closingNow = closingNow + (closing - closingNow) * 0.5
				if want >= 8 and closing > 0.5 then
					local kObs = closing / want
					if kObs > K_MIN and kObs < K_MAX then
						K = K + (kObs - K) * 0.15
					end
				end
				lastD, lastT = dist, now
			end

			if os.clock() - bufferHazardAt < 2 then
				reason = "SCR warned about the buffer"
				break
			end
			-- Floor test, on how fast the train is ACTUALLY closing and against
			-- the FULL brake rate. Two things this is deliberately not:
			--
			--   * not the speed the curve derived from this same distance —
			--     that is circular, and reduces to comparing aim to the floor;
			--   * not an abort. Entering above the curve is the ordinary state
			--     at the start of an approach and the answer to it is to brake,
			--     which is what commanding zero does. Ending the run-in here
			--     instead would park the train short of the platform with the
			--     trip still open and nothing left to recover it.
			local floored = dist <= HARD_FLOOR + (closingNow * closingNow) / (2 * DECEL)
			if floored then flooredAt, floorLatched = now, true end
			floored = floored or floorLatched

			-- Stall watch, as described above.
			if math.abs(dist - stillFrom) > 1.5 then
				stillFrom, stillSince = dist, now
			elseif want == 0 and (now - stillSince) > 1.5 then
				reason = floored and "stopped on the floor" or "come to rest"
				break
			elseif want > 0 and (now - stillSince) > 10 then
				-- Asked to move and not moving. Once, that is a train that
				-- will not start at this notch, so ask for a bit more. Twice
				-- is a train with something in front of it, and at a terminus
				-- there is only one thing that can be.
				if floorMph < 8 then
					floorMph = math.min(floorMph + 2, 8)
					stillSince = now
					log("not rolling — raising the floor to %.0f mph", floorMph)
				else
					contact = true
					reason = ("not moving at %.0f mph — against the buffer"):format(floorMph)
					break
				end
			end

			local rem = dist - aim
			if rem <= 0 then break end

			if floored then
				want = 0                       -- brake, and let the stall watch
				                               -- end the phase once we are stopped
			else
				-- Straight off the ladder. The line speed limit is NOT applied
				-- here, on purpose: this is the run into the last station, the
				-- platform is the end of the line, and crawling the last
				-- quarter mile at a 15 limit costs a minute a trip. The floor
				-- test above is what keeps it honest instead.
				local mph = ladderMph(rem)
				if mph > APPROACH_CAP then mph = APPROACH_CAP end
				if rem <= ARRIVE_BAND then
					mph = 0                    -- inside the band, roll to rest
				elseif mph < floorMph then
					mph = floorMph             -- or it simply will not move
				end
				want = math.floor(mph + 0.5)
			end

			pump(want)
			task.wait(TICK)
		end

		local curveRest = stopAndSettle(measure, bufferPos)

		------------------------------------------------------------------
		-- PHASE 2 — let SCR accept it
		------------------------------------------------------------------
		local waited = os.clock()
		while os.clock() - waited < ACCEPT_WAIT do
			if tripComplete() then break end
			pump(0)
			task.wait(0.1)
		end

		local rest = curveRest

		------------------------------------------------------------------
		-- PHASE 3 — one continuous roll-in, only if the stop was not taken
		------------------------------------------------------------------
		-- Only roll in from a stop we MEANT to make. If phase 1 broke out
		-- because the buffer was receding or the run-in ran out of time, the
		-- last thing to do is set off again in the same direction.
		-- "stopped on the floor" belongs here too: it means the train braked
		-- and stopped, which is a stop we meant to make. Whether it is close
		-- enough to go no further is decided by `blocked` just below, on the
		-- distance actually reached — not by how the phase happened to end.
		local parked = (reason == "reached the aim point")
			or (reason == "come to rest")
			or (reason == "stopped on the floor")

		local didRoll = false
		if not tripComplete() and parked then
			-- SCR asking us to come closer overrides our own floor. The floor
			-- is a guess about what the game will accept; the message is the
			-- game telling us the guess was wrong.
			local askedCloser = (os.clock() - closerAt) < 25
			local floorUse = askedCloser and CLOSER_FLOOR or HARD_FLOOR
			local floorNow = floorUse + stopNeedMph(CRAWL_SPEED)
			local blocked  = (rest and rest <= floorNow)
				or (os.clock() - bufferHazardAt < 5)

			if askedCloser and not blocked then
				log("SCR asked for a closer stop (\"%s\") — floor for this roll " ..
					"is %.0f studs", tostring(lastMsg), floorUse)
			end

			if blocked then
				log("stopped at %.0f studs and the trip did not complete, but that " ..
					"is the floor — not going closer. Lower it with " ..
					"_G.SCRBuffer.set{ floor = <studs> } if SCR wants more.",
					rest or -1)
			else
				didRoll = true
				rolled  = rolled + 1

				-- ONE movement, not a series of nudges: it starts rolling and
				-- does not stop until the game takes the trip.
				local crawl = math.max(CRAWL_SPEED, math.min(floorMph, CRAWL_MAX))
				log("stopped at %.0f studs, trip not accepted — rolling in at %.0f mph",
					rest or -1, crawl)

				local tc = os.clock()
				local cFrom, cSince = rest, os.clock()
				local lost, cMin = 0, rest or math.huge

				while os.clock() - tc < CRAWL_LIMIT do
					if tripComplete() then break end

					local dist = measure(bufferPos)
					if not dist then
						-- No reading means no floor check. Two in a row and
						-- we stop rather than roll on blind.
						lost = lost + 1
						if lost >= 2 then
							log("lost the camera reading while rolling in — stopping")
							break
						end
					else
						lost = 0
						if dist < cMin then cMin = dist end
						if dist > cMin + RECEDE_ABORT then
							log("rolling away from the buffer — stopping")
							break
						end
						if dist <= floorUse + stopNeedMph(crawl) then break end

						-- One escalation for a train that will not start, and
						-- then no more. Escalating a second time is how a
						-- stalled roll turns into a buffer strike.
						if cFrom == nil or math.abs(dist - cFrom) > 1.5 then
							cFrom, cSince = dist, os.clock()
						elseif os.clock() - cSince > 6 then
							if crawl < CRAWL_MAX then
								crawl = math.min(crawl + 2, CRAWL_MAX)
								cSince = os.clock()
							else
								contact = true
								log("not moving at %.0f mph — against the buffer, stopping",
									crawl)
								break
							end
						end
					end

					if os.clock() - bufferHazardAt < 2 then break end
					pump(crawl)
					task.wait(0.05)
				end

				rest = stopAndSettle(measure, bufferPos)

				local w = os.clock()
				while os.clock() - w < 2 do
					if tripComplete() then break end
					pump(0)
					task.wait(0.1)
				end
			end
		end

		------------------------------------------------------------------
		-- LEARN
		--
		-- What gets stored is the AIM THAT WORKED, not where the train ended
		-- up. Those are a stud or two apart, and storing the latter would
		-- walk the aim point a little further out on every single visit
		-- until SCR stopped accepting it — an oscillation, not convergence.
		--
		--   accepted on the ladder -> the aim was good, keep it
		--   accepted after rolling -> the aim was too far out, and the place
		--                             the roll ended is the known-good one
		------------------------------------------------------------------
		-- Touching the buffer beats every learned number and every message SCR
		-- can send. Whatever we were aiming for was too close; back it off and
		-- do not let the "come closer" ratchet undo it.
		if contact and rest then
			local safe = rest + 25
			if safe < HARD_FLOOR then safe = HARD_FLOOR end
			learnedAny = safe
			if key then learned[key] = safe end
			closerAt = -math.huge
			warn(("[buffer] stopped against the buffer at %.0f studs — aim at %s " ..
			      "backed off to %.0f and locked. If SCR still wants closer, it wants " ..
			      "something other than distance."):format(rest, key or "this platform", safe))
		end

		if tripComplete() and rest then
			accepted = accepted + 1

			-- The ladder does not stop exactly on its aim — it commands zero
			-- inside ARRIVE_BAND and rolls out a stud or two past that. So
			-- when a roll-in found the good spot, aiming AT that spot next
			-- time would stop the residual short of it and need another
			-- roll-in, a little closer each visit, forever. Take the residual
			-- off the aim instead and the curve lands on the spot itself.
			--
			-- Only when the ladder was actually in charge, though. If the floor
			-- test was what brought the train to a stand, or the run-in ended
			-- nowhere near its aim, the gap between the two is not a residual
			-- at all — it is the whole distance the ladder never drove, and
			-- subtracting it would slam the learned point onto the hard floor
			-- and keep it there.
			--
			-- The floor test is checked on when it LAST fired, not on whether
			-- it ever fired. It trips on the first tick of most approaches,
			-- because the notch still reads the 30 mph the original was
			-- holding when the distance counter hit zero; treating that as
			-- "the ladder never drove" would disable this on every arrival.
			local floorStopped = (os.clock() - flooredAt) < 4

			local curveDrove = (not floorStopped) and curveRest
				and math.abs(curveRest - aim) <= (ARRIVE_BAND + 10)

			local residual = curveDrove and (curveRest - aim) or 0
			local good = aim
			if didRoll then good = rest - residual end
			local lowest = ((os.clock() - closerAt) < 60) and CLOSER_FLOOR or HARD_FLOOR
			if good < lowest then good = lowest end

			learnedAny = good
			if key then learned[key] = good end

			retries = 0
			lastLine = ("accepted at %.0f studs (%s)%s — aim for next time %.0f, " ..
				"k=%.2f studs/s per mph")
				:format(rest, key or "unknown platform",
					didRoll and ", after a roll-in" or " on the ladder",
					good, K)
			log(lastLine)
		else
			lastLine = ("stopped at %.0f studs and the trip is still open — %s")
				:format(rest or -1, reason)

			-- SCR said in so many words that we are too far out. Whatever we
			-- were aiming for is wrong, so move it in before the retry rather
			-- than repeating the same stop and hoping.
			if (os.clock() - closerAt) < 30 then
				local was = (key and learned[key]) or learnedAny or AIM_DEFAULT
				local tighter = math.max(CLOSER_FLOOR, was - 12)
				if tighter < was then
					learnedAny = tighter
					if key then learned[key] = tighter end
					log("SCR wants us closer — aim at %s cut from %.0f to %.0f studs",
						key or "this platform", was, tighter)
				end
			end

			-- Nothing in the original will come back for us. b() only runs on
			-- the distance, signal-distance and speed-limit labels changing,
			-- and at a terminus with the train stopped all three are frozen;
			-- clockTick's kick is gated on distance being non-zero, and the
			-- routine defib is fifteen minutes away. So kick it here, a
			-- bounded number of times, rather than sit short of the platform
			-- for the rest of the night.
			if retries < MAX_RETRIES then
				retries = retries + 1
				local n = retries
				log(lastLine .. " — retrying (%.0f of %.0f)", n, MAX_RETRIES)
				task.spawn(function()
					task.wait(RESTART_LOCK + 2)
					if owning or tripComplete() then return end
					if type(b) == "function" then pcall(b) end
				end)
			else
				warn("[buffer] " .. lastLine .. " — out of retries. Stand where it " ..
				     "does complete, run _G.SCRBuffer.probe(), then " ..
				     "_G.SCRBuffer.set{ aim = <studs> }.")
			end
		end
		releaseKeys()
		return true
	end

	----------------------------------------------------------------------
	-- INSTALL
	----------------------------------------------------------------------
	local function install()
		------------------------------------------------------------------
		-- getD — the hijack point.
		--
		-- The original's creep loop is `while getD(buffer) >= BUFFERSTOP`,
		-- and it hands us the buffer position as the argument. So we take
		-- the position, return 0 to collapse the loop before it can command
		-- a single 15 mph, and drive the approach ourselves. Nothing in the
		-- original needs editing for this.
		------------------------------------------------------------------
		local prevGetD = getD

		-- Collapsing the loop makes the original fire a stop straight after.
		-- At a terminus that must not become a 5 mph stop-hold nudge, so
		-- every path that returns 0 waves the hold off first.
		local function collapse()
			if _G.SCRStop and _G.SCRStop.skipNext then pcall(_G.SCRStop.skipNext) end
			return 0
		end

		getD = function(v)
			if not (ENABLED and typeof(v) == "Vector3") then
				return prevGetD(v)
			end

			if owning then return 0 end   -- already ours; collapse any re-entry

			-- b() runs again on every label change, and at a terminus the
			-- distance label stays at zero, so without these latches the same
			-- platform would be driven at over and over while sat in it.
			if tripComplete() then return collapse() end

			-- The platform block drives the notch with its own key presses.
			-- Starting an approach on top of that gives two controllers one
			-- set of keys, each fighting the other's idea of the notch.
			if _G.SCRPlatform and _G.SCRPlatform.busy then
				local okp, busy = pcall(_G.SCRPlatform.busy)
				if okp and busy then return collapse() end
			end

			local key = stationKey()
			if (os.clock() - settledAt) < RESTART_LOCK
				and (key == nil or key == settledKey) then
				return collapse()
			end

			-- However many times b() comes back, there is a limit to how many
			-- times one platform may be driven at. Each approach ends a little
			-- closer than the last, and unbounded that is a buffer strike with
			-- extra steps.
			if key ~= nil and key ~= triesKey then tries, triesKey = 0, key end
			if tries >= MAX_TRIES then
				if tries == MAX_TRIES then
					tries = tries + 1
					warn(("[buffer] %.0f approaches at %s and the trip is still open — " ..
					      "standing down rather than going closer. _G.SCRBuffer.probe() " ..
					      "and _G.SCRBuffer.status() will say where it got to.")
						:format(MAX_TRIES, key))
				end
				return collapse()
			end
			tries = tries + 1

			-- Straight after Next Leg the buffer we are handed is the one
			-- behind us. The creep guard tracks that; respect it.
			if _G.SCRFix and _G.SCRFix.lastLegChange then
				local ok, t = pcall(_G.SCRFix.lastLegChange)
				if ok and type(t) == "number" and (os.clock() - t) < LEG_SUPPRESS then
					log("leg changed %.0fs ago — that buffer is behind us, skipping",
						os.clock() - t)
					return collapse()
				end
			end

			owning = true
			task.spawn(function()
				local ok, res = pcall(runApproach, v)
				if not ok then
					warn("[buffer] approach failed: " .. tostring(res))
					pcall(releaseKeys)
				end
				-- Only claim the grace period if we actually drove; an
				-- approach that bailed on the first reading has no business
				-- muting the rest of the script for twenty seconds.
				if ok and res == true then
					settledAt, settledKey = os.clock(), key
				end
				owning = false
			end)
			return collapse()
		end

		------------------------------------------------------------------
		-- target — the swallow.
		--
		-- b() keeps firing on every label change while we are driving, and
		-- the original fires 0 the moment its creep loop collapses. Both
		-- would fight the profile, so while the approach owns the train
		-- nothing but the approach gets to command a speed.
		------------------------------------------------------------------
		realTarget = target
		target = function(speed)
			if owning then return end
			return realTarget(speed)
		end

		_G.SCRBuffer = {
			-- True while driving, and for a short tail afterwards. Anything
			-- that would grab the train — a defib, the original's buffer
			-- message handler, the next-leg key release — checks this and
			-- stands down. The tail matters as much as the approach: a 5 mph
			-- nudge ten seconds after we have parked against a buffer goes
			-- straight into it.
			-- Also busy while SCR is actively asking for a closer stop. That
			-- situation belongs to this block, and the thing it has to keep
			-- out is the original's under(): a blind 5 mph for three seconds,
			-- fired once per complaint, with eight complaints on screen.
			busy = function()
				return owning or (os.clock() - settledAt) < GRACE
					or (os.clock() - closerAt) < 25
			end,

			probe = function()
				if not lastBuffer then
					print("[buffer] no buffer seen yet — probe after an arrival")
					return nil
				end
				local dist = rawDist(lastBuffer)
				print(("[buffer] %.1f studs to the last buffer | trip complete: %s")
					:format(dist or -1, tostring(tripComplete())))
				return dist
			end,

			set = function(t)
				if type(t) ~= "table" then
					warn("[buffer] usage: _G.SCRBuffer.set{ aim = 45, floor = 10, cap = 25, crawl = 3 }")
					return false
				end
				if tonumber(t.aim)   then AIM_DEFAULT  = tonumber(t.aim)   end
				if tonumber(t.floor) then HARD_FLOOR   = tonumber(t.floor) end
				if tonumber(t.cap)   then APPROACH_CAP = tonumber(t.cap)   end
				if tonumber(t.crawl) then CRAWL_SPEED  = tonumber(t.crawl) end
				if tonumber(t.closerFloor) then CLOSER_FLOOR = tonumber(t.closerFloor) end
				log("aim %.0f studs | floor %.0f | cap %.0f mph | roll-in %.0f mph",
					AIM_DEFAULT, HARD_FLOOR, APPROACH_CAP, CRAWL_SPEED)
				return true
			end,

			forget = function()
				learned, learnedAny, K = {}, nil, K_DEFAULT
				log("forgot every learned stop point and calibration")
			end,

			enable  = function() ENABLED = true  ; log("on — profiled approach") end,
			disable = function() ENABLED = false ; log("off — the original's 15 mph creep is back") end,

			status = function()
				local n = 0
				for _ in pairs(learned) do n = n + 1 end
				return ("[buffer] %s | %.0f approach(es), %.0f accepted, %.0f roll-in(s), %.0f abort(s), %.0f timeout(s)\n" ..
				        "         %.0f platform(s) learned | k=%.2f studs/s per mph | " ..
				        "cap %.0f mph | floor %.0f (%.0f once asked closer)\n" ..
				        "         last message: %s\n         last: %s"):format(
					installed and (ENABLED and "armed" or "disabled") or "NOT installed",
					runs, accepted, rolled, aborted, timedOut, n, K,
					APPROACH_CAP, HARD_FLOOR, CLOSER_FLOOR,
					(lastMsg ~= "" and lastMsg or "none"), lastLine)
			end,

			learned = function()
				local n = 0
				for name, dist in pairs(learned) do
					print(("[buffer] %-28s %.0f studs"):format(name, dist))
					n = n + 1
				end
				if n == 0 then print("[buffer] nothing learned yet") end
				return learned
			end,
		}

		installed = true
		log("armed — braking curve to the buffer, aim %.0f studs, floor %.0f",
			AIM_DEFAULT, HARD_FLOOR)
	end

	-- Must install LAST, so its getD and target wrappers sit outside the
	-- creep guard's and the stop-hold's. Waits for both of those to be up.
	task.spawn(function()
		local t0 = os.clock()
		repeat
			task.wait(0.1)
		until (_G.SCRFix and _G.SCRStop and _G.SCRWhite and _G.SCRPlatform
			and type(getD) == "function" and type(target) == "function")
			or (os.clock() - t0 > 45)

		if type(getD) == "function" and type(target) == "function" then
			install()
		else
			warn("[buffer] getD/target never appeared — the approach is NOT active. " ..
			     "This block has to run in the same file as the autopilot.")
		end
	end)
end
-- ================== END TERMINAL BUFFER APPROACH =========================


--[[ ======================================================================
     CONTROL BRIDGE  —  last block in the file.

     Every block publishes its controls on _G. In some executors _G is not
     shared between one execution and the next, so a control typed into a
     second tab cannot see them and comes back as "attempt to index nil".
     getgenv() is the executor's shared environment and does survive, so
     this mirrors everything into it as the blocks come up.

     Costs nothing where _G was already shared: the names simply exist in
     both places.

       getgenv().SCRPlatform.probe()      -- works from another tab
       _G.SCRPlatform.probe()             -- works from inside this file
====================================================================== ]]
do
	local NAMES = {
		"AntiAFK", "SCRFix", "SCRBrake", "SCRStop", "SCRWhite",
		"SCRPlatform", "SCRLong", "AutoNextLeg", "SCRBuffer",
	}

	task.spawn(function()
		if type(getgenv) ~= "function" then
			warn("[bridge] no getgenv in this executor — controls are _G only, " ..
			     "and may not be reachable from a second tab.")
			return
		end

		local ok, g = pcall(getgenv)
		if not ok or type(g) ~= "table" then return end

		local seen = {}
		-- The blocks install over about forty-five seconds, so keep mirroring
		-- for a while rather than taking one snapshot too early.
		for _ = 1, 60 do
			for _, n in ipairs(NAMES) do
				if _G[n] ~= nil and not seen[n] then
					g[n] = _G[n]
					seen[n] = true
				end
			end
			task.wait(2)
		end

		local have = {}
		for _, n in ipairs(NAMES) do
			if seen[n] then have[#have + 1] = n end
		end
		print("[bridge] controls on getgenv(): " ..
			(#have > 0 and table.concat(have, ", ") or "NONE — no block installed"))
	end)
end
-- ================== END CONTROL BRIDGE ==================================

-- Made by PlaceReporter99
-- https://github.com/PlaceReporter99

-- You may want to change these constants depending on your train.

-- The maximum speed of your train.
local MAXSPEED = 100

-- Whether to obey the current speed limit.
local OBEYSPEEDLIMIT = true

-- The speed the train should slow down to when getting close to the station.
local SAFESTOPSPEED = 30

-- The speed the train should move at when approaching a single yellow signal.
local YELLOWSIGNALSPEED = 35

-- The distance in miles from the station your train should reach before slowing down.
local SAFESTOPDISTANCE = 0.2

-- The distance in studs from the buffer the train should stop.
local BUFFERSTOP = 100














print("AUTO DRIVE")
local cs = Instance.new("BindableEvent")
local buf = loadstring(game:HttpGet("https://raw.githubusercontent.com/PlaceReporter99/SCR-Autopilot/refs/heads/main/const/RouteBuffers.lua"))()
cs.Name = "ChangeSpeed"
signalv = {
["proceed"] = 0,
["precaution"] = 1,
["caution"] = 2,
["danger"] = 3,
["unknown"] = 4
}
cs.Event:Connect(function(a)
    target(a)
end)

local fex = Instance.new("BindableEvent")
fex.Name = "ExecuteFunction"
fex.Event:Connect(function(f) f() end)
local vim = game:GetService('VirtualInputManager')
input = {
    hold = function(key, time)
        print("Holding key", key)
        vim:SendKeyEvent(true, key, false, nil)
        task.wait(time)
        vim:SendKeyEvent(false, key, false, nil)
        print("Finished holding key", key)
end,
    press = function(key)
        print("Pressing key", key)
        vim:SendKeyEvent(true, key, false, nil)
        task.wait(0.005)
        vim:SendKeyEvent(false, key, false, nil)
end,
    start = function(key)
        print("starting key", key)
        vim:SendKeyEvent(true, key, false, nil)
end,
    stop = function(key)
        print("stopping key", key)
        vim:SendKeyEvent(false, key, false, nil)
end
}
local drive, schd, left, cluster, arm, buttons, d, ti, odm, nl, aws, signal, signald, speedl, msg
function SCR_BindHUD()
drive = game.Players.LocalPlayer.PlayerGui:WaitForChild("DriveGui", 30)
schd = drive.Additional.DetailsStack.AdvanceContainer.Main.ScheduleDetails
left = schd.Counters
cluster = drive.Cluster
arm = cluster.Spedometer.TargetIndicator
buttons = cluster.Actions
d = left.Distance
ti = left.DepartTime
odm = cluster.Activity.ActivityMessage
nl = drive.Summary.SummaryPage.Controls.NextLeg
aws = cluster.AwsIndicatorMinimal
signal = drive.Additional.DetailsStack.AdvanceContainer.Signal.Standard
signald = drive.Additional.DetailsStack.AdvanceContainer.Signal.Distance
speedl = game.Players.LocalPlayer.PlayerGui.DriveGui.Cluster.Stats.CurrentState.SpeedLimit.Limit
msg = game.Players.LocalPlayer.PlayerGui.DriveGui.Additional.DetailsStack.MessageContainer
end
SCR_BindHUD()

function getD(v)
return (workspace.CurrentCamera.Focus.Position - v).Magnitude
end

function getSpeedLimit()
if OBEYSPEEDLIMIT then
return tonumber(speedl.Text)
else
return 1000
end
end

function getSignal()
if signal.Danger.BackgroundTransparency == 0 then
        print("signal get danger")
return signalv.danger
end
if signal.Precaution.BackgroundTransparency == 0 then
        print("signal get precaution")
return signalv.precaution
end
if signal.Caution.BackgroundTransparency == 0 then
        print("signal get caution")
return signalv.caution
end
if signal.Proceed.BackgroundTransparency == 0 then
        print("signal get proceed")
return signalv.proceed
end
    print("signal get unknown")
return signalv.unknown
end

function getSignalDistance()
return tonumber(signald.Text:sub(1, -4))
end

local mode = nil

speed_angle = function(speed) return speed*1.2 - 31 end

function target(speed)
local tt = false
local stopr = cs.Event:Connect(function()
        tt = true
end)
    input.stop(Enum.KeyCode.W)
    input.stop(Enum.KeyCode.S)
    print("targeting speed", speed)
    print("rotation data this", speed_angle(speed), "that", arm.Rotation)
if -1.8 <= speed_angle(speed) - arm.Rotation and speed_angle(speed) - arm.Rotation <= 1.8 then
-- it's fine, do nothing 
        print("speed did not change", speed)
elseif speed_angle(speed) < arm.Rotation then
        print("speed decrease to", speed)
        input.start(Enum.KeyCode.S)
while speed_angle(speed) < arm.Rotation and not tt do
            task.wait(0.005)
end
        input.stop(Enum.KeyCode.S)
elseif speed_angle(speed) > arm.Rotation then
        print("speed increase to", speed)
        input.start(Enum.KeyCode.W)
while speed_angle(speed) > arm.Rotation and not tt do
            task.wait(0.005)
end
        input.stop(Enum.KeyCode.W)
end
    stopr:Disconnect()
end
function clockTick()
input.press(Enum.KeyCode.T)
input.press(Enum.KeyCode.Q)
if arm.Rotation <= speed_angle(10) and tonumber(d.Text:sub(1, -4)) ~= 0 and (getSignal() ~= signalv.danger or getSignalDistance() > tonumber(d.Text:sub(1, -4))) then
    task.wait(10)
if arm.Rotation <= speed_angle(10) and tonumber(d.Text:sub(1, -4)) ~= 0 and (getSignal() ~= signalv.danger or getSignalDistance() > tonumber(d.Text:sub(1, -4))) then
        cs:Fire(SAFESTOPSPEED)
end
end
--clickButton(nl)
end
drive.Clock.TextLabel:GetPropertyChangedSignal("Text"):Connect(clockTick)
local c;
print(d.Text)
cs:Fire(math.min(MAXSPEED, getSpeedLimit()))
function b()
local num = tonumber(d.Text:sub(1, -4))
    print(num)
if num == 0 or (getSignal() == signalv.danger and num >= getSignalDistance()) then
if num == 0 then
local plat = string.gsub(schd.Platform.Text, "Platform ", "")
local st = schd.NextStop.Text
if buf[st] and buf[st][plat] then
while getD(buf[st][plat]) >= BUFFERSTOP do
                    print(getD(buf[st][plat]))
                    cs:Fire(15)
                    task.wait(0.1)
end
end
end
        cs:Fire(0)
elseif num <= SAFESTOPDISTANCE then
        cs:Fire(math.min(SAFESTOPSPEED, getSpeedLimit()))
elseif getSignal() == signalv.caution then
        cs:Fire(math.min(YELLOWSIGNALSPEED, getSpeedLimit()))
elseif (num > SAFESTOPDISTANCE and (getSignal() == signalv.precaution or getSignal() == signalv.proceed)) then
        cs:Fire(math.min(MAXSPEED, getSpeedLimit()))
end
end
if (tonumber(d.Text:sub(1, -4)) <= SAFESTOPDISTANCE) then
    cs:Fire(math.min(SAFESTOPSPEED, getSpeedLimit()))
elseif getSignal() == signalv.caution then
    cs:Fire(math.min(YELLOWSIGNALSPEED, getSpeedLimit()))
else
    cs:Fire(math.min(MAXSPEED, getSpeedLimit()))
end
d:GetPropertyChangedSignal("Text"):Connect(b)
signald:GetPropertyChangedSignal("Text"):Connect(b)
speedl:GetPropertyChangedSignal("Text"):Connect(b)
local underBusy, underLast = false, -math.huge
function under(child)
if _G.SCRBuffer and _G.SCRBuffer.busy() then return end
if _G.SCRPlatform and _G.SCRPlatform.busy() then return end
if underBusy or (os.clock() - underLast) < 20 then return end
if child.Name == "DriveMessage" and (string.match(child.TextLabel.Text, "longside") or string.match(child.TextLabel.Text, "uffer")) then
        underBusy = true
        pcall(function()
            cs:Fire(5)
            task.wait(3)
            cs:Fire(0)
        end)
        underLast = os.clock()
        underBusy = false
end
end
msg.ChildAdded:Connect(under)
print(getSignal())
