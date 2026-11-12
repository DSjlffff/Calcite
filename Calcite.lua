-- Calcite, glued from the modules of src by build.ps1; edit those, not this file
local __modules, __loaded = {}, {}

-- what the modules call require: every one of them is run once, on first use
local function __require(path)
    local name = string.match(path, "([%w_]+)$")
    local entry = __loaded[name]
    if entry == nil then
        local module = __modules[name]
        if module == nil then
            error("Calcite: there is no module " .. tostring(path), 2)
        end
        entry = { value = module(__require) }
        __loaded[name] = entry
    end
    return entry.value
end

__modules["aim_math"] = function(require)
-- the arithmetic of the aim: who is the nearest to the crosshair, and how far to move the mouse in a frame
-- the mouse is all the aim has: it sends counts, the game turns the camera by them in its own way, and how many pixels
-- of the screen a count is worth depends on the game and on the sensitivity the user has set there. The aim finds
-- that out by itself, from how far the point moved after what was sent
-- pure logic, checked by tests/aim_math_test.lua
local num = require("./num")

local aim_math = {}

aim_math.max_step = 200         -- counts in one frame, whatever the error: a wrong guess must not spin the camera

local min_gain = 0.02           -- counts for a pixel: the range a guess is kept in
local max_gain = 50
local learn_from = 3            -- counts: a smaller step tells too little about the game to learn from
local learn_rate = 0.5          -- how far a guess moves to what was just seen: the target moves and the hand of the user too
local on_point = 1              -- pixels: closer than this the mouse is left alone

-- the share of the error removed in a frame that long: the same path whatever the frame rate
function aim_math.share(speed, dt)
    return 1 - math.exp(-speed * dt)
end

-- the one closest to the crosshair among those inside the circle; each has ex, ey: pixels from the crosshair to it
function aim_math.nearest(candidates, radius)
    local best = nil
    local bestDistance = radius * radius

    for _, candidate in candidates do
        local distance = candidate.ex * candidate.ex + candidate.ey * candidate.ey
        if distance <= bestDistance then
            best = candidate
            bestDistance = distance
        end
    end

    return best
end

function aim_math.newController()
    return {
        gain = 1,           -- counts of the mouse for a pixel of the screen, as far as it is known
        carryX = 0,         -- what was cut off when the last step was made whole
        carryY = 0,
        lastErrorX = nil,   -- where the point was a frame ago, and what was sent then
        lastErrorY = nil,
        lastMoveX = 0,
        lastMoveY = 0,
    }
end

-- before another target: what was learnt about the game stays, what was known about the old target goes
function aim_math.reset(controller)
    controller.carryX = 0
    controller.carryY = 0
    controller.lastErrorX = nil
    controller.lastErrorY = nil
    controller.lastMoveX = 0
    controller.lastMoveY = 0
end

-- one frame: the point is ex, ey pixels from the crosshair; gives the whole counts to send to the mouse
function aim_math.step(controller, ex, ey, speed, dt)
    if not (num.finite(ex) and num.finite(ey)) then
        aim_math.reset(controller)
        return 0, 0
    end

    -- what did the last step do: the point came shiftX, shiftY pixels closer for the counts that were sent
    if controller.lastErrorX ~= nil then
        local sentX, sentY = controller.lastMoveX, controller.lastMoveY
        local sent = sentX * sentX + sentY * sentY

        if sent >= learn_from * learn_from then
            local shiftX = controller.lastErrorX - ex
            local shiftY = controller.lastErrorY - ey
            -- pixels a count, along the way the mouse was sent
            local perCount = (shiftX * sentX + shiftY * sentY) / sent

            -- a point that got further away although the mouse went after it is running faster than the aim: nothing
            -- to learn from that
            if perCount > 0 then
                local seen = math.clamp(1 / perCount, min_gain, max_gain)
                controller.gain = controller.gain * (seen / controller.gain) ^ learn_rate
            end
        end
    end

    if ex * ex + ey * ey < on_point * on_point then
        controller.carryX = 0
        controller.carryY = 0
        controller.lastErrorX = ex
        controller.lastErrorY = ey
        controller.lastMoveX = 0
        controller.lastMoveY = 0
        return 0, 0
    end

    local share = aim_math.share(speed, dt)
    local wantX = ex * share * controller.gain + controller.carryX
    local wantY = ey * share * controller.gain + controller.carryY

    local length = math.sqrt(wantX * wantX + wantY * wantY)
    if length > aim_math.max_step then
        wantX = wantX * aim_math.max_step / length
        wantY = wantY * aim_math.max_step / length
    end

    -- the mouse takes whole counts; the rest is kept for the next frame, or a slow aim would never move
    local moveX = math.round(wantX)
    local moveY = math.round(wantY)
    controller.carryX = wantX - moveX
    controller.carryY = wantY - moveY

    controller.lastErrorX = ex
    controller.lastErrorY = ey
    controller.lastMoveX = moveX
    controller.lastMoveY = moveY

    return moveX, moveY
end

return aim_math
end

__modules["aim"] = function(require)
-- the aim: while its key is held, the mouse is moved towards the one nearest to the crosshair
-- nothing of the game is read or changed here beyond the places of the characters: the mouse is all it moves,
-- the way a hand would. Who can be aimed at, where the crosshair is and what is in sight come in from outside,
-- so tests/aim_test.lua runs it without a game. Which point of a body it goes for is hitbox.lua
local aim_math = require("./aim_math")
local hitbox = require("./hitbox")
local num = require("./num")

local aim = {}

aim.looks_per_frame = 48    -- points asked whether they are in sight, for all the targets of a frame: a look is a ray through the world

local max_frame = 0.1       -- seconds: a longer pause between two frames is a hitch, not time to make up for
local sticky_factor = 1.5   -- the one aimed at is kept this many radii away
local body_reach = 4        -- studs: no part of a body is further from its root

local Aim = {}
Aim.__index = Aim

-- deps:
--   project(x, y, z) -> screenX, screenY, visible
--   mouse() -> x, y                  where the crosshair is: the cursor, which a game keeps in the middle while it turns the camera
--   move(dx, dy)                     counts for the mouse
--   sees(x, y, z, record) -> boolean nothing of the world is between the camera and that point of that character
function aim.new(deps)
    return setmetatable({
        deps = deps,
        controller = aim_math.newController(),
        current = nil,      -- the key of the record that is aimed at
        last = nil,         -- when the last frame was
        boxes = {},         -- the parts of the body that is being looked at, filled again for every body
    }, Aim)
end

local function inSight()
    return true
end

-- one frame. targets are the tables of players.target; a is settings.aim in effect; held says the key is down
-- gives back the target that is aimed at, nil when there is none
-- who the aim would go for now, and where on him: { target, ex, ey, far } or nil. The crosshair is at centerX, centerY
-- moves nothing and draws nothing
function Aim:choose(targets, a, teamCheck, centerX, centerY)
    local deps = self.deps
    -- fullScreen: радиус бесконечен, любой враг в поле зрения — валидная цель
    local effRadius = a.fullScreen and 1e9 or a.radius
    local reach = effRadius * sticky_factor

    -- who can be aimed at at all, and how far from the crosshair each is: the bodies are looked at in that order,
    -- the one that is aimed at first
    local near = {}
    for _, target in targets do
        local record = target.record

        -- a character the game has put away is not where its model lies
        if (teamCheck and target.sameTeam) or target.hidden or (a.skipProtected and record.shielded) then
            continue
        end

        -- the distance is unknown while the user has no character, nobody is filtered then
        if target.haveDistance and target.distance > a.maxDistance then
            continue
        end

        local rootX, rootY, visible = deps.project(target.x, target.y, target.z)
        if not visible or not num.finite(rootX) or not num.finite(rootY) then
            continue
        end

        -- a body whose root is further from the circle than a body reaches has no point in it; dropping it here
        -- saves reading its parts, and the looks
        local size = 0
        local upX, upY, upVisible = deps.project(target.x, target.y + body_reach, target.z)
        if upVisible and num.finite(upX) and num.finite(upY) then
            size = math.sqrt((upX - rootX) ^ 2 + (upY - rootY) ^ 2)
        end

        local away = math.sqrt((rootX - centerX) ^ 2 + (rootY - centerY) ^ 2)
        if away > reach + size then
            continue
        end

        local kept = record.key == self.current
        table.insert(near, { target = target, away = if kept then -1 else away, kept = kept })
    end

    table.sort(near, function(p, q)
        return p.away < q.away
    end)

    local looks = aim.looks_per_frame
    local chosen = nil

    for _, entry in near do
        local target = entry.target
        local record = target.record

        -- the one aimed at is held on to a little outside the circle too: it is finished before another is taken
        local limit = if entry.kept then reach else effRadius

        local function offset(x, y, z)
            local screenX, screenY, visible = deps.project(x, y, z)
            if not visible or not num.finite(screenX) or not num.finite(screenY) then
                return nil
            end

            local ex, ey = screenX - centerX, screenY - centerY
            if ex * ex + ey * ey > limit * limit then
                return nil
            end

            return ex, ey
        end

        local boxes = hitbox.read(record.parts, self.boxes)
        if #boxes == 0 then
            boxes = hitbox.standIns(target.x, target.y, target.z, a.zones)
        end

        local choice = nil
        if a.visibleOnly then
            if looks <= 0 then
                break
            end

            choice, looks = hitbox.choose(boxes, a.zones, a.nearestPoint, a.multipoint, a.pointInset, offset, function(x, y, z)
                return deps.sees(x, y, z, record)
            end, looks)
        else
            choice = hitbox.choose(boxes, a.zones, a.nearestPoint, a.multipoint, a.pointInset, offset, inSight, math.huge)
        end

        if choice == nil then
            continue
        end

        local candidate = { target = target, ex = choice.dx, ey = choice.dy, far = choice.far,
            x = choice.x, y = choice.y, z = choice.z, zone = choice.zone,
            health = if target.haveHealth then target.healthFraction else 1 }

        if entry.kept then
            chosen = candidate
            break
        end

        -- the nearest one, or with weakestFirst the one with the least health (the nearer of two equally hurt)
        local better = chosen == nil
        if not better then
            if a.weakestFirst and candidate.health ~= chosen.health then
                better = candidate.health < chosen.health
            else
                better = candidate.far < chosen.far
            end
        end

        if better then
            chosen = candidate
        end
    end

    return chosen
end

-- the same from outside, with the crosshair where the cursor is: whom the aim would go for, nil for nobody
-- (the auto stop asks this before the crosshair is on anybody)
function Aim:pick(targets, a, teamCheck)
    local centerX, centerY = self.deps.mouse()
    local chosen = self:choose(targets, a, teamCheck, centerX, centerY)
    return if chosen ~= nil then chosen.target else nil
end

-- the pick with the 3D point to aim at: { target, x, y, z, zone }, nil for nobody. For silent aim, which does not
-- move the mouse but rewrites the shot direction instead; see nospread.lua
function Aim:pickWorld(targets, a, teamCheck)
    local centerX, centerY = self.deps.mouse()
    local chosen = self:choose(targets, a, teamCheck, centerX, centerY)
    if chosen == nil then
        return nil
    end
    return { target = chosen.target, x = chosen.x, y = chosen.y, z = chosen.z, zone = chosen.zone }
end

function Aim:update(targets, a, teamCheck, held, now, d)
    local deps = self.deps
    local centerX, centerY = deps.mouse()

    -- при fullScreen круг не рисуем (слишком большой), и в silent-режиме курсор не двигаем
    if a.showFov and not a.fullScreen then
        d.circle(centerX, centerY, a.radius, 255, 255, 255)
    end

    -- the very first frame is taken for an ordinary one
    local dt = 1 / 60
    if self.last ~= nil then
        dt = math.clamp(now - self.last, 0, max_frame)
    end
    self.last = now

    if not held then
        aim_math.reset(self.controller)
        self.current = nil

        -- the choice is made while the key is up too, for the mark on the point; without the mark it is for nothing
        if not a.showPoint then
            self.picked = nil
            self.pickedAt = nil
            return nil
        end
    end

    local chosen = self:choose(targets, a, teamCheck, centerX, centerY)
    -- what was chosen on this frame, and by which settings, for whoever asks after it
    self.picked = if chosen ~= nil then chosen.target else nil
    self.pickedAt = now
    self.pickedWith = a

    if chosen ~= nil and a.showPoint then
        local x, y = math.floor(centerX + chosen.ex + 0.5), math.floor(centerY + chosen.ey + 0.5)
        d.dot(x, y, 4, 0, 0, 0)
        d.dot(x, y, 2, 255, 255, 255)
    end

    if not held then
        return nil
    end

    if chosen == nil then
        aim_math.reset(self.controller)
        self.current = nil
        return nil
    end

    local key = chosen.target.record.key
    if key ~= self.current then
        aim_math.reset(self.controller)
        self.current = key
    end

    local moveX, moveY = aim_math.step(self.controller, chosen.ex, chosen.ey, a.speed, dt)
    if moveX ~= 0 or moveY ~= 0 then
        deps.move(moveX, moveY)
    end

    return chosen.target
end

return aim
end

__modules["autofarm"] = function(require)
-- the auto farm of YBA: the items of the kinds the user picked, one after another, are taken the way a player takes
-- them: the character is moved to the item and the key of its prompt is held for as long as the prompt asks.
-- What an item of the world is (tools/yba_probe2.lua): a model in Workspace.Item_Spawns.Items with two prompts, the
-- one that works Enabled with MaxActivationDistance 8 and HoldDuration 0.2, the other off at 0; the game gives the
-- client only the items within some 150 studs of the character.
-- The move is deferred to a glider (glider.lua): the farm asks moveTo(x, y, z) and then polls arrived() every
-- frame; the glider slides the character over several frames so the host does not snap to the item in one tick
-- (tools/yba_probe3.lua: that is the pattern Slowc2960 and other YBA farmers use)
-- the prompt is held through its own InputHoldBegin and InputHoldEnd, the way a prompt with a custom look takes the
-- press of its key; pure logic over what it is given, checked by tests/autofarm_test.lua
local autofarm = {}

autofarm.above = 2.5        -- studs above the item the character is put: within the 8 the prompt works at
autofarm.settle = 0.15      -- seconds after the move before the key goes down: the prompt has to see the character there
autofarm.extra_hold = 0.1   -- seconds the key is held beyond what the prompt asks
autofarm.give_up = 1.5      -- seconds after the key came up for the item to go
autofarm.skip_for = 10      -- seconds an item that did not go is left alone

local Farm = {}
Farm.__index = Farm

-- deps:
--   moveTo(x, y, z)        starts moving the character there (through the glider, in practice)
--   arrived() -> boolean   true once the character is at the last point moveTo was given
--   stopMoving()           optional: tells the glider to drop its goal (asked when a run is cancelled)
--   holdBegin(prompt), holdEnd(prompt)
function autofarm.new(deps)
    return setmetatable({
        deps = deps,
        state = "idle",         -- "idle", "moving", "arriving", "holding" or "waiting"
        target = nil,           -- the entry of items.lua being taken
        since = 0,
        skipped = {},           -- prompt -> when it was given up on
        taken = 0,              -- items that went after the key was held
    }, Farm)
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- whether the prompt of an entry works: on, and within reach of somebody at all
local function working(entry)
    local prompt = entry.prompt
    local reach = prompt.MaxActivationDistance
    return prompt.Enabled == true and finite(reach) and reach > 0
end

-- lets go of the key if it is held, tells the glider to forget its goal, and forgets the item
function Farm:stop()
    if self.state == "holding" and self.target ~= nil then
        self.deps.holdEnd(self.target.prompt)
    end

    if self.deps.stopMoving ~= nil then
        self.deps.stopMoving()
    end

    self.state = "idle"
    self.target = nil
end

-- one step, on every frame while the farm is on
--   entries: of items.lua; kinds: the set of kinds to take (ids of item_kinds); position(entry) -> x, y, z or nil
--   meX, meY, meZ: where the character of the user is, nil while there is none (nothing is done then)
-- gives back the entry being taken, nil for none
function Farm:update(now, entries, kinds, position, meX, meY, meZ)
    if meX == nil then
        self:stop()
        return nil
    end

    local target = self.target
    local gone = target ~= nil and (position(target) == nil or not working(target))

    -- a kind the user does not want any more: left where it is, not counted
    if target ~= nil and not gone and (kinds == nil or kinds[target.kind] ~= true) then
        self:stop()
        target = nil
    end

    if self.state == "moving" then
        if gone then
            self:stop()
        elseif self.deps.arrived() then
            self.state = "arriving"
            self.since = now
        end
    elseif self.state == "arriving" then
        if gone then
            self:stop()
        elseif now - self.since >= autofarm.settle then
            self.deps.holdBegin(target.prompt)
            self.state = "holding"
            self.since = now
        end
    elseif self.state == "holding" then
        local hold = target.prompt.HoldDuration
        if not finite(hold) or hold < 0 then
            hold = 0
        end

        if gone then
            self:stop()
            self.taken += 1
        elseif now - self.since >= hold + autofarm.extra_hold then
            self.deps.holdEnd(target.prompt)
            self.state = "waiting"
            self.since = now
        end
    elseif self.state == "waiting" then
        if gone then
            self.taken += 1
            self.state = "idle"
            self.target = nil
        elseif now - self.since >= autofarm.give_up then
            -- did not go: somebody else's, or not to be taken by this; left alone for a while
            self.skipped[target.prompt] = now
            self.state = "idle"
            self.target = nil
        end
    end

    if self.state ~= "idle" then
        return self.target
    end

    -- the nearest item of a kind picked, with a prompt that works, not given up on lately
    local best, bestDistance = nil, math.huge
    local bestX, bestY, bestZ = 0, 0, 0
    for _, entry in entries do
        if entry.part == nil or kinds == nil or kinds[entry.kind] ~= true or not working(entry) then
            continue
        end

        local skippedAt = self.skipped[entry.prompt]
        if skippedAt ~= nil and now - skippedAt < autofarm.skip_for then
            continue
        end

        local x, y, z = position(entry)
        if x == nil then
            continue
        end

        local dx, dy, dz = x - meX, y - meY, z - meZ
        local distance = dx * dx + dy * dy + dz * dz
        if distance < bestDistance then
            best, bestDistance = entry, distance
            bestX, bestY, bestZ = x, y, z
        end
    end

    if best == nil then
        return nil
    end

    self.target = best
    self.state = "moving"
    self.since = now
    self.deps.moveTo(bestX, bestY + autofarm.above, bestZ)
    return best
end

return autofarm
end

__modules["autostop"] = function(require)
-- the auto stop: before the auto fire shoots, the user is stopped, so that the shot goes where the crosshair is
-- a shot of Blox Strike spreads by the speed of the user once it is above 6.4 studs a second (and by the speed of the
-- jump in the air): an AK-47 spreads 0.25 degrees standing and some 24 running (Components.Weapon.Classes.Bullet)
-- stopping is done the way a player does it: walking against the motion until it is slow, then standing; the game is
-- told that walk through the same function the controls of Roblox tell it the keys with, see strike_move.lua
-- pure logic, checked by tests/autostop_test.lua
local autostop = {}

autostop.threshold = 6.4    -- studs a second: slower than this, moving does not spread a shot
local settle = 1.5          -- studs a second: slower than this, walking against the motion would start a walk back
autostop.patience = 0.5     -- seconds a shot waits for a stop on the ground; a stop takes a fraction of that

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- whether a shot goes where the crosshair is: on the ground and slower than the threshold along the ground
function autostop.accurate(vx, vz, onGround)
    return onGround == true and finite(vx) and finite(vz) and vx * vx + vz * vz < autostop.threshold * autostop.threshold
end

-- the direction to tell the game to walk, in the world, to stop as soon as it can: against the motion along the
-- ground while that is fast, nothing once it is slow; nil when the input of the user is to be left alone (in the air
-- walking stops nothing)
function autostop.input(vx, vz, onGround)
    if onGround ~= true or not finite(vx) or not finite(vz) then
        return nil
    end

    local speed = math.sqrt(vx * vx + vz * vz)
    if speed < settle then
        return 0, 0
    end

    return -vx / speed, -vz / speed
end

-- whether the user is to be stopped now
--   kind: "Off", "OnTarget" (the crosshair is on somebody to shoot at) or "Early" (that, or somebody to shoot at is in
--   the circle of the aim already, before the crosshair is on him)
function autostop.wanted(kind, onTarget, inCircle)
    if kind == "OnTarget" then
        return onTarget == true
    elseif kind == "Early" then
        return onTarget == true or inCircle == true
    end

    return false
end

return autostop
end

__modules["bhop"] = function(require)
-- the bhop: while the jump key is held, the jump is made again the moment the ground is touched
-- for a game with the movement of a shooter of the old school, where a jump takes a new press of the key, made
-- while standing on the ground: a key that is held does nothing, and a press that comes a few ticks late costs speed
-- nothing of the game is changed and nothing is sent by the script: the game is told "the jump key is down / up"
-- through the same switch its own handler of the key uses, see strike_move.lua. Checked by tests/bhop_test.lua
local bhop = {}

local deaf_after = 0.25     -- seconds in the air with the jump let go of, after which a button still down in the commands
                            -- of the game means the game does not follow what it is told

local Bhop = {}
Bhop.__index = Bhop

-- deps:
--   state() -> table or nil    the movement state of the game after its last tick: OnGround, MovementMode, PreviousButtons
--   setJump(pressed)           the switch of the game
--   jumpDown(buttons) -> boolean   whether the jump is down in those buttons, as the game itself reads them;
--                              nil when the script does not know how the game reads them
--   ineffective()              called once when the game turns out not to follow the switch
function bhop.new(deps)
    return setmetatable({
        deps = deps,
        airSince = nil,     -- since when the jump has been let go of in the air without a break
        reported = false,
    }, Bhop)
end

-- every frame, before the game steps its movement; held says the jump key is down
function Bhop:update(held, now)
    if not held then
        -- the key going up is told to the game by its own handler
        self.airSince = nil
        return
    end

    local state = self.deps.state()
    if type(state) ~= "table" or type(state.OnGround) ~= "boolean" then
        return
    end

    -- on a ladder the first press is the jump off it: the key is left as the user has it
    local want = state.OnGround or state.MovementMode == "Ladder"

    -- on every frame, not only on a change: the handler of the game sets the switch too, whenever the key goes down
    self.deps.setJump(want)

    if want then
        self.airSince = nil
        return
    end

    if self.airSince == nil then
        self.airSince = now
        return
    end

    -- the commands the game makes should have the button up by now
    local jumpDown = self.deps.jumpDown
    if not self.reported and jumpDown ~= nil and now - self.airSince >= deaf_after then
        local buttons = state.PreviousButtons
        if type(buttons) == "number" and jumpDown(buttons) then
            self.reported = true
            self.deps.ineffective()
        end
    end
end

return bhop
end

__modules["chams"] = function(require)
-- Chams: подсвечиваю чужих моделей сквозь стены через нативный Highlight API Roblox.
-- Один Highlight на character, живёт столько сколько character; при респавне Roblox сам
-- убирает его вместе со старой моделью. При выключении — Destroy всех и чистка кэша.
-- Фильтры (hideInvincible, teamCheck, hidden) смотрит те же что ESP, чтобы не рисовать
-- там, где игрок исключён из таргетов.
-- pure logic over deps, checked by tests/chams_test.lua
local chams = {}

local Chams = {}
Chams.__index = Chams

-- deps:
--   Instance    env.Instance (для Instance.new("Highlight"))
--   Color3      env.Color3
--   Enum        env.Enum (для HighlightDepthMode: AlwaysOnTop | Occluded)
function chams.new(deps)
    return setmetatable({
        deps = deps,
        cache = {},   -- [character Model] = Highlight instance
    }, Chams)
end

local function pickDepth(Enum, throughWalls)
    local m = Enum and Enum.HighlightDepthMode
    if m == nil then return nil end
    return if throughWalls then m.AlwaysOnTop else m.Occluded
end

-- s: таблица settings в кадре — читает s.chams (enabled/fillColor/fillTransparency/...),
-- и глобальные фильтры s.hideInvincible, s.teamCheck
function Chams:step(targets, s)
    local c = s and s.chams
    if c == nil or not c.enabled then
        if next(self.cache) ~= nil then
            self:cleanup()
        end
        return
    end

    local Color3 = self.deps.Color3
    local fill = c.fillColor or { 255, 50, 50 }
    local outline = c.outlineColor or { 0, 0, 0 }
    local fillColor = Color3.fromRGB(fill[1], fill[2], fill[3])
    local outlineColor = Color3.fromRGB(outline[1], outline[2], outline[3])
    local fillT = (c.fillTransparency or 50) / 100
    local outlineT = (c.outlineTransparency or 0) / 100
    local depthMode = pickDepth(self.deps.Enum, c.throughWalls ~= false)

    local wanted = {}
    for _, target in targets do
        local record = target.record
        local char = record and record.character
        if char == nil then continue end
        if target.hidden then continue end
        if s.hideInvincible and record.shielded then continue end
        if s.teamCheck and target.sameTeam then continue end

        local h = self.cache[char]
        -- character мог освободиться (респавн) — старый Highlight уже умер вместе с ним
        if h == nil or h.Parent ~= char then
            h = self.deps.Instance.new("Highlight")
            h.Adornee = char
            h.Parent = char
            self.cache[char] = h
        end
        h.FillColor = fillColor
        h.OutlineColor = outlineColor
        h.FillTransparency = fillT
        h.OutlineTransparency = outlineT
        if depthMode then
            h.DepthMode = depthMode
        end
        h.Enabled = true
        wanted[char] = true
    end

    for char, h in self.cache do
        if not wanted[char] then
            pcall(function() h:Destroy() end)
            self.cache[char] = nil
        end
    end
end

function Chams:cleanup()
    for _, h in self.cache do
        pcall(function() h:Destroy() end)
    end
    table.clear(self.cache)
end

return chams
end

__modules["clouds"] = function(require)
-- the smokes and the fires on the ground in Blox Strike, as its server tells about them: a smoke is a set of voxels
-- the packet VFX.CreateVoxelSmoke brings ({ SmokeId, Duration, DeployTime, Team, Voxels = { { Position, Size } } },
-- tools/strike_probe8.lua), VFX.DestroyVoxelSmoke takes it away by its id; a fire comes the same way through
-- VFX.CreateVoxelFire, grows through VFX.UpdateVoxelFire and goes through VFX.DestroyVoxelFire. What a fire packet
-- holds was not seen yet, so it is read the way a smoke is, by what it has: an id, voxels with a Position, a Duration
-- drawn: a ring on the ground around the voxels (how far the cloud reaches) and the time it has left
-- pure logic, checked by tests/clouds_test.lua
local clouds = {}

local default_size = 4      -- studs: the side of a voxel of a smoke of the game
local ring_steps = 32       -- pieces of the ring
local linger = 2            -- seconds a cloud past its duration is kept, if the word of its end does not come
local hold_on = 60          -- seconds a cloud with no duration is kept, if the word of its end does not come

local style = {
    smoke = { r = 200, g = 200, b = 210, label = "SMOKE" },
    fire = { r = 255, g = 120, b = 40, label = "FIRE" },
}

local Clouds = {}
Clouds.__index = Clouds

function clouds.new()
    return setmetatable({ list = {} }, Clouds)
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- the id of a cloud: the packet of an end is the id itself; a packet of a beginning has it in SmokeId, FireId or Id,
-- or else in any text field whose name ends with Id
local function idOf(payload)
    if type(payload) == "string" then
        return payload
    end

    if type(payload) ~= "table" then
        return nil
    end

    for _, key in { "SmokeId", "FireId", "Id", "ID" } do
        local value = payload[key]
        if type(value) == "string" or type(value) == "number" then
            return tostring(value)
        end
    end

    for key, value in payload do
        if type(key) == "string" and string.sub(key, -2) == "Id" and (type(value) == "string" or type(value) == "number") then
            return tostring(value)
        end
    end

    return nil
end

-- the place of a voxel: a Vector3 or a table with X, Y and Z
local function placeOf(voxel)
    local position = if type(voxel) == "table" then voxel.Position else nil
    if position == nil then
        return nil
    end

    local ok, x, y, z = pcall(function()
        return position.X, position.Y, position.Z
    end)

    if ok and finite(x) and finite(y) and finite(z) then
        return x, y, z
    end

    return nil
end

-- the voxels of a packet, added to into (keyed by where they stand, so a voxel told twice is one)
local function readVoxels(payload, into)
    local list = if type(payload) == "table" then payload.Voxels else nil
    if type(list) ~= "table" then
        return
    end

    for _, voxel in list do
        local x, y, z = placeOf(voxel)
        if x ~= nil then
            local size = voxel.Size
            if not finite(size) then
                -- a Vector3 size: the widest side
                local ok, sx, sy, sz = pcall(function()
                    return size.X, size.Y, size.Z
                end)
                size = if ok and finite(sx) and finite(sy) and finite(sz) then math.max(sx, sy, sz) else default_size
            end

            into[string.format("%.1f,%.1f,%.1f", x, y, z)] = { x = x, y = y, z = z, size = size }
        end
    end
end

-- where the cloud stands: the middle of its voxels across the ground, how far from it they reach (to the corner of
-- the farthest), its floor and its top
local function shape(entry)
    local count, sumX, sumZ = 0, 0, 0
    local floor, top = math.huge, -math.huge
    for _, voxel in entry.voxels do
        count += 1
        sumX += voxel.x
        sumZ += voxel.z
        floor = math.min(floor, voxel.y - voxel.size * 0.5)
        top = math.max(top, voxel.y + voxel.size * 0.5)
    end

    if count == 0 then
        return false
    end

    local cx, cz = sumX / count, sumZ / count
    local reach = 0
    for _, voxel in entry.voxels do
        local dx, dz = voxel.x - cx, voxel.z - cz
        reach = math.max(reach, math.sqrt(dx * dx + dz * dz) + voxel.size * 0.5 * math.sqrt(2))
    end

    entry.x, entry.z, entry.radius, entry.floor, entry.top, entry.count = cx, cz, reach, floor, top, count
    return true
end

-- a cloud begins: kind is "smoke" or "fire"; now is the local clock. Gives back whether it was taken
function Clouds:create(kind, payload, now)
    local id = idOf(payload)
    if id == nil then
        return false
    end

    local entry = { kind = kind, id = id, voxels = {}, born = now, duration = nil }
    readVoxels(payload, entry.voxels)
    if not shape(entry) then
        return false
    end

    if finite(payload.Duration) and payload.Duration > 0 then
        entry.duration = payload.Duration
    end

    self.list[kind .. ":" .. id] = entry
    return true
end

-- a cloud grows (a fire spreading): its new voxels join it; one not heard of before begins with them
function Clouds:update(kind, payload, now)
    local id = idOf(payload)
    local entry = if id ~= nil then self.list[kind .. ":" .. id] else nil
    if entry == nil then
        return self:create(kind, payload, now)
    end

    readVoxels(payload, entry.voxels)
    shape(entry)
    if finite(payload.Duration) and payload.Duration > 0 then
        entry.duration = payload.Duration
        entry.born = now
    end

    return true
end

-- a cloud ends
function Clouds:destroy(kind, payload)
    local id = idOf(payload)
    if id ~= nil then
        self.list[kind .. ":" .. id] = nil
    end
end

function Clouds:clear()
    table.clear(self.list)
end

function Clouds:count()
    local count = 0
    for _ in self.list do
        count += 1
    end

    return count
end

-- the seconds a cloud has left, nil when its duration was not told
function clouds.left(entry, now)
    if entry.duration == nil then
        return nil
    end

    return math.max(0, entry.born + entry.duration - now)
end

-- drops what is past its time and the word of whose end did not come
function Clouds:expire(now)
    for key, entry in self.list do
        local over = if entry.duration ~= nil then entry.born + entry.duration + linger else entry.born + hold_on
        if now > over then
            self.list[key] = nil
        end
    end
end

-- the ring of every cloud on its floor, and over its middle what it is and the time it has left
--   project(x, y, z) -> screenX, screenY, visible; d is draw.lua; wanted[kind] says which kinds are drawn
function Clouds:draw(now, wanted, project, d)
    self:expire(now)

    for _, entry in self.list do
        if not wanted[entry.kind] then
            continue
        end

        local look = style[entry.kind] or style.smoke
        local lastX, lastY, lastVisible = nil, nil, false
        for step = 0, ring_steps do
            local angle = 2 * math.pi * step / ring_steps
            local screenX, screenY, visible = project(entry.x + math.cos(angle) * entry.radius, entry.floor,
                entry.z + math.sin(angle) * entry.radius)
            visible = visible and finite(screenX) and finite(screenY)

            if visible and lastVisible then
                d.line(lastX, lastY, screenX, screenY, look.r, look.g, look.b, 1)
            end

            lastX, lastY, lastVisible = screenX, screenY, visible
        end

        local screenX, screenY, visible = project(entry.x, entry.floor + 0.5, entry.z)
        if visible and finite(screenX) and finite(screenY) then
            local left = clouds.left(entry, now)
            local text = if left ~= nil then string.format("%s %.0f s", look.label, math.ceil(left)) else look.label
            d.textCentered(math.floor(screenX + 0.5), math.floor(screenY + 0.5), look.r, look.g, look.b, text)
        end
    end
end

return clouds
end

__modules["diag"] = function(require)
-- what the script is doing, written to a file while it is asked for (getgenv().CalciteDiagnostics = true; there is
-- no switch for it in the menu: it is a tool for finding a fault, not a feature)
-- a script in a game cannot be watched from outside: what it warns about goes to the console of the game, and
-- "it does not work" tells nothing of where. With the diagnostics on, every part says what it knows right now
-- (state: a value whose changes are remembered; number: a value that is only shown), and once a second the lot is
-- written out, to be read from the disk. Off, it keeps nothing and costs nothing
-- pure logic: the writing comes in as a function; checked by tests/diag_test.lua
local diag = {}

diag.interval = 1           -- seconds between two writes
diag.max_events = 150       -- changes and events that are kept, the newest

local max_text = 160        -- a value longer than this is cut

local Diag = {}
Diag.__index = Diag

-- deps: write(text), started (the clock at the start of the script: times are told from it)
function diag.new(deps)
    return setmetatable({
        deps = deps,
        on = false,
        values = {},        -- key -> text
        keys = {},          -- the keys in the order they first came
        events = {},
        lastWrite = -math.huge,
    }, Diag)
end

local function textOf(value)
    local kind = type(value)
    if kind == "string" then
        if #value > max_text then
            return string.sub(value, 1, max_text) .. "..."
        end

        return value
    elseif kind == "number" then
        return string.format("%g", value)
    elseif kind == "nil" or kind == "boolean" then
        return tostring(value)
    end

    return kind
end

function Diag:set(on, now)
    if on == self.on then
        return
    end

    self.on = on
    table.clear(self.values)
    table.clear(self.keys)
    table.clear(self.events)
    self.lastWrite = -math.huge

    if on then
        self:event("diagnostics on", now)
    end
end

function Diag:event(text, now)
    if not self.on then
        return
    end

    table.insert(self.events, string.format("%6.1f s  %s", now - self.deps.started, textOf(text)))
    if #self.events > diag.max_events then
        table.remove(self.events, 1)
    end
end

local function put(self, key, text)
    if self.values[key] == nil then
        table.insert(self.keys, key)
    end

    self.values[key] = text
end

-- a value whose changes are worth remembering: what a part of the script has decided
function Diag:state(key, value, now)
    if not self.on then
        return
    end

    local text = textOf(value)
    local before = self.values[key]
    if before ~= nil and before ~= text then
        self:event(key .. ": " .. before .. " -> " .. text, now)
    end

    put(self, key, text)
end

-- a value that changes all the time and is only shown as it is now
function Diag:number(key, value)
    if not self.on then
        return
    end

    put(self, key, textOf(value))
end

-- writes the lot when its time has come
function Diag:flush(now, header)
    if not self.on or now - self.lastWrite < diag.interval then
        return
    end

    self.lastWrite = now

    local lines = { header, string.format("seconds since the start: %.1f", now - self.deps.started), "", "NOW" }

    local keys = table.clone(self.keys)
    table.sort(keys)
    for _, key in keys do
        table.insert(lines, "  " .. key .. " = " .. self.values[key])
    end

    table.insert(lines, "")
    table.insert(lines, "CHANGES AND EVENTS (the newest last)")
    for _, event in self.events do
        table.insert(lines, "  " .. event)
    end

    local write = self.deps.write
    pcall(function()
        write(table.concat(lines, "\n"))
    end)
end

return diag
end

__modules["draw"] = function(require)
-- the only place that calls DrawingImmediate; everything above it works in plain numbers:
-- pixels for places, 0..255 for colours. Its functions may be called only while a frame is being painted
local draw = {}

local font_size = 16        -- the external writes in Segoe UI of this size
local line_height = 16
local max_widths = 2000     -- strings whose width is remembered; distances keep making new ones

function draw.new(env)
    local immediate = env.DrawingImmediate
    local Vector2 = env.Vector2
    local Color3 = env.Color3
    local font = env.Drawing.Fonts.UI
    local black = Color3.new(0, 0, 0)

    local self = { font_size = font_size, line_height = line_height }
    local visible = true
    function self.setVisible(value) visible = value == true end

    -- DrawingImmediate cannot measure text; a text object that is never shown can
    local ruler = env.Drawing.new("Text")
    ruler.Visible = false
    ruler.Font = font
    ruler.Size = font_size

    local widths = {}
    local remembered = 0

    function self.textWidth(text)
        local width = widths[text]
        if width == nil then
            if remembered >= max_widths then
                table.clear(widths)
                remembered = 0
            end

            ruler.Text = text
            width = ruler.TextBounds.X
            widths[text] = width
            remembered += 1
        end

        return width
    end

    -- the outline of a rectangle, one pixel thick
    function self.rect(left, top, right, bottom, r, g, b)
        immediate.Rectangle(Vector2.new(left, top), Vector2.new(right - left, bottom - top), Color3.fromRGB(r, g, b), 1, 0, 1)
    end

    function self.filledRect(left, top, right, bottom, r, g, b)
        immediate.FilledRectangle(Vector2.new(left, top), Vector2.new(right - left, bottom - top), Color3.fromRGB(r, g, b), 1, 0)
    end

    -- a filled circle, drawn as a square rounded all the way: the documentation gives the arguments of FilledCircle
    -- in another order than those of Circle, and one of the two is a mistake
    function self.dot(x, y, radius, r, g, b, opacity)
        immediate.FilledRectangle(Vector2.new(x - radius, y - radius), Vector2.new(radius * 2, radius * 2),
            Color3.fromRGB(r, g, b), opacity or 1, radius)
    end

    -- the outline of a circle, one pixel thick
    function self.circle(x, y, radius, r, g, b)
        immediate.Circle(Vector2.new(x, y), radius, Color3.fromRGB(r, g, b), 1, 64, 1)
    end

    -- a line one pixel thick
    function self.line(x1, y1, x2, y2, r, g, b, opacity)
        immediate.Line(Vector2.new(x1, y1), Vector2.new(x2, y2), Color3.fromRGB(r, g, b), opacity or 1, 1)
    end

    -- text with a black outline, readable over any background; opacity below 1 fades the outline with the text
    function self.text(x, y, r, g, b, text, opacity)
        opacity = opacity or 1
        immediate.OutlinedText(Vector2.new(x, y), font, font_size, Color3.fromRGB(r, g, b), opacity, black, opacity, text, false)
    end

    -- the same, centred on x
    function self.textCentered(x, y, r, g, b, text, opacity)
        opacity = opacity or 1
        immediate.OutlinedText(Vector2.new(x, y), font, font_size, Color3.fromRGB(r, g, b), opacity, black, opacity, text, true)
    end

    for _, name in { "rect", "filledRect", "dot", "circle", "line", "text", "textCentered" } do
        local paint = self[name]
        self[name] = function(...)
            if visible then paint(...) end
        end
    end

    function self.destroy()
        ruler:Remove()
    end

    return self
end

return draw
end

__modules["env"] = function(require)
-- everything the script takes from the game and from the executor, in one table: the only module that touches
-- the globals, so that the rest can be run and checked without either
local env = {}

function env.fromGlobals()
    return {
        game = game,
        workspace = workspace,
        Vector2 = Vector2,
        Vector3 = Vector3,
        CFrame = CFrame,
        Color3 = Color3,
        Enum = Enum,
        -- for the overlays of hud.lua
        Instance = Instance,
        UDim = UDim,
        UDim2 = UDim2,
        Drawing = Drawing,
        DrawingImmediate = DrawingImmediate,
        -- a reference the game cannot tell from its own; where an executor has none, the object itself does
        cloneref = cloneref or function(instance)
            return instance
        end,
        getgenv = getgenv,
        isfile = isfile,
        isfolder = isfolder,
        makefolder = makefolder,
        readfile = readfile,
        writefile = writefile,
        loadstring = loadstring,
        httpGet = function(url)
            return game:HttpGet(url)
        end,
        clock = os.clock,
        -- the other clock of Roblox: the game times the scope of a sniper rifle by it
        tick = tick,
        warn = warn or print,
        print = print,
        -- the tables of the game, what a function of it holds on to, and threads: for finding the packets
        -- through which a game tells about its sounds, see strike_net.lua
        getgc = getgc,
        -- the mouse of the executor, the rays of the engine, and whether the window of the game is in front: for the aim
        mousemoverel = mousemoverel,
        -- the left button of the mouse, for the auto fire
        mouse1press = mouse1press,
        mouse1release = mouse1release,
        RaycastParams = RaycastParams,
        isrbxactive = isrbxactive,
        -- presses a prompt of the world without walking up to it: for the NPCs of YBA and the eggs of Steal an Egg
        fireproximityprompt = fireproximityprompt,
        getupvalues = debug and debug.getupvalues,
        -- require as the executor gives it: the modules of the script are glued with a require of their own, which
        -- would shadow it; for reading what a module of the game says about a weapon
        gameRequire = (getgenv and getgenv().require) or getfenv(0).require,
        task = task,
        -- хуки C-функций: Town silent aim ставит hookfunction на workspace.Raycast + newcclosure для
        -- замены C-closure (НЕ hookmetamethod на __namecall — Town кикает за namecall-детектор)
        hookfunction = hookfunction,
        newcclosure = newcclosure,
        -- VirtualInputManager: эмулирует настоящий клик для rage autoFire — Roblox прокидывает в
        -- Mouse.Button1Down (на который слушает GunScript Town). GunScript сам делает выстрел с
        -- анимацией + звуком + обновлением ClientAmmo, наш хук workspace.Raycast подменяет направление
        virtualInputManager = (function()
            if game == nil then return nil end
            local ok, vim = pcall(function() return game:GetService("VirtualInputManager") end)
            return ok and vim or nil
        end)(),
    }
end

return env
end

__modules["esp_items"] = function(require)
-- the label of an item: a dot where it is, its name above and the distance below
-- a port of features/items.cpp of the external; checked by tests/esp_items_test.lua
local item_kinds = require("./item_kinds")
local num = require("./num")

local esp_items = {}

-- items is the registry of items.lua, already matched against the choice of the user; s is settings.items
-- a kind of item_kinds with a color of its own is labelled in it, the rest in the color the user picked
-- the distances are measured from the reference point: the character of the user, or the camera while there is none,
-- so that the range keeps working and the whole map is not labelled after every death
function esp_items.draw(items, s, screenW, screenH, project, d, refX, refY, refZ)
    local lineHeight = d.line_height

    for _, entry in items.entries do
        if not entry.shown then
            continue
        end

        local color = item_kinds.color(entry.kind) or s.color
        local r, g, b = color[1], color[2], color[3]

        -- nil for what was taken out of the world or switched off since it was found
        local x, y, z = items:position(entry)
        if x == nil then
            continue
        end

        local dx, dy, dz = x - refX, y - refY, z - refZ
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        if distance > s.maxDistance then
            continue
        end

        local pixelX, pixelY, visible = project(x, y, z)
        if not visible or not num.finite(pixelX) or not num.finite(pixelY) then
            continue
        end

        if pixelX < -100 or pixelY < -100 or pixelX > screenW + 100 or pixelY > screenH + 100 then
            continue
        end

        pixelX = math.floor(pixelX)
        pixelY = math.floor(pixelY)

        d.dot(pixelX, pixelY, 4, 0, 0, 0)
        d.dot(pixelX, pixelY, 3, r, g, b)

        if entry.name ~= "" then
            d.textCentered(pixelX, pixelY - lineHeight - 6, r, g, b, entry.name)
        end

        d.textCentered(pixelX, pixelY + 6, r, g, b, string.format("%.0f st", distance))
    end
end

return esp_items
end

__modules["esp_players"] = function(require)
-- what is drawn around a player: the box, the health, the name and what is known about the state
-- a port of features/esp.cpp of the external; draws through the layer and the projection it is given,
-- so tests/esp_players_test.lua checks every pixel of it without a game
local health_fade = require("./health_fade")
local kit = require("./kit")
local num = require("./num")
local status = require("./status")

local esp_players = {}

-- studs from the center of HumanoidRootPart, good for avatars of the default scale
local head_offset = 2.8
local feet_offset = 3.0

local abandoned_after = 10      -- seconds without a sample before the health track of a player is forgotten

-- the Time Erase of King Crimson (see players.lua): the place is where the erase began
local erase_color = { 200, 130, 255 }

local limbs = {
    { "left arm", "leftArm" },
    { "right arm", "rightArm" },
    { "left leg", "leftLeg" },
    { "right leg", "rightLeg" },
}

local Esp = {}
Esp.__index = Esp

function esp_players.new()
    -- by the key of the record, so that a track lives through a respawn
    return setmetatable({ tracks = {} }, Esp)
end

-- screen rectangle of a character: left, top, right, bottom
-- nil when the character is behind the camera or the projection is not usable
local function characterBox(x, y, z, project)
    local headX, headY, headVisible = project(x, y + head_offset, z)
    if not headVisible then
        return nil
    end

    local feetX, feetY, feetVisible = project(x, y - feet_offset, z)
    if not feetVisible then
        return nil
    end

    if not (num.finite(headX) and num.finite(headY) and num.finite(feetX) and num.finite(feetY)) then
        return nil
    end

    local height = feetY - headY
    if height <= 0 then
        return nil
    end

    local centerX = (headX + feetX) * 0.5
    return math.floor(centerX - height * 0.25), math.floor(headY), math.floor(centerX + height * 0.25), math.floor(feetY)
end

-- targets are the tables of players.target; s is the settings in effect; now is in seconds
function Esp:draw(targets, s, screenW, screenH, project, d, now)
    -- the percent after a loss of health goes with the bar, always
    local percents = s.healthBar
    local statusKinds = s.statusKinds or {}
    local lineHeight = d.line_height
    local boxR, boxG, boxB = s.boxColor[1], s.boxColor[2], s.boxColor[3]
    local textR, textG, textB = s.textColor[1], s.textColor[2], s.textColor[3]

    for _, target in targets do
        local record = target.record

        -- «Не отображать неуязвимых»: игрок с ForceField/Invincible не рисуется совсем (ни бокс, ни хп).
        -- Отличается от settings.protection (та только добавляет метку Shield рядом с нарисованным ESP)
        if s.hideInvincible and record.shielded then
            continue
        end

        -- followed for everyone, drawn or not: the label has to tell when the health was lost,
        -- not when the player came into view
        local percentShown = 0
        if percents and target.haveHealth then
            local track = self.tracks[record.key]
            if track == nil then
                track = health_fade.newTrack()
                self.tracks[record.key] = track
            end

            percentShown = health_fade.update(track, target.healthFraction, now)
        end

        if s.teamCheck and target.sameTeam then
            continue
        end

        -- the distance is unknown while the user has no character, nobody is filtered then
        if target.haveDistance and target.distance > s.maxDistance then
            continue
        end

        -- erasing time: the box is where the erase began, in a colour of its own
        local erased = target.erased == true
        if erased and not statusKinds.timeErase then
            continue
        end

        -- a character the game has put away: its server tells nothing about it any more, and what can be drawn
        -- is the place it was last at. Drawn dim, so that it is not taken for a character that is there
        local hidden = target.hidden == true and not erased
        if hidden and not s.lastSeen then
            continue
        end

        local frameR, frameG, frameB = boxR, boxG, boxB
        local labelR, labelG, labelB = textR, textG, textB
        if hidden then
            frameR, frameG, frameB = 150, 150, 160
            labelR, labelG, labelB = 170, 170, 180
        elseif erased then
            frameR, frameG, frameB = erase_color[1], erase_color[2], erase_color[3]
            labelR, labelG, labelB = erase_color[1], erase_color[2], erase_color[3]
        end

        local left, top, right, bottom = characterBox(target.x, target.y, target.z, project)
        if left == nil then
            continue
        end

        -- fully off screen, health bar and labels included
        if right < -100 or left > screenW + 100 or bottom < -100 or top > screenH + 100 then
            continue
        end

        -- a whole pixel: the two edges were rounded down separately, so their middle can fall on a half
        local centerX = math.floor((left + right) * 0.5 + 0.5)

        if s.box then
            d.rect(left - 1, top - 1, right + 1, bottom + 1, 0, 0, 0)
            -- far players get boxes too small to have an inside
            if right - left >= 4 then
                d.rect(left + 1, top + 1, right - 1, bottom - 1, 0, 0, 0)
            end
            d.rect(left, top, right, bottom, frameR, frameG, frameB)
        end

        if s.healthBar and target.haveHealth then
            -- a bar of 3 px with a gap of 1 px to the outline of the box, filled from the bottom
            local fraction = target.healthFraction
            local barRight = left - 3
            local barLeft = barRight - 3
            local filledTop = bottom - (bottom - top) * fraction
            -- lerp между цветами «пустой HP» и «полный HP» по fraction. Дефолты (0,255,0 / 255,0,0)
            -- сохраняют старое поведение (чистый красный → чистый зелёный)
            local full = s.healthBarFullColor or { 0, 255, 0 }
            local empty = s.healthBarEmptyColor or { 255, 0, 0 }
            -- без округления: совместимо со старой формулой 255*(1-f) / 255*f (floor без +0.5)
            local inv = 1 - fraction
            local healthR = math.floor(empty[1] * inv + full[1] * fraction)
            local healthG = math.floor(empty[2] * inv + full[2] * fraction)
            local healthB = math.floor(empty[3] * inv + full[3] * fraction)

            d.filledRect(barLeft - 1, top - 1, barRight + 1, bottom + 1, 0, 0, 0)
            d.filledRect(barLeft, filledTop, barRight, bottom, healthR, healthG, healthB)

            if percentShown > 0 then
                -- left of the bar, level with the top of its filled part, kept within the height of the box
                local label = health_fade.percent(fraction) .. "%"
                local lowest = math.max(top, bottom - lineHeight)
                local y = math.clamp(filledTop - lineHeight * 0.5, top, lowest)
                d.text(math.floor(barLeft - 4 - d.textWidth(label)), math.floor(y), healthR, healthG, healthB, label, percentShown)
            end
        end

        -- what is known about the state of the player: a column to the right of the box, from its top
        local columnX = right + 5
        local columnY = top

        -- first, since it decides whether hitting the player is of any use
        if s.protection and record.shielded then
            local look = status.look("Shield")
            d.text(columnX, columnY, look.r, look.g, look.b, look.text)
            columnY += lineHeight
        end

        -- the ping of the player, where the game tells it; a character run by the game has none
        if s.ping and record.ping ~= nil then
            d.text(columnX, columnY, 200, 200, 210, string.format("%d ms", math.floor(record.ping + 0.5)))
            columnY += lineHeight
        end

        -- the effects of the kinds the user picked
        for _, effect in record.statuses do
            if statusKinds[status.kindOf(effect)] then
                local look = status.look(effect)
                d.text(columnX, columnY, look.r, look.g, look.b, look.text)
                columnY += lineHeight
            end
        end

        -- a limb something happened to
        if statusKinds.limbs then
            for _, limb in limbs do
                local line = kit.limb(limb[1], record[limb[2]])
                if line ~= "" then
                    d.text(columnX, columnY, 255, 160, 60, line)
                    columnY += lineHeight
                end
            end
        end

        if s.name and record.name ~= "" then
            d.textCentered(centerX, top - lineHeight - 2, labelR, labelG, labelB, record.name)
        end

        -- lines under the box, one below the other
        local below = bottom + 2

        if s.distance and target.haveDistance then
            d.textCentered(centerX, below, labelR, labelG, labelB, string.format("%.0f st", target.distance))
            below += lineHeight
        end

        -- what the player has in the hands, where the game tells it
        if s.weapon and record.weapon ~= nil and record.weapon ~= "" then
            d.textCentered(centerX, below, labelR, labelG, labelB, record.weapon)
            below += lineHeight
        end

        -- how old the place of a hidden character is
        if hidden then
            d.textCentered(centerX, below, 255, 170, 60, string.format("seen %.1f s ago", target.hiddenFor or 0))
            below += lineHeight
        end

        -- how long ago the erase began
        if erased then
            d.textCentered(centerX, below, erase_color[1], erase_color[2], erase_color[3],
                string.format("TIME ERASE %.1f s", target.erasedFor or 0))
            below += lineHeight
        end

        if s.stand or s.spec then
            -- the stand in its own colour, the fighting style after it in the common one; centred as one line
            -- the stand by its short name: "KCR" for King Crimson Requiem
            local parts = kit.parts(record.stand, record.spec, s.stand, s.spec, true)
            local standWidth = if parts.stand == "" then 0 else d.textWidth(parts.stand)
            local restWidth = if parts.rest == "" then 0 else d.textWidth(parts.rest)
            local x = math.floor(centerX - (standWidth + restWidth) * 0.5)

            if parts.stand ~= "" then
                local color = kit.standColor(record.stand)
                d.text(x, below, color[1], color[2], color[3], parts.stand)
            end

            if parts.rest ~= "" then
                local color = kit.color.other
                d.text(x + standWidth, below, color[1], color[2], color[3], parts.rest)
            end
        end
    end

    -- players that left the game
    for key, track in self.tracks do
        if now - track.seenAt > abandoned_after then
            self.tracks[key] = nil
        end
    end
end

return esp_players
end

__modules["fly"] = function(require)
-- fly for YBA: the same CFrame-step technique as the auto-farm glider, but the goal comes from the user's WASD /
-- Space / Shift input relative to the camera, not from a point. The velocity of the root is zeroed every frame so
-- gravity and Humanoid physics do not push against the step. The fly is driven from main.lua by a per-frame step
-- that passes the current inputs and the camera CFrame
-- pure logic over its deps, checked by tests/fly_test.lua
local fly = {}

local Fly = {}
Fly.__index = Fly

-- deps:
--   rootPosition() -> x, y, z | nil, nil, nil      where the character is now
--   setRootPosition(x, y, z)                       moves the root there and zeroes its velocity
function fly.new(deps)
    return setmetatable({
        deps = deps,
    }, Fly)
end

-- forward is -1 (back) / 0 / 1 (forward), same for right (-1 left, 1 right) and up (-1 down, 1 up). camera is the
-- CFrame of the camera (the fly moves relative to where the user looks). speed is studs per second. dt is seconds
-- gives back whether a step was applied (false when there is no character or no input)
function Fly:step(dt, forward, right, up, camera, speed)
    if dt <= 0 then
        return false
    end

    local x, y, z = self.deps.rootPosition()
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return false
    end

    -- always flatten the velocity: even when the user is not pressing anything, gravity should not drop the
    -- character while fly is on
    if forward == 0 and right == 0 and up == 0 then
        self.deps.setRootPosition(x, y, z)
        return true
    end

    -- WASD вектор в системе камеры: вперёд — куда смотрим (без наклона вниз, чтобы W не толкал в землю),
    -- вправо — rightVector камеры, вверх — мировой Y. Так ощущается как fly в большинстве игр
    local look = camera.LookVector
    local rightV = camera.RightVector
    -- горизонтальный компонент взгляда: Y обнуляем, нормируем
    local lookX, lookZ = look.X, look.Z
    local lookMag = math.sqrt(lookX * lookX + lookZ * lookZ)
    if lookMag > 0 then
        lookX, lookZ = lookX / lookMag, lookZ / lookMag
    else
        lookX, lookZ = 0, 1       -- strictly up/down камера: берём произвольный вперёд
    end

    local dx = lookX * forward + rightV.X * right
    local dz = lookZ * forward + rightV.Z * right
    local dy = up

    local mag = math.sqrt(dx * dx + dy * dy + dz * dz)
    if mag > 0 then
        local step = speed * dt / mag
        dx, dy, dz = dx * step, dy * step, dz * step
    end

    self.deps.setRootPosition(x + dx, y + dy, z + dz)
    return true
end

return fly
end

__modules["fullbright"] = function(require)
-- Fullbright: убирает ночь/туман/тени на карте через Lighting-свойства. Запоминает оригинальные
-- значения перед включением и восстанавливает их при выключении, чтобы ничего не оставить игре.
-- Применяется каждый тик, пока включено: карта/сервер могут перезаписывать Lighting (например,
-- циклы день/ночь или ивенты).

local fullbright = {}

local savedClockTime = nil

-- просто ставит день (ClockTime = 14), ничего больше не трогает. Применяется каждый тик пока
-- enabled=true (сервер может крутить день/ночь). Выключение возвращает старое время.
-- lighting() gives the Lighting service; it is asked for only when there is something to do, so a mode without
-- the feature never touches it
function fullbright.step(enabled, lighting)
    if enabled then
        local Lighting = lighting()
        if savedClockTime == nil then
            savedClockTime = Lighting.ClockTime
        end
        Lighting.ClockTime = 14
    elseif savedClockTime ~= nil then
        local saved = savedClockTime
        savedClockTime = nil
        pcall(function() lighting().ClockTime = saved end)
    end
end

return fullbright
end

__modules["glider"] = function(require)
-- the chain-walk the auto-farmers of YBA use (tools/yba_probe3.lua on Slowc2960): short CFrame steps every frame
-- instead of a single teleport. The step is capped at a speed that gives ~12-20 studs per 7 ms frame (so ~1800 st/s
-- at the top) and tapers linearly within the last brakeDistance studs so the character coasts to the goal rather
-- than snapping to it. The resulting motion looks like a sprint, not a teleport, which keeps the host out of the
-- anti-teleport checks of the game while still being an order of magnitude faster than walking the character
-- pure logic over its deps, checked by tests/glider_test.lua
local glider = {}

local Glider = {}
Glider.__index = Glider

-- deps:
--   rootPosition() -> x, y, z     where the character is now; nil for either coord means "no character"
--   setRootPosition(x, y, z)      moves the root there (the host also zeroes velocity so Humanoid physics does not
--                                 push against our steps)
function glider.new(deps)
    return setmetatable({
        deps = deps,
        state = "idle",             -- "idle" / "going" / "arrived"
        targetX = 0, targetY = 0, targetZ = 0,
        maxSpeed = 1800,            -- studs/sec at full gas
        minSpeed = 150,             -- studs/sec near the goal, so a frame step is never microscopic
        brakeDistance = 60,         -- studs: within this radius the speed falls linearly with distance
        stopRadius = 3,             -- studs: snapped to the goal and the state turns to "arrived"
    }, Glider)
end

-- starts a glide to (x, y, z); replaces any previous goal
function Glider:goTo(x, y, z)
    self.targetX, self.targetY, self.targetZ = x, y, z
    self.state = "going"
end

-- forgets the goal (does not move the character)
function Glider:stop()
    self.state = "idle"
end

-- the current phase; the auto farm reads this to tell when it may start holding the prompt
function Glider:phase()
    return self.state
end

-- one step on every frame; dt is seconds since the last step
function Glider:step(dt)
    if self.state ~= "going" then
        return self.state
    end

    local x, y, z = self.deps.rootPosition()
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        self.state = "idle"
        return self.state
    end

    local dx, dy, dz = self.targetX - x, self.targetY - y, self.targetZ - z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

    if dist <= self.stopRadius then
        self.deps.setRootPosition(self.targetX, self.targetY, self.targetZ)
        self.state = "arrived"
        return self.state
    end

    -- speed: full gas until brakeDistance, then falls to minSpeed at the goal
    local speed = self.maxSpeed * dist / self.brakeDistance
    if speed > self.maxSpeed then
        speed = self.maxSpeed
    elseif speed < self.minSpeed then
        speed = self.minSpeed
    end

    local step = speed * (dt > 0 and dt or 0)
    if step >= dist then
        self.deps.setRootPosition(self.targetX, self.targetY, self.targetZ)
        self.state = "arrived"
        return self.state
    end

    local scale = step / dist
    self.deps.setRootPosition(x + dx * scale, y + dy * scale, z + dz * scale)
    return self.state
end

return glider
end

__modules["grenade"] = function(require)
-- where a thrown grenade goes: the flight, the bounces and the end
-- the same steps as the simulator of Blox Strike itself (Shared.GrenadeSimulator, read by tools/strike_probe7.lua),
-- which the server works a grenade out with and every client draws it with:
--   a step is 1/128 of a second; in the air the speed falls by gravity and the place moves by the mean of the old
--   and the new speed; on the ground the place moves by the speed and nothing pulls;
--   what is in the way is asked with a ray from the old place to the new one: a grenade is a point, not a ball;
--   a bounce turns the speed back from the surface and scales all of it (0.4; 0.32 for a jump throw; 0.3 of that
--   off a player), and on a floor a speed that is small enough becomes none;
--   a kind without a fuse ends when it lies still on the ground, a kind with one when the fuse runs out, and fire
--   the moment it meets a floor
-- of the game's seven rays per step (one from the centre, six from a hundredth of the radius around it) only the
-- one from the centre is cast: the others differ from it by a few thousandths of a stud
-- pure logic: the world comes in as a function; checked by tests/grenade_test.lua against a throw of the game
local num = require("./num")

local grenade = {}

grenade.step = 0.0078125        -- seconds, the step of the game
grenade.max_seconds = 10        -- the game gives up on a grenade after this long

local gravity = 23.83333396911621
local floor_normal = 0.7        -- how much a surface faces up to be a floor
local still = 2.3341049382716053    -- the square of the speed under which a grenade on a floor stops
local tiny = 0.0076388888888888895  -- a part of the speed smaller than this is none
local skin = 0.05               -- studs a grenade is put off the surface it met
local ground_reach = 0.2        -- studs below a grenade within which a surface means it is on the ground
local keep_every = 6            -- steps between two points of the path that are kept: about twenty a second

local function finite(value)
    return type(value) == "number" and num.finite(value)
end

-- what the game sends with a throw, made into what the simulation takes; nil for what is not it
function grenade.configOf(sent)
    if type(sent) ~= "table" then
        return nil
    end

    local fuse = sent.FuseTime
    if fuse ~= nil and not finite(fuse) then
        return nil
    end

    local maxBounces = sent.MaxBounces
    return {
        -- the game takes a fuse of nothing for no fuse
        fuse = if fuse ~= nil and fuse > 0 then fuse else nil,
        maxBounces = if finite(maxBounces) then maxBounces else 20,
        group = if type(sent.CollisionGroup) == "string" then sent.CollisionGroup else nil,
        floorImpact = false,    -- set by the kind: fire goes off on a floor
        minFuse = nil,          -- and not before this long after the throw
    }
end

-- the path from where a grenade is to where it ends; nil when the numbers are garbage
--   start: x, y, z, vx, vy, vz, time (seconds since the throw), bounces (made so far), touched (it has met
--     something already), jump (a jump throw)
--   config: a table of grenade.configOf
--   ray(x, y, z, dx, dy, dz) -> hitX, hitY, hitZ, nx, ny, nz, isPlayer: the first thing on the way from that place
--     along that move, and which way its surface faces; nil when nothing is in the way
-- gives back { points, endX, endY, endZ, endTime, reason, bounces }: points are { x, y, z, t } in the order of time,
-- t in seconds since the throw; a point where it bounced has bounce = true and the speed it left with (vx, vy, vz);
-- reason is "fuse", "rest", "impact" (fire met a floor) or "limit" (the game gives up)
function grenade.simulate(start, config, ray)
    local x, y, z = start.x, start.y, start.z
    local vx, vy, vz = start.vx, start.vy, start.vz
    local t = start.time
    if not num.plausible(x, y, z) or not finite(vx) or not finite(vy) or not finite(vz) or not finite(t) then
        return nil
    end

    local dt = grenade.step
    local bounces = start.bounces or 0
    local touched = start.touched == true
    local fuse = config.fuse
    local minFuse = config.minFuse
    local elasticity = if start.jump then 0.32 else 0.4
    local grounded = false

    local points = { { x = x, y = y, z = z, t = t } }
    local reason = nil
    local steps = 0

    while reason == nil do
        -- lying still with a fuse: nothing happens until it runs out
        if grounded and vx == 0 and vy == 0 and vz == 0 and fuse ~= nil then
            reason = if fuse <= grenade.max_seconds then "fuse" else "limit"
            break
        end

        t += dt

        if t >= grenade.max_seconds then
            reason = "limit"
            break
        end

        if fuse ~= nil and t >= fuse then
            reason = "fuse"
            break
        end

        if bounces >= config.maxBounces then
            reason = "rest"
            break
        end

        -- the move of this step
        local toX, toY, toZ = x + vx * dt, y + vy * dt, z + vz * dt
        local newVy = vy
        if not grounded then
            newVy = vy - gravity * dt
            toY = y + (vy + newVy) * 0.5 * dt
        end

        local dx, dy, dz = toX - x, toY - y, toZ - z
        local hitX, hitY, hitZ, nx, ny, nz, isPlayer = nil, nil, nil, nil, nil, nil, false
        if dx * dx + dy * dy + dz * dz >= 1e-6 then
            hitX, hitY, hitZ, nx, ny, nz, isPlayer = ray(x, y, z, dx, dy, dz)
        end

        if hitX ~= nil then
            -- turned back from the surface, and the whole of it scaled; off a player it keeps less
            local keep = math.clamp(elasticity * (if isPlayer then 0.3 else 1), 0, 0.9)
            local into = (vx * nx + newVy * ny + vz * nz) * 2
            local bx, by, bz = vx - nx * into, newVy - ny * into, vz - nz * into
            bx = if math.abs(bx) < tiny then 0 else bx * keep
            by = if math.abs(by) < tiny then 0 else by * keep
            bz = if math.abs(bz) < tiny then 0 else bz * keep

            if ny > floor_normal and bx * bx + by * by + bz * bz < still then
                bx, by, bz = 0, 0, 0
            end

            vx, vy, vz = bx, by, bz
            x, y, z = hitX + nx * skin, hitY + ny * skin, hitZ + nz * skin
            bounces += 1
            touched = true

            if config.floorImpact and ny > floor_normal and (minFuse == nil or t >= minFuse) then
                reason = "impact"
                break
            end

            table.insert(points, { x = x, y = y, z = z, t = t, bounce = true, vx = vx, vy = vy, vz = vz })
        else
            x, y, z = toX, toY, toZ
            vy = newVy
        end

        grounded = ray(x, y, z, 0, -ground_reach, 0) ~= nil

        -- a kind without a fuse ends when it lies still
        if grounded and touched and fuse == nil and vx * vx + vy * vy + vz * vz < still and (minFuse == nil or t >= minFuse) then
            reason = "rest"
            break
        end

        steps += 1
        if steps % keep_every == 0 and hitX == nil then
            table.insert(points, { x = x, y = y, z = z, t = t })
        end
    end

    -- the path ends where the grenade stops moving; with a fuse that may be before it ends
    local last = points[#points]
    if last.x ~= x or last.y ~= y or last.z ~= z then
        table.insert(points, { x = x, y = y, z = z, t = t })
    end

    local endTime = t
    if reason == "fuse" then
        endTime = fuse
    elseif reason == "limit" then
        endTime = grenade.max_seconds
    end

    return { points = points, endX = x, endY = y, endZ = z, endTime = endTime, reason = reason, bounces = bounces }
end

return grenade
end

__modules["grenades"] = function(require)
-- the grenades of Blox Strike on the screen: where each one in the air goes and where it ends, and where the one in
-- the hand of the user would go
-- the game tells every client about a throw (Projectile.Spawn: the kind of the grenade and the state it was thrown
-- in), about every bounce (Projectile.Bounce: where it is and how fast, afterwards) and about the end
-- (Projectile.Resolve). The way is worked out once per word of the game, see grenade.lua; a frame only draws it
-- nothing is sent and nothing of the game is changed. Checked by tests/grenades_test.lua
local grenade = require("./grenade")
local num = require("./num")

local grenades = {}

grenades.max_count = 24         -- followed at once; a new one pushes out the oldest
grenades.linger = 0.6           -- seconds the mark stays after the game said the grenade ended
grenades.forget_after = 1.5     -- seconds after the end the script worked out, when the game never said it ended

local clock_slack = 30          -- seconds a stamp of the game may differ from the clock of the server and still be trusted
local fire_min_fuse = 0.1       -- fire does not go off on a floor in the first tenth of a second

-- what the game has of each kind: the fuse it sends with a throw (none: the kind lies where it comes to rest), and
-- whether it goes off the moment it meets a floor, which the code of the game decides by the name
-- (Controllers.Observers.Game.Grenade); read by tools/strike_probe6.lua and strike_probe7.lua
local known = {
    ["HE Grenade"] = { fuse = 1.6 },
    ["Flashbang"] = { fuse = 1.5 },
    ["Smoke Grenade"] = {},
    ["Molotov"] = { fuse = 2.4, fire = true },
    ["Incendiary Grenade"] = { fuse = 2.4, fire = true },
    ["Decoy Grenade"] = { fuse = 15 },
}

-- the colour of a kind, by a word in its name; a kind the script does not know is white
local colours = {
    { word = "smoke", r = 200, g = 200, b = 210 },
    { word = "flash", r = 255, g = 235, b = 90 },
    { word = "molotov", r = 255, g = 150, b = 50 },
    { word = "incendiary", r = 255, g = 150, b = 50 },
    { word = "fire", r = 255, g = 150, b = 50 },
    { word = "decoy", r = 150, g = 220, b = 150 },
    { word = "he", r = 255, g = 80, b = 80 },
    { word = "frag", r = 255, g = 80, b = 80 },
}

-- x, y, z of a vector the game sent; nil when it is not one or its numbers are garbage
local function triple(value)
    local ok, x, y, z = pcall(function()
        return value.X, value.Y, value.Z
    end)

    if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" and num.finite(x) and num.finite(y) and num.finite(z) then
        return x, y, z
    end

    return nil
end

-- how a kind is written and in which colour
function grenades.describe(weapon)
    local label = "Grenade"
    local r, g, b = 255, 255, 255

    if type(weapon) == "string" and weapon ~= "" then
        -- "HE Grenade" is written "HE"
        label = string.gsub(weapon, "%s*[Gg]renade%s*$", "")
        if label == "" then
            label = weapon
        end

        local lower = string.lower(weapon)
        for _, kind in colours do
            -- a whole word: "he" must not be found in "the"
            if string.find(" " .. lower .. " ", "[^%a]" .. kind.word) ~= nil then
                r, g, b = kind.r, kind.g, kind.b
                break
            end
        end
    end

    return label, r, g, b
end

-- the config of a grenade the user holds, by its name alone: the game has not said anything about it yet
-- group is the collision group of the side of the user; nil for what is not a grenade
function grenades.configFor(weapon, group)
    local kind = known[weapon]
    if kind == nil then
        return nil
    end

    return {
        fuse = kind.fuse,
        maxBounces = 20,
        group = group,
        floorImpact = kind.fire == true,
        minFuse = if kind.fire then fire_min_fuse else nil,
    }
end

-- the mark where a way ends: a dot, what is written under it, and how far from the user it is
local function mark(d, project, x, y, z, r, g, b, text, haveLocal, localX, localY, localZ)
    local screenX, screenY, visible = project(x, y, z)
    if not visible or not num.finite(screenX) or not num.finite(screenY) then
        return
    end

    local px, py = math.floor(screenX + 0.5), math.floor(screenY + 0.5)
    d.dot(px, py, 5, 0, 0, 0)
    d.dot(px, py, 4, r, g, b)
    d.textCentered(px, py + 7, r, g, b, text)

    if haveLocal then
        local dx, dy, dz = x - localX, y - localY, z - localZ
        d.textCentered(px, py + 7 + d.line_height, 255, 255, 255, string.format("%.0f st", math.sqrt(dx * dx + dy * dy + dz * dz)))
    end
end

-- a way from the moment `elapsed` (seconds since the throw) on, and the mark at its end
function grenades.drawWay(path, elapsed, r, g, b, text, haveLocal, localX, localY, localZ, project, d)
    local points = path.points
    local lastX, lastY, lastVisible = nil, nil, false

    local function to(x, y, z)
        local screenX, screenY, visible = project(x, y, z)
        visible = visible and num.finite(screenX) and num.finite(screenY)

        if visible and lastVisible then
            d.line(lastX, lastY, screenX, screenY, r, g, b, 1)
        end

        lastX, lastY, lastVisible = screenX, screenY, visible
    end

    -- the points still ahead, after a point worked out between two of them: where the grenade is now
    for i = 1, #points do
        local point = points[i]
        if point.t >= elapsed then
            if lastX == nil and i > 1 then
                local previous = points[i - 1]
                local span = point.t - previous.t
                local share = if span > 0 then (elapsed - previous.t) / span else 0
                to(previous.x + (point.x - previous.x) * share, previous.y + (point.y - previous.y) * share,
                    previous.z + (point.z - previous.z) * share)
            end

            to(point.x, point.y, point.z)
        end
    end

    mark(d, project, path.endX, path.endY, path.endZ, r, g, b, text, haveLocal, localX, localY, localZ)
end

local Tracker = {}
Tracker.__index = Tracker

-- deps:
--   ray(x, y, z, dx, dy, dz, group) -> hitX, hitY, hitZ, nx, ny, nz, isPlayer
--     the first thing a grenade of that collision group meets on the way from that place along that move, and which
--     way its surface faces; nil when nothing is in the way
function grenades.new(deps)
    return setmetatable({
        deps = deps,
        byId = {},      -- id -> entry
        order = {},     -- the same entries, the oldest first
    }, Tracker)
end

function Tracker:count()
    return #self.order
end

function Tracker:clear()
    table.clear(self.byId)
    table.clear(self.order)
end

local function drop(self, entry)
    self.byId[entry.id] = nil
    local at = table.find(self.order, entry)
    if at ~= nil then
        table.remove(self.order, at)
    end
end

-- the way of a grenade with that config from that state on
function Tracker:way(config, x, y, z, vx, vy, vz, time, bounces, touched, jump)
    local group = config.group
    local ray = self.deps.ray

    return grenade.simulate({ x = x, y = y, z = z, vx = vx, vy = vy, vz = vz, time = time, bounces = bounces, touched = touched, jump = jump },
        config, function(px, py, pz, dx, dy, dz)
            return ray(px, py, pz, dx, dy, dz, group)
        end)
end

-- the game tells about a throw; serverNow is the clock of the server, the one the game stamps its words with
function Tracker:spawn(payload, serverNow)
    if type(payload) ~= "table" or payload.Id == nil then
        return
    end

    local config = grenade.configOf(payload.Physics)
    local state = payload.State
    if config == nil or type(state) ~= "table" then
        return
    end

    local kind = known[payload.Weapon]
    if kind ~= nil and kind.fire then
        config.floorImpact = true
        config.minFuse = fire_min_fuse
    end

    local x, y, z = triple(state.Position)
    local vx, vy, vz = triple(state.Velocity)
    if x == nil or vx == nil or not num.plausible(x, y, z) then
        return
    end

    -- a stamp that is not of the clock the script reads cannot be counted from: the throw is taken to be now
    local start = state.StartTime
    if type(start) ~= "number" or not num.finite(start) or math.abs(serverNow - start) > clock_slack then
        start = serverNow
    end

    local label, r, g, b = grenades.describe(payload.Weapon)
    local entry = { id = payload.Id, label = label, r = r, g = g, b = b, config = config, jump = state.IsJumpThrow == true, start = start,
        path = nil, resolvedAt = nil }

    entry.path = self:way(config, x, y, z, vx, vy, vz, 0, 0, false, entry.jump)
    if entry.path == nil then
        return
    end

    -- told twice: the later word is the one that counts
    local before = self.byId[entry.id]
    if before ~= nil then
        drop(self, before)
    end

    self.byId[entry.id] = entry
    table.insert(self.order, entry)

    while #self.order > grenades.max_count do
        drop(self, self.order[1])
    end
end

-- the game tells where a grenade is after a bounce, and how fast
function Tracker:bounce(payload, serverNow)
    if type(payload) ~= "table" then
        return
    end

    local entry = self.byId[payload.Id]
    if entry == nil or entry.resolvedAt ~= nil then
        return
    end

    local x, y, z = triple(payload.Position)
    local vx, vy, vz = triple(payload.Velocity)
    if x == nil or vx == nil or not num.plausible(x, y, z) then
        return
    end

    -- when it bounced, counted from the throw
    local elapsed = serverNow - entry.start
    local stamp = payload.Timestamp
    if type(stamp) == "number" and num.finite(stamp) and stamp >= entry.start and stamp - entry.start <= grenade.max_seconds then
        elapsed = stamp - entry.start
    end

    local bounces = payload.BounceIndex
    if type(bounces) ~= "number" or not num.finite(bounces) then
        bounces = entry.path.bounces
    end

    local path = self:way(entry.config, x, y, z, vx, vy, vz, math.max(elapsed, 0), bounces, true, entry.jump)
    if path ~= nil then
        entry.path = path
    end
end

-- the game tells that a grenade has ended; localNow is the clock the frames are drawn by
function Tracker:resolve(payload, localNow)
    if type(payload) ~= "table" then
        return
    end

    local entry = self.byId[payload.Id]
    if entry == nil then
        return
    end

    entry.resolvedAt = localNow

    local x, y, z = triple(payload.Position)
    if x ~= nil and num.plausible(x, y, z) then
        entry.endX, entry.endY, entry.endZ = x, y, z
    else
        entry.endX, entry.endY, entry.endZ = entry.path.endX, entry.path.endY, entry.path.endZ
    end
end

-- every frame: the way ahead of every grenade, and the mark where it ends
function Tracker:draw(serverNow, localNow, haveLocal, localX, localY, localZ, project, d)
    for index = #self.order, 1, -1 do
        local entry = self.order[index]

        if entry.resolvedAt ~= nil then
            -- ended: the mark stays for a moment where the game said it did
            if localNow - entry.resolvedAt > grenades.linger then
                drop(self, entry)
            else
                mark(d, project, entry.endX, entry.endY, entry.endZ, entry.r, entry.g, entry.b, entry.label, haveLocal, localX, localY, localZ)
            end

            continue
        end

        local path = entry.path
        local elapsed = serverNow - entry.start
        if elapsed > path.endTime + grenades.forget_after then
            drop(self, entry)
            continue
        end

        local left = math.max(path.endTime - elapsed, 0)
        grenades.drawWay(path, elapsed, entry.r, entry.g, entry.b, string.format("%s %.1f s", entry.label, left), haveLocal, localX, localY,
            localZ, project, d)
    end
end

return grenades
end

__modules["guard"] = function(require)
-- a function that runs on every frame must not report the same error on every frame:
-- after the first one it is not called again until somebody asks for it; checked by tests/guard_test.lua
local guard = {}

-- onError takes the message with the stack, once per error
function guard.new(fn, onError)
    local self = { broken = false }

    function self.run(...)
        if self.broken then
            return
        end

        local ok, message = xpcall(fn, debug.traceback, ...)
        if not ok then
            self.broken = true
            onError(message)
        end
    end

    function self.reset()
        self.broken = false
    end

    return self
end

return guard
end

__modules["health_fade"] = function(require)
-- the percent label next to the health bar: shown for a while after the health went down, hidden otherwise
-- pure logic, checked by tests/health_fade_test.lua; a port of features/health_fade.h of the external
local health_fade = {}

health_fade.hold = 3        -- seconds the label stays after the last loss
health_fade.fade = 0.5      -- seconds it takes to disappear after that
health_fade.step = 0.001    -- smallest loss that counts, as a share of full health

function health_fade.newTrack()
    return {
        reference = -1,     -- health the next sample is compared with, negative before the first one
        lostAt = -1e9,      -- time of the last loss, seconds
        seenAt = 0,         -- time of the last sample, tells the owner which tracks are abandoned
    }
end

-- how visible the label is that long after a loss, 0..1
local function visibility(sinceLoss)
    if sinceLoss <= health_fade.hold then
        return 1
    end

    if sinceLoss >= health_fade.hold + health_fade.fade then
        return 0
    end

    return 1 - (sinceLoss - health_fade.hold) / health_fade.fade
end

-- takes the health seen at that time, returns how visible the label is, 0..1
function health_fade.update(track, fraction, now)
    track.seenAt = now

    if track.reference < 0 or fraction > track.reference then
        -- the first sample, or healing: nothing was lost
        track.reference = fraction
    elseif fraction < track.reference - health_fade.step then
        track.reference = fraction
        track.lostAt = now
    end
    -- a smaller loss leaves the reference where it is, so that a slow drain adds up

    return visibility(now - track.lostAt)
end

-- whole percent for the label; a hurt player never reads 100 and a living one never reads 0
function health_fade.percent(fraction)
    if not (fraction > 0) then
        return 0
    end

    if fraction >= 1 then
        return 100
    end

    return math.clamp(math.round(fraction * 100), 1, 99)
end

return health_fade
end

__modules["hitbox"] = function(require)
-- which point of a body the aim goes for: the parts of a character as boxes, the points worth trying on each,
-- and the choice among them; the same rules as rbx/hitbox.h of the external
-- checked by tests/hitbox_test.lua
local num = require("./num")

local hitbox = {}

-- in the order they are tried when the choice goes by priority
hitbox.Head = 1
hitbox.Chest = 2
hitbox.Stomach = 3
hitbox.Arms = 4
hitbox.Legs = 5

hitbox.zone_count = 5
hitbox.max_points = 7       -- per part: the centre and one towards each face

local max_parts = 32        -- of one body; both rigs of Roblox have fewer

-- the zone of a body part by its name, in both character rigs of Roblox
-- (the root part is not one: it is an invisible box in the middle of the torso)
local zones = {
    ["Head"] = hitbox.Head,
    ["UpperTorso"] = hitbox.Chest, ["Torso"] = hitbox.Chest,
    ["LowerTorso"] = hitbox.Stomach,
    ["LeftUpperArm"] = hitbox.Arms, ["LeftLowerArm"] = hitbox.Arms, ["LeftHand"] = hitbox.Arms,
    ["RightUpperArm"] = hitbox.Arms, ["RightLowerArm"] = hitbox.Arms, ["RightHand"] = hitbox.Arms,
    ["Left Arm"] = hitbox.Arms, ["Right Arm"] = hitbox.Arms,
    ["LeftUpperLeg"] = hitbox.Legs, ["LeftLowerLeg"] = hitbox.Legs, ["LeftFoot"] = hitbox.Legs,
    ["RightUpperLeg"] = hitbox.Legs, ["RightLowerLeg"] = hitbox.Legs, ["RightFoot"] = hitbox.Legs,
    ["Left Leg"] = hitbox.Legs, ["Right Leg"] = hitbox.Legs,
}

-- nil for anything that is not a part of a body
function hitbox.zoneOf(name)
    return zones[name]
end

-- the parts of a character: { part, zone } for each; for the slow pass, the list is kept between frames
function hitbox.collect(body)
    local parts = {}

    for _, child in body:GetChildren() do
        local zone = zones[child.Name]
        if zone ~= nil and child:IsA("BasePart") then
            table.insert(parts, { part = child, zone = zone })
            if #parts >= max_parts then
                break
            end
        end
    end

    return parts
end

-- where those parts are right now, as boxes; out is filled and given back
-- a box is its centre (cx, cy, cz), its size (sx, sy, sz) and its three axes in the world (r, u, l)
function hitbox.read(parts, out)
    table.clear(out)

    for _, entry in parts do
        local part = entry.part
        -- a part that was destroyed still answers, with the place it was at
        if part.Parent == nil then
            continue
        end

        local frame = part.CFrame
        local position = frame.Position
        local x, y, z = position.X, position.Y, position.Z
        if not num.plausible(x, y, z) then
            continue
        end

        local size = part.Size
        local right, up, look = frame.RightVector, frame.UpVector, frame.LookVector

        table.insert(out, {
            zone = entry.zone,
            cx = x, cy = y, cz = z,
            sx = size.X, sy = size.Y, sz = size.Z,
            rx = right.X, ry = right.Y, rz = right.Z,
            ux = up.X, uy = up.Y, uz = up.Z,
            lx = look.X, ly = look.Y, lz = look.Z,
        })
    end

    return out
end

local function plain(zone, x, y, z, sx, sy, sz)
    return {
        zone = zone,
        cx = x, cy = y, cz = z,
        sx = sx, sy = sy, sz = sz,
        rx = 1, ry = 0, rz = 0,
        ux = 0, uy = 1, uz = 0,
        lx = 0, ly = 0, lz = 1,
    }
end

-- a body of another make, or one that was not read yet: the two places every character has, as plain boxes
-- the head stands for the head, the middle of the body for everything else; x, y, z is where the root is
function hitbox.standIns(x, y, z, enabled)
    local boxes = {}

    if enabled[hitbox.Head] then
        table.insert(boxes, plain(hitbox.Head, x, y + 2, z, 1.2, 1.2, 1.2))
    end

    for zone = hitbox.Chest, hitbox.zone_count do
        if enabled[zone] then
            -- filed under the first of those zones that is allowed, or the choice would throw it away
            table.insert(boxes, plain(zone, x, y, z, 2, 2, 1))
            break
        end
    end

    return boxes
end

-- the points of a part worth aiming at: its centre, then with multipoint one towards each of the six faces,
-- `inset` of the way from the centre to the face (0 is the centre, 1 is the face itself)
-- writes x, y, z of each into out one after another and gives back how many there are
function hitbox.points(box, multipoint, inset, out)
    out[1], out[2], out[3] = box.cx, box.cy, box.cz
    if not multipoint then
        return 1
    end

    -- written this way to take nan for the centre as well
    local share = 0
    if inset > 0 then
        share = math.min(inset, 1)
    end

    local halfX, halfY, halfZ = box.sx * 0.5 * share, box.sy * 0.5 * share, box.sz * 0.5 * share
    local at = 3

    local function pair(ax, ay, az, half)
        out[at + 1], out[at + 2], out[at + 3] = box.cx + ax * half, box.cy + ay * half, box.cz + az * half
        out[at + 4], out[at + 5], out[at + 6] = box.cx - ax * half, box.cy - ay * half, box.cz - az * half
        at += 6
    end

    pair(box.rx, box.ry, box.rz, halfX)
    pair(box.ux, box.uy, box.uz, halfY)
    pair(box.lx, box.ly, box.lz, halfZ)

    return 7
end

-- picks the point to aim at among the parts of one body; gives back the choice (nil when there is none)
-- and how many looks are left
--  - enabled says which zones may be picked at all
--  - nearest false: the zones go in their order, and the first point that can be seen wins (the centre of a part
--    before its edges); nearest true: the point closest to the crosshair that can be seen wins, whatever its zone
--  - project(x, y, z) gives the offset of a point from the crosshair in pixels, nil when the point cannot be aimed at
--    (behind the camera, outside the circle); it is cheap and is asked about every point
--  - visible(x, y, z) is the line of sight test; it is expensive, so points are tried one at a time in the order
--    the mode prefers them, and rays says how many tests are left for this frame
function hitbox.choose(boxes, enabled, nearest, multipoint, inset, project, visible, rays)
    local options = {}
    local tried = {}

    for zone = 1, hitbox.zone_count do
        if not enabled[zone] then
            continue
        end

        for _, box in boxes do
            if box.zone ~= zone then
                continue
            end

            local count = hitbox.points(box, multipoint, inset, tried)
            for i = 1, count do
                local at = (i - 1) * 3
                local x, y, z = tried[at + 1], tried[at + 2], tried[at + 3]
                local dx, dy = project(x, y, z)
                if dx ~= nil then
                    table.insert(options, { x = x, y = y, z = z, zone = zone, dx = dx, dy = dy, far = dx * dx + dy * dy,
                        order = #options })
                end
            end
        end
    end

    -- the list is in the order of priority as built; "nearest" replaces that order, keeping it for equal distances
    if nearest then
        table.sort(options, function(p, q)
            if p.far ~= q.far then
                return p.far < q.far
            end

            return p.order < q.order
        end)
    end

    for _, option in options do
        if rays <= 0 then
            break
        end

        rays -= 1
        if visible(option.x, option.y, option.z) then
            return option, rays
        end
    end

    return nil, rays
end

return hitbox
end

__modules["hitchance"] = function(require)
-- the chance that a shot hits, the way Blox Strike spreads it (Components.Weapon.Classes.Bullet._performRaycast): the
-- direction is the middle of the screen turned off by an angle drawn evenly between 0 and half the spread, and around
-- it by an angle drawn evenly all round. The draw is stood for by rings of directions: one ring for every equal step
-- of the first angle, the same number on each ring, every direction counting the same
-- the directions are worked out here; whether a ray along one hits is asked of whoever gives the rays
-- pure logic, checked by tests/hitchance_test.lua
local hitchance = {}

hitchance.rings = 4
hitchance.per_ring = 8
local pinpoint = 0.0005     -- radians: a cone this narrow is one direction

-- the directions around the unit forward (fx, fy, fz) for a cone of half that angle (radians), written into out as
-- { x, y, z } tables, unit long; gives back how many
function hitchance.directions(fx, fy, fz, half, out)
    if half <= pinpoint then
        local only = out[1] or {}
        out[1] = only
        only[1], only[2], only[3] = fx, fy, fz
        return 1
    end

    -- two directions across the forward one: the game turns about the up of the world, unless it looks straight up
    local ux, uy, uz = 0, 1, 0
    if math.abs(fy) > 0.9999 then
        ux, uy, uz = 1, 0, 0
    end

    local rx, ry, rz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
    local length = math.sqrt(rx * rx + ry * ry + rz * rz)
    rx, ry, rz = rx / length, ry / length, rz / length
    local vx, vy, vz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx

    local count = 0
    for ring = 1, hitchance.rings do
        local off = half * (ring - 0.5) / hitchance.rings
        local along, across = math.cos(off), math.sin(off)

        for step = 1, hitchance.per_ring do
            -- every other ring turned by half a step, so that the rings do not line up
            local around = 2 * math.pi * (step - 1 + (ring % 2) * 0.5) / hitchance.per_ring
            local a, b = math.cos(around) * across, math.sin(around) * across

            count += 1
            local direction = out[count] or {}
            out[count] = direction
            direction[1] = fx * along + rx * a + vx * b
            direction[2] = fy * along + ry * a + vy * b
            direction[3] = fz * along + rz * a + vz * b
        end
    end

    return count
end

-- whether at least the share need (0 to 1) of the directions hit: hits(x, y, z) -> boolean is asked for one direction
-- after another, and no more of them than it takes to know the answer
function hitchance.enough(directions, count, need, hits)
    local wanted = math.ceil(need * count - 1e-9)
    if wanted <= 0 then
        return true
    end

    local got, missed = 0, 0
    for index = 1, count do
        local direction = directions[index]
        if hits(direction[1], direction[2], direction[3]) then
            got += 1
            if got >= wanted then
                return true
            end
        else
            missed += 1
            if count - missed < wanted then
                return false
            end
        end
    end

    return got >= wanted
end

return hitchance
end

__modules["hud"] = function(require)
-- HUD overlays: watermark (вверху справа) и reload bar (внизу по центру, MVS)
-- Стиль под Obsidian: тёмная подложка, тонкий бордер, акцент-цвет полоски

local hud = {}

-- what the overlays are made of, handed over by hud.setup from env.lua: only env.lua touches the globals. Without
-- Instance (the tests run without one) nothing is built and every step does nothing
local game, Instance, UDim, UDim2, Color3, Enum, Vector2
local dragConnections = {}  -- the mouse moves followed for dragging, taken back by hud.destroy

local Players = nil
local workspace_ = nil
local gui = nil           -- ScreenGui
local wmFrame = nil       -- watermark container
local wmText = nil        -- TextLabel inside watermark
local reloadFrame = nil
local reloadFill = nil
local hkFrame = nil       -- hotkeys panel container
local hkList = nil        -- UIListLayout inside hkFrame
local hkRows = {}         -- id -> { frame, keyLabel, nameLabel }

-- lazy — Color3 нет в тестовом окружении
local accent, bg, border, textCol
local function initColors()
    if accent then return end
    accent = Color3.fromRGB(140, 90, 230)
    bg = Color3.fromRGB(14, 14, 18)
    border = Color3.fromRGB(45, 45, 55)
    textCol = Color3.fromRGB(230, 230, 235)
end

local reloadStartAt = 0
local reloadDuration = 2.5    -- MVS револьвер: ~2.5s между выстрелами (из спеки external)

local lastFpsMeasure = 0
local fpsCount = 0
local fpsAvg = 0

-- делает frame перетаскиваемым за ЛКМ. Хранит позицию в UDim2 offset'ах
local function makeDraggable(frame)
    local UIS = game:GetService("UserInputService")
    local dragging = false
    local dragStart, startPos
    frame.Active = true
    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    table.insert(dragConnections, UIS.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))
end

local function ensureGui()
    if gui ~= nil and gui.Parent ~= nil then return end
    initColors()
    -- an overlay left on screen by a copy of the script that went away without taking it
    pcall(function()
        local stale = game:GetService("CoreGui"):FindFirstChild("CalciteHUD")
        if stale ~= nil then
            stale:Destroy()
        end
    end)
    gui = Instance.new("ScreenGui")
    gui.Name = "CalciteHUD"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder = 999
    local ok = pcall(function() gui.Parent = game:GetService("CoreGui") end)
    if not ok then gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end

    -- Watermark
    wmFrame = Instance.new("Frame")
    wmFrame.Name = "Watermark"
    wmFrame.BackgroundColor3 = bg
    wmFrame.BackgroundTransparency = 0.15
    wmFrame.BorderSizePixel = 0
    wmFrame.Size = UDim2.fromOffset(0, 26)
    wmFrame.AutomaticSize = Enum.AutomaticSize.X
    wmFrame.Position = UDim2.new(1, -12, 0, 12)
    wmFrame.AnchorPoint = Vector2.new(1, 0)
    wmFrame.Visible = false
    wmFrame.Parent = gui
    local corner = Instance.new("UICorner", wmFrame)
    corner.CornerRadius = UDim.new(0, 6)
    local stroke = Instance.new("UIStroke", wmFrame)
    stroke.Color = border
    stroke.Thickness = 1
    stroke.Transparency = 0.3
    local pad = Instance.new("UIPadding", wmFrame)
    pad.PaddingLeft = UDim.new(0, 10)
    pad.PaddingRight = UDim.new(0, 10)

    wmText = Instance.new("TextLabel")
    wmText.Parent = wmFrame
    wmText.BackgroundTransparency = 1
    wmText.Size = UDim2.fromScale(1, 1)
    wmText.AutomaticSize = Enum.AutomaticSize.X
    wmText.Font = Enum.Font.GothamMedium
    wmText.TextSize = 13
    wmText.TextColor3 = textCol
    wmText.TextXAlignment = Enum.TextXAlignment.Left
    wmText.Text = "Calcite"

    -- акцент-полоска слева внутри watermark
    local accentBar = Instance.new("Frame")
    accentBar.Parent = wmFrame
    accentBar.BackgroundColor3 = accent
    accentBar.BorderSizePixel = 0
    accentBar.Size = UDim2.new(0, 2, 1, -8)
    accentBar.Position = UDim2.new(0, 0, 0, 4)
    local accentCorner = Instance.new("UICorner", accentBar)
    accentCorner.CornerRadius = UDim.new(1, 0)

    -- Reload bar — под прицелом (центр экрана + смещение вниз)
    reloadFrame = Instance.new("Frame")
    reloadFrame.Name = "ReloadBar"
    reloadFrame.BackgroundColor3 = bg
    reloadFrame.BackgroundTransparency = 0.15
    reloadFrame.BorderSizePixel = 0
    reloadFrame.Size = UDim2.fromOffset(140, 6)
    reloadFrame.Position = UDim2.new(0.5, 0, 0.5, 36)
    reloadFrame.AnchorPoint = Vector2.new(0.5, 0)
    reloadFrame.Visible = false
    reloadFrame.Parent = gui
    local rCorner = Instance.new("UICorner", reloadFrame)
    rCorner.CornerRadius = UDim.new(1, 0)
    local rStroke = Instance.new("UIStroke", reloadFrame)
    rStroke.Color = border
    rStroke.Thickness = 1
    rStroke.Transparency = 0.3

    reloadFill = Instance.new("Frame")
    reloadFill.Parent = reloadFrame
    reloadFill.BackgroundColor3 = accent
    reloadFill.BorderSizePixel = 0
    reloadFill.Size = UDim2.new(0, 0, 1, 0)
    local fCorner = Instance.new("UICorner", reloadFill)
    fCorner.CornerRadius = UDim.new(1, 0)

    -- Hotkeys panel: правый край экрана, под watermark
    hkFrame = Instance.new("Frame")
    hkFrame.Name = "Hotkeys"
    hkFrame.BackgroundColor3 = bg
    hkFrame.BackgroundTransparency = 0.15
    hkFrame.BorderSizePixel = 0
    hkFrame.Size = UDim2.fromOffset(110, 0)
    hkFrame.AutomaticSize = Enum.AutomaticSize.Y
    hkFrame.Position = UDim2.new(1, -12, 0, 52)
    hkFrame.AnchorPoint = Vector2.new(1, 0)
    hkFrame.Visible = false
    hkFrame.Parent = gui
    local hkCorner = Instance.new("UICorner", hkFrame)
    hkCorner.CornerRadius = UDim.new(0, 6)
    local hkStroke = Instance.new("UIStroke", hkFrame)
    hkStroke.Color = border
    hkStroke.Thickness = 1
    hkStroke.Transparency = 0.3
    local hkPad = Instance.new("UIPadding", hkFrame)
    hkPad.PaddingTop = UDim.new(0, 4)
    hkPad.PaddingBottom = UDim.new(0, 4)
    hkPad.PaddingLeft = UDim.new(0, 8)
    hkPad.PaddingRight = UDim.new(0, 8)
    hkList = Instance.new("UIListLayout", hkFrame)
    hkList.FillDirection = Enum.FillDirection.Vertical
    hkList.SortOrder = Enum.SortOrder.LayoutOrder
    hkList.Padding = UDim.new(0, 1)
    local hkTitle = Instance.new("TextLabel")
    hkTitle.Parent = hkFrame
    hkTitle.BackgroundTransparency = 1
    hkTitle.Size = UDim2.new(1, 0, 0, 14)
    hkTitle.Font = Enum.Font.GothamMedium
    hkTitle.TextSize = 11
    hkTitle.TextColor3 = textCol
    hkTitle.TextXAlignment = Enum.TextXAlignment.Left
    hkTitle.Text = "HOTKEYS"
    hkTitle.LayoutOrder = -2

    -- горизонтальная полоска-разделитель под заголовком
    local hkSep = Instance.new("Frame")
    hkSep.Parent = hkFrame
    hkSep.BackgroundColor3 = border
    hkSep.BackgroundTransparency = 0.3
    hkSep.BorderSizePixel = 0
    hkSep.Size = UDim2.new(1, 0, 0, 1)
    hkSep.LayoutOrder = -1

    -- перетаскивание ЛКМ: watermark и hotkeys. reload bar привязан к курсору, не drag'ается
    makeDraggable(wmFrame)
    makeDraggable(hkFrame)
end

local mutedCol -- локальный муд для hotkeys
local function initMuted()
    if mutedCol == nil then mutedCol = Color3.fromRGB(150, 150, 160) end
end

local function ensureHkRow(id, keyText, nameText, order)
    initMuted()
    local row = hkRows[id]
    if row == nil then
        local frame = Instance.new("Frame")
        frame.BackgroundTransparency = 1
        frame.Size = UDim2.new(1, 0, 0, 15)
        frame.LayoutOrder = order or 0
        frame.Parent = hkFrame
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Parent = frame
        nameLabel.BackgroundTransparency = 1
        nameLabel.Size = UDim2.new(1, 0, 1, 0)
        nameLabel.Position = UDim2.fromOffset(0, 0)
        nameLabel.Font = Enum.Font.Gotham
        nameLabel.TextSize = 12
        nameLabel.TextColor3 = textCol
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        local keyLabel = Instance.new("TextLabel")
        keyLabel.Parent = frame
        keyLabel.BackgroundTransparency = 1
        keyLabel.Size = UDim2.new(1, 0, 1, 0)
        keyLabel.Position = UDim2.fromOffset(0, 0)
        keyLabel.Font = Enum.Font.GothamMedium
        keyLabel.TextSize = 12
        keyLabel.TextColor3 = mutedCol
        keyLabel.TextXAlignment = Enum.TextXAlignment.Right
        row = { frame = frame, keyLabel = keyLabel, nameLabel = nameLabel }
        hkRows[id] = row
    end
    row.frame.LayoutOrder = order or 0
    row.nameLabel.Text = nameText
    row.keyLabel.Text = keyText or "-"
    row.frame.Visible = true
end

local function hideRow(id)
    local row = hkRows[id]
    if row then row.frame.Visible = false end
end

-- deps: players, workspace, and game, Instance, UDim, UDim2, Color3, Enum, Vector2 of env.lua
function hud.setup(deps)
    Players = deps.players
    workspace_ = deps.workspace
    game, Instance, UDim, UDim2 = deps.game, deps.Instance, deps.UDim, deps.UDim2
    Color3, Enum, Vector2 = deps.Color3, deps.Enum, deps.Vector2
end

-- takes the overlays off the screen and lets go of the mouse: on unload, so nothing stays behind the script
function hud.destroy()
    for _, connection in dragConnections do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(dragConnections)

    if gui ~= nil then
        pcall(function()
            gui:Destroy()
        end)
    end

    gui, wmFrame, wmText, reloadFrame, reloadFill, hkFrame, hkList = nil, nil, nil, nil, nil, nil, nil
    table.clear(hkRows)
end

-- вызвать когда произошёл выстрел (один раз на выстрел)
function hud.markShot(now)
    reloadStartAt = now
end

-- каждый тик обновляет watermark/reload bar; передай dt для FPS и enabled-флаги
function hud.step(dt, now, showWatermark, showReload)
    if Instance == nil then
        return
    end

    if not showWatermark and not showReload then
        if gui ~= nil then
            if wmFrame then wmFrame.Visible = false end
            if reloadFrame then reloadFrame.Visible = false end
        end
        return
    end
    ensureGui()

    -- FPS: усредняем за 0.5с
    fpsCount += 1
    if now - lastFpsMeasure >= 0.5 then
        fpsAvg = fpsCount / (now - lastFpsMeasure)
        fpsCount = 0
        lastFpsMeasure = now
    end

    wmFrame.Visible = showWatermark
    if showWatermark then
        local ping = 0
        pcall(function() ping = math.floor(Players.LocalPlayer:GetNetworkPing() * 1000) end)
        wmText.Text = string.format("  Calcite   |   %d FPS   |   %d ms", math.floor(fpsAvg + 0.5), ping)
    end

    local elapsed = now - reloadStartAt
    local show = showReload and reloadStartAt > 0 and elapsed < reloadDuration
    reloadFrame.Visible = show == true
    if show then
        local progress = math.clamp(elapsed / reloadDuration, 0, 1)
        reloadFill.Size = UDim2.new(progress, 0, 1, 0)
        -- привязка к курсору: центр бара под курсором с небольшим смещением вниз
        local UIS = game:GetService("UserInputService")
        local m = UIS:GetMouseLocation()
        reloadFrame.Position = UDim2.fromOffset(m.X, m.Y + 24)
    end
end

function hud.setReloadDuration(seconds)
    if type(seconds) == "number" and seconds > 0 then
        reloadDuration = seconds
    end
end

-- entries: { { id = "aim", name = "Aim", key = "MB2", active = true/false }, ... }
-- active=true подсвечивает ряд акцентом; nil строка — скрыть ряд с таким id
function hud.setHotkeys(entries, show)
    if Instance == nil then
        return
    end

    if not show then
        if hkFrame then hkFrame.Visible = false end
        return
    end
    ensureGui()
    hkFrame.Visible = entries ~= nil and #entries > 0
    if not hkFrame.Visible then
        for id in hkRows do hideRow(id) end
        return
    end
    local seen = {}
    for i, e in ipairs(entries) do
        seen[e.id] = true
        ensureHkRow(e.id, e.key, e.name, i)
        local row = hkRows[e.id]
        if row then
            row.nameLabel.TextColor3 = textCol
            if e.active then
                row.keyLabel.TextColor3 = accent
            else
                row.keyLabel.TextColor3 = mutedCol or Color3.fromRGB(150, 150, 160)
            end
        end
    end
    for id in hkRows do
        if not seen[id] then hideRow(id) end
    end
end

return hud
end

__modules["i18n"] = function(require)
-- Canonical source strings stay stable in configs. Only their presentation is translated.
local i18n = {}
local rows = {
    { "Visuals", "Визуалы", "Visuals" }, { "Aim", "Наведение", "Aim" },
    { "Hitboxes", "Хитбоксы", "Hitboxes" }, { "Settings", "Настройки", "Settings" },
    { "Player", "Персонаж", "Player" }, { "AutoFarm", "Автофарм", "Auto farm" },
    { "Teleport", "Телепорт", "Teleport" }, { "Steal", "Сбор яиц", "Egg collection" },
    { "Search", "Поиск настроек", "Search settings" },
    { "Search...", "Поиск...", "Search..." },
    { "Overwrite config", "Сохранить изменения", "Save changes" },
    { "Overwrite", "Перезаписать", "Overwrite" }, { "Load", "Загрузить", "Load" },
    { "Delete", "Удалить", "Delete" }, { "Reset", "Сбросить", "Reset" },
    { "Config already exists", "Профиль уже существует", "Profile already exists" },
    { "Reset autoload", "Сбросить автозагрузку", "Reset autoload" },
    { "Reset autoload config", "Сбросить автозагрузку профиля", "Reset profile autoload" },
    { "Config JSON", "JSON профиля", "Profile JSON" },
    { "Import config", "Импортировать профиль", "Import profile" },
    { "Import", "Импортировать", "Import" },
    { "Export current config", "Экспортировать профиль", "Export profile" },
    { "Copied config to your clipboard", "Профиль скопирован в буфер обмена", "Profile copied to clipboard" },
    { "Configuration name cannot be empty.", "Введи название профиля.", "Enter a profile name." },
    { "Invalid config name provided.", "Недопустимое название профиля.", "Invalid profile name." },
    { "Please select a config first.", "Сначала выбери профиль.", "Select a profile first." },
    { "Configuration JSON cannot be empty", "Вставь JSON профиля.", "Paste the profile JSON." },
    { "Successfully imported config", "Профиль импортирован", "Profile imported" },
    { "Successfully reset autoload config.", "Автозагрузка отключена.", "Autoload disabled." },
    { "Are you sure you want to clear the autoload config? No config will be loaded automatically on next launch.", "Отключить автоматическую загрузку профиля при запуске?", "Disable automatic profile loading on startup?" },
    { "Are you sure you want to import this configuration? Your current settings will be overwritten.", "Импортировать профиль и заменить текущие настройки?", "Import this profile and replace current settings?" },
    { "Configuration", "Конфигурации", "Configurations" },
    { "Theme", "Оформление", "Appearance" }, { "Themes", "Темы", "Themes" },
    { "Config name", "Название профиля", "Profile name" },
    { "Create config", "Создать профиль", "Create profile" },
    { "Config list", "Профили", "Profiles" }, { "Load config", "Загрузить", "Load" },
    { "Save config", "Сохранить", "Save" }, { "Delete config", "Удалить профиль", "Delete profile" },
    { "Refresh list", "Обновить список", "Refresh list" },
    { "Set as autoload", "Загружать при запуске", "Load on startup" },
    { "Delete autoload", "Отключить автозагрузку", "Disable autoload" },
    { "Cancel", "Отмена", "Cancel" }, { "Confirm", "Подтвердить", "Confirm" },
    { "None", "Нет", "None" }, { "Always", "Всегда", "Always" },
    { "Hold", "Удерживать", "Hold" }, { "Toggle", "Переключать", "Toggle" },
    { "Enabled", "Включено", "Enabled" },
}
local pairs = {
    ["Какую брать"] = "Point priority", ["Сквозь простреливаемые стены"] = "Through penetrable walls",
    ["Боссы"] = "Bosses", ["Другие"] = "Other", ["Fast Travel"] = "Fast Travel",
    ["Интерфейс"] = "Interface", ["Применяется сразу"] = "Applies immediately",
    ["Акцент"] = "Accent", ["Сиреневый"] = "Lilac", ["Голубой"] = "Blue", ["Шалфей"] = "Sage", ["Розовый"] = "Rose",
    ["Масштаб интерфейса"] = "Interface scale", ["Скрывать оверлей при открытом меню"] = "Hide overlay while menu is open",
    ["Сохранить настройки интерфейса не удалось."] = "Could not save interface preferences.",
    ["Язык, оформление и конфигурации"] = "Language, appearance and profiles",
    ["Игроки, предметы и игровые метки"] = "Players, items and game overlays",
    ["Выбор цели и управление прицелом"] = "Target selection and aim controls",
    ["Части тела и точки наведения"] = "Body parts and target points",
    ["Перемещение персонажа"] = "Character movement", ["Автоматический сбор предметов"] = "Automatic item collection",
    ["Диалоги и взаимодействия"] = "Dialogues and interactions", ["Зоны и доставка яиц"] = "Areas and egg delivery",
    ["Быстрое перемещение"] = "Quick travel",
    ["Включено"] = "Enabled", ["Включить"] = "Enable", ["Рамка"] = "Box", ["Ник"] = "Name",
    ["Дистанция"] = "Distance", ["Полоска HP"] = "Health bar", ["Цвет рамки"] = "Box color",
    ["Цвет полного HP"] = "Full health color", ["Цвет пустого HP"] = "Empty health color",
    ["Неуязвимость"] = "Invulnerability", ["Не отображать неуязвимых"] = "Hide invulnerable players",
    ["Проверка команды"] = "Team check", ["Цвет текста"] = "Text color", ["Дальность"] = "Range",
    ["Цвет заливки"] = "Fill color", ["Прозрачность заливки"] = "Fill transparency",
    ["Цвет контура"] = "Outline color", ["Прозрачность контура"] = "Outline transparency",
    ["Сквозь стены"] = "Through walls", ["Игроки"] = "Players", ["Предметы"] = "Items",
    ["Статусы"] = "Statuses", ["Стенд"] = "Stand", ["Спек"] = "Fighting style", ["Пинг"] = "Ping",
    ["Оружие в руках"] = "Held weapon", ["Спрятанные: последнее место"] = "Last known position",
    ["Звуки: шаги тех, кого не видно"] = "Unseen footsteps", ["Гранаты: путь и место падения"] = "Grenade trajectories",
    ["Гранаты: куда полетит своя"] = "Throw preview", ["Дым и огонь: радиус и время"] = "Smoke and fire: area and timer",
    ["Кто за мной наблюдает"] = "Spectators", ["Прострел стены у прицела"] = "Wall penetration",
    ["ESP оружия"] = "Weapon ESP", ["ESP предметов"] = "Item ESP", ["Абилки E/R"] = "E/R abilities",
    ["Цвет меток"] = "Label color", ["Отображать"] = "Show", ["Собирать"] = "Collect",
    ["Ходить, пока нет цели"] = "Roam while idle", ["Скорость глайдера"] = "Glide speed",
    ["Наведение"] = "Aim", ["Основное"] = "General", ["Отображение"] = "Display", ["Аим"] = "Aim",
    ["Игнорировать блокировки (Town)"] = "Ignore action limits (Town)", ["Круг"] = "Radius",
    ["Радиус"] = "Radius", ["Полный экран"] = "Full screen", ["Скорость"] = "Speed",
    ["Показывать круг"] = "Show FOV circle", ["Точка наведения"] = "Aim point", ["Цели"] = "Target",
    ["Сначала"] = "Priority", ["Ближнего"] = "Closest to crosshair", ["Слабого"] = "Lowest health",
    ["Только видимые"] = "Visible only", ["Не трогать неуязвимых"] = "Skip invulnerable",
    ["Автовыстрел"] = "Auto fire", ["Только с клавишей аима"] = "Only with aim key",
    ["Через простреливаемую стену"] = "Through penetrable walls", ["Автостоп"] = "Auto stop",
    ["Выкл"] = "Off", ["Обычный"] = "On target", ["Ранний"] = "Early", ["Интервал"] = "Interval",
    ["Шанс попадания"] = "Hit chance", ["Оружие"] = "Weapon", ["Без разброса"] = "No spread",
    ["Части тела"] = "Body parts", ["Голова"] = "Head", ["Грудь"] = "Chest", ["Живот"] = "Stomach",
    ["Руки"] = "Arms", ["Ноги"] = "Legs", ["Выбор точки"] = "Point selection",
    ["По списку"] = "By priority", ["Ближнюю"] = "Closest", ["Мультипоинты"] = "Multipoint",
    ["До края"] = "Point radius", ["Авто-кража"] = "Auto collection", ["Зоны"] = "Areas",
    ["Автоопределять базу"] = "Detect own plot", ["Моя база (ручной)"] = "Own plot (manual)",
    ["Режим перемещения"] = "Movement mode", ["TP Up высота"] = "Teleport ascent height",
    ["TP Up задержка"] = "Ascent delay", ["TP задержка"] = "Travel delay", ["TP Down задержка"] = "Descent delay",
    ["Drop задержка"] = "Drop delay", ["WalkSpeed (Walk mode)"] = "Walking speed",
    ["Скорость глайдера (Glide mode)"] = "Glide speed", ["Z-detour (обход guard-зон)"] = "Avoid guard areas",
    ["Z коридора обхода"] = "Detour corridor Z", ["Базы"] = "Plots", ["Бхоп"] = "Bunny hop",
    ["Полёт"] = "Fly", ["Свет"] = "Lighting", ["Прицел"] = "Crosshair", ["Цвет"] = "Color",
    ["Длина плеча"] = "Arm length", ["Отступ от центра"] = "Center gap", ["Точка в центре"] = "Center dot",
    ["Ватермарка (FPS/ping)"] = "Watermark (FPS/ping)", ["Индикатор перезарядки (MVS)"] = "Reload indicator (MVS)",
    ["Hotkeys HUD"] = "Hotkeys HUD", ["Hit logs (Town)"] = "Hit logs (Town)", ["Меню"] = "Menu",
    ["Режим"] = "Game mode", ["Авто"] = "Auto", ["Клавиша меню"] = "Menu key", ["Выгрузить"] = "Unload",
    ["Выгрузка: клавиша End или кнопка ниже"] = "Unload with End or the button below",
    ["Рокаки"] = "Rokakaka", ["Стрелы"] = "Arrows", ["Монеты"] = "Coins", ["Алмазы"] = "Diamonds",
    ["Маски"] = "Masks", ["Части святого"] = "Saint's corpse parts", ["Ивентовые"] = "Event items",
    ["Остальные предметы"] = "Other items", ["Не из каталога"] = "Not in catalog",
    ["Сюжет"] = "Story", ["Тренеры"] = "Trainers", ["Магазины"] = "Shops", ["Прочее"] = "Other",
    [" ст/с"] = " st/s", [" мс"] = " ms", [" ст"] = " st",
}
local catalog = {}
for source, english in pairs do
    local entry = { ru = source, en = english }
    catalog[source] = entry
    if catalog[english] == nil then catalog[english] = entry end
end
for _, row in rows do
    local entry = { ru = row[2], en = row[3] }
    catalog[row[1]] = entry
    if catalog[row[2]] == nil then catalog[row[2]] = entry end
    -- Do not reverse-map generic English words onto a different source context.
    if catalog[row[3]] == nil then catalog[row[3]] = entry end
end

local help = {
    { "Бхоп: переключатель", "Бхоп: переключатель прыжка не найден.", "Bunny hop: jump control not found." },
    { "Бхоп: игра не слушается", "Бхоп недоступен: игра не принимает управление прыжком.", "Bunny hop unavailable: the game does not accept jump input." },
    { "Бхоп: движение", "Бхоп: зайди в матч и включи его снова.", "Bunny hop: enter a match and enable it again." },
    { "Автостоп: управление", "Автостоп: управление движением не найдено.", "Auto stop: movement control not found." },
    { "Автостоп: движение", "Автостоп: зайди в матч и выбери режим снова.", "Auto stop: enter a match and select the mode again." },
    { "Автостоп: персонаж", "Автостоп: персонаж не найден. Зайди в матч.", "Auto stop: character not found. Enter a match." },
    { "Ошибка аима,", "Наведение остановлено из-за ошибки. Подробности в консоли. Выключи и включи его снова.", "Aim stopped after an error. See the console, then toggle it off and on to retry." },
    { "Ошибка автовыстрела,", "Автовыстрел остановлен из-за ошибки. Подробности в консоли. Включи его снова.", "Auto fire stopped after an error. See the console, then enable it again." },
    { "Ошибка автофарма,", "Автофарм остановлен из-за ошибки. Подробности в консоли. Включи его снова.", "Auto farm stopped after an error. See the console, then enable it again." },
    { "Ошибка бхопа,", "Бхоп остановлен из-за ошибки. Подробности в консоли. Включи его снова.", "Bunny hop stopped after an error. See the console, then enable it again." },
    { "Ошибка автостопа,", "Автостоп остановлен из-за ошибки. Подробности в консоли. Выбери режим снова.", "Auto stop stopped after an error. See the console, then select its mode again." },
    { "Ошибка отрисовки,", "Отрисовка остановлена из-за ошибки. Подробности в консоли. Включи визуалы снова.", "Drawing stopped after an error. See the console, then enable visuals again." },
    { "Нет папки Workspace.Dialogues", "Диалоги NPC не найдены. Этот раздел предназначен для YBA.", "NPC dialogues not found. This section is for YBA." },
    { "executor не предоставляет", "Executor не поддерживает взаимодействие с NPC.", "The executor does not support NPC interaction." },
    { "Нативный Highlight", "Подсветка модели и контура. Можно показывать сквозь стены.", "Highlight player models and outlines, optionally through walls." },
    { "Показывает Tool в руках чужих +", "Оружие, патроны и перезарядка других игроков.", "Other players' weapons, ammo and reload state." },
    { "Показывает Tool в руках чужих.", "Предмет в руках, патроны и доступные способности.", "Held items, ammo and available abilities." },
    { "«Не из каталога»", "Неизвестные предметы, магазины и квестовые метки.", "Unknown items, shops and quest markers." },
    { "Персонаж идёт глайдером", "Собирает ближайшие предметы. В режиме поиска перемещается по окрестностям.", "Collects nearby items and roams the area while idle." },
    { "Silent Aim: при выстреле", "Направляет выстрел в выбранную цель. Для отключения движения мыши выключи наведение.", "Directs shots at the selected target. Disable aim assistance to keep the mouse still." },
    { "Silent Aim: клик ЛКМ отправляет выстрел в", "Использует настройки цели и видимости. Движение мыши включается отдельно.", "Uses target and visibility settings. Mouse assistance is controlled separately." },
    { "Silent Aim: клик ЛКМ отправляет выстрел по", "Только видимые цели и пистолет. Автовыстрел включается отдельно.", "Visible targets and the pistol only. Auto fire is enabled separately." },
    { "Своих пропускает", "Проверка команды находится на вкладке «Визуалы».", "Team check is on the Visuals tab." },
    { "Автостоп: выстрел ждёт", "Обычный: остановка на цели. Ранний: остановка при входе цели в круг.", "On target: stop when aiming at an enemy. Early: stop when an enemy enters the FOV." },
    { "Темп — как у оружия", "Учитывает темп оружия и разброс. Шанс попадания: 0 отключает проверку.", "Uses weapon timing and spread. Set hit chance to 0 to skip the check." },
    { "Кликает ЛКМ сам", "Стреляет, когда прицел на выбранной части тела противника.", "Fires when the crosshair is over a selected enemy body part." },
    { "Blox Strike. Угол отклонения", "Убирает разброс выстрела. Доступно в Blox Strike.", "Removes shot spread. Available in Blox Strike." },
    { "Ничего не выбрано:", "Выбери хотя бы одну часть тела.", "Select at least one body part." },
    { "«По списку»: части тела", "По списку: первая доступная часть тела. Ближнюю: ближайшая к прицелу точка.", "By priority: first available body part. Closest: point nearest the crosshair." },
    { "Кроме центра части тела", "Проверяет края части тела, если центр закрыт препятствием.", "Checks body edges when the center is behind cover." },
    { "Z-detour: все 13", "Прокладывает путь в обход промежуточных зон со стражами.", "Routes around intermediate guard areas." },
    { "TP — 3 фазы", "TP: телепорт с паузами. Walk: пешком. Glide: прямой полёт.", "TP: teleport in stages. Walk: move on foot. Glide: fly directly." },
    { "Глайдер летит в точку", "Перемещение к выбранной точке со скоростью автофарма.", "Travel to the selected point at the auto farm speed." },
    { "Держи пробел:", "Удерживай пробел для прыжка сразу после приземления.", "Hold Space to jump immediately on landing." },
    { "WASD + Пробел", "WASD — направление, пробел — вверх, левый Shift — вниз. ПКМ по переключателю — назначить клавишу.", "WASD to move, Space to ascend, left Shift to descend. Right-click the toggle to bind a key." },
    { "Проходишь сквозь стены", "Позволяет проходить сквозь стены. Выключение возвращает столкновения.", "Walk through walls. Disabling restores collisions." },
    { "Ставит ClockTime", "Постоянное дневное освещение. Выключение возвращает прежнее время.", "Keep daylight enabled. Disabling restores the original time." },
    { "Рисует крестик", "Показывает прицел по центру экрана от первого лица.", "Show a centered crosshair in first person." },
    { "Ватермарка —", "FPS и пинг, активные клавиши и игровые уведомления.", "FPS and ping, active keybinds and game notifications." },
}
for _, row in help do
    local entry = { ru = row[2], en = row[3] }
    catalog[row[2]], catalog[row[3]] = entry, entry
end

local configPatterns = {
    { "^Successfully created config (.+)$", "Профиль %s создан" },
    { "^Successfully loaded config (.+)$", "Профиль %s загружен" },
    { "^Successfully overwrote config (.+)$", "Профиль %s сохранён" },
    { "^Successfully deleted config (.+)$", "Профиль %s удалён" },
    { "^Successfully set autoload config to (.+)$", "Автозагрузка: %s" },
    { "^Current autoload config: (.+)$", "Автозагрузка: %s" },
    { "^Are you sure you want to load (.+)%? Your current settings will be overwritten%.$", "Загрузить %s и заменить текущие настройки?" },
    { "^Are you sure you want to overwrite (.+) with your current settings%? This cannot be undone%.$", "Заменить профиль %s текущими настройками? Это действие нельзя отменить." },
    { "^Are you sure you want to delete (.+)%? This cannot be undone%.$", "Удалить профиль %s? Это действие нельзя отменить." },
    { "^A config named (.+) already exists%. Overwriting will replace it with your current settings%.$", "Профиль %s уже существует. Заменить его текущими настройками?" },
    { "^Failed to create config (.+)$", "Не удалось создать профиль %s" },
    { "^Failed to load config (.+)$", "Не удалось загрузить профиль %s" },
    { "^Failed to overwrite config (.+)$", "Не удалось сохранить профиль %s" },
    { "^Failed to delete config (.+)$", "Не удалось удалить профиль %s" },
    { "^Failed to set autoload config (.+)$", "Не удалось включить автозагрузку %s" },
    { "^Failed to load autoload config: (.+)$", "Не удалось загрузить стартовый профиль: %s" },
    { "^Failed to reset autoload config: (.+)$", "Не удалось сбросить автозагрузку: %s" },
    { "^Failed to import config: (.+)$", "Не удалось импортировать профиль: %s" },
    { "^Failed to load config list: (.+)$", "Не удалось получить список профилей: %s" },
}

function i18n.new(language)
    local self = { language = if language == "en" then "en" else "ru", bindings = {}, listeners = {} }
    function self:text(source)
        if type(source) ~= "string" then return source end
        local entry = catalog[source]
        if entry then return entry[self.language] end
        for _, row in help do
            if source:sub(1, #row[1]) == row[1] then return if self.language == "en" then row[3] else row[2] end
        end
        if self.language == "en" then
            local a, b = string.match(source, "^Предметов: (%d+), показано: (%d+)$")
            if a then return "Items: " .. a .. ", shown: " .. b end
            local n = string.match(source, "^Подобрано: (%d+)$")
            if n then return "Collected: " .. n end
            return (source:gsub(" %(авто%)", " (auto)"))
        end
        local name = string.match(source, "^Current autoload config: (.*)$")
        if name then return "Автозагрузка: " .. name end
        for _, row in configPatterns do
            local value = string.match(source, row[1])
            if value then return string.format(row[2], value) end
        end
        return source
    end
    function self:bind(source, setter)
        local binding = { source = source, setter = setter }
        table.insert(self.bindings, binding)
        setter(self:text(source))
        return binding
    end
    function self:onChanged(callback) table.insert(self.listeners, callback) end
    function self:set(value)
        self.language = if value == "en" then "en" else "ru"
        for _, binding in self.bindings do binding.setter(self:text(binding.source)) end
        for _, callback in self.listeners do callback() end
    end
    return self
end

return i18n
end

__modules["item_asylum"] = function(require)
-- Item Asylum mode: pure read helpers. Враг = любой другой игрок (FFA, нет команд).
-- Факты игры из tools/itemasylum_probe.lua:
--   • игроки = топ-уровень Workspace (не папка), Character:FindFirstChildOfClass("Tool") — тулза в руках
--   • у тулзы атрибуты: OriginalOwner, ItemColor, EABILITY (имя абилки на E), RABILITY (R),
--     ToolIconText (патроны формата "11 / 16" где есть), MobileCrosshair
--   • Humanoid у Character обычный; атрибуты статуса: Status_Ragdolled, Status_OnFire
local item_asylum = {}

-- для ESP: { name, ammo (opt), eAbility (opt), rAbility (opt) }, nil если тулзы в руке нет
function item_asylum.weaponInfo(char)
    if char == nil then return nil end
    local tool = char:FindFirstChildOfClass('Tool')
    if tool == nil then return nil end
    local info = { name = tool.Name }
    -- ToolIconText часто "N / M" — патроны/макс, иногда просто N или строка-статус
    local okAmmo, ammoText = pcall(function() return tool:GetAttribute('ToolIconText') end)
    if okAmmo and type(ammoText) == 'string' and #ammoText > 0 then
        info.ammo = ammoText
    end
    local okE, eAb = pcall(function() return tool:GetAttribute('EABILITY') end)
    if okE and type(eAb) == 'string' and #eAb > 0 then info.eAbility = eAb end
    local okR, rAb = pcall(function() return tool:GetAttribute('RABILITY') end)
    if okR and type(rAb) == 'string' and #rAb > 0 then info.rAbility = rAb end
    return info
end

return item_asylum
end

__modules["item_kinds"] = function(require)
-- the kinds the item esp of YBA sorts the items of the world into, so that the menu shows or hides a whole kind at
-- once. The names are the ones of the models in ReplicatedStorage.Tool_Replicas of the game: every item it has
-- (read from the dumps of the external, 11.10.2026). What is not among them, a shop or a quest with a prompt of its
-- own or an item added since, is of the kind "unknown"
-- pure logic, checked by tests/item_kinds_test.lua
local item_kinds = {}

-- in the order of the menu; color nil is the color the user picked for the labels
item_kinds.list = {
    { id = "rokakaka", label = "Рокаки", color = { 255, 95, 150 },
        names = { "Rokakaka", "Pure Rokakaka", "Redeemed Rokakaka" } },
    { id = "arrows", label = "Стрелы", color = { 255, 205, 70 },
        names = { "Mysterious Arrow", "Lucky Arrow", "Heavenly Arrow", "Requiem Arrow" } },
    { id = "coins", label = "Монеты", color = { 240, 230, 120 },
        names = { "Gold Coin" } },
    { id = "diamonds", label = "Алмазы", color = { 110, 225, 255 },
        names = { "Diamond" } },
    { id = "masks", label = "Маски", color = { 215, 175, 125 },
        names = { "Stone Mask", "Lucky Stone Mask" } },
    { id = "corpse", label = "Части святого", color = { 190, 145, 255 },
        names = { "Heart of The Saint's Corpse", "Left Arm of The Saint's Corpse", "Pelvis of The Saint's Corpse",
            "Rib Cage of The Saint's Corpse" } },
    { id = "event", label = "Ивентовые", color = { 255, 150, 220 },
        names = { "Christmas Present", "Blue Candy", "Green Candy", "Red Candy", "Yellow Candy" } },
    { id = "items", label = "Остальные предметы", color = nil,
        names = { "Ancient Scroll", "Bottle of Blood", "Caesar's Headband", "Clackers", "Dio's Bone", "Dio's Diary",
            "Mysterious Bow", "Quinton's Glove", "Stand Virus Capsule", "Steel Ball", "Zepellin's Headband",
            "Zeppeli's Hat" } },
    { id = "unknown", label = "Не из каталога", color = nil, names = {} },
}

local byName = {}       -- the lower-case name of an item -> its kind
local byId = {}         -- id -> the entry of the list
for _, kind in item_kinds.list do
    byId[kind.id] = kind
    for _, name in kind.names do
        byName[string.lower(name)] = kind.id
    end
end

-- for a name the catalogue does not have word for word (written otherwise, or an item of the same family added
-- since): by its words. An arrow is a name that ends with the word, so "Arrowsmith" and "Requiem Arrow Quest",
-- prompts of people, are not arrows
local function byWords(low)
    if string.find(low, "rokakaka", 1, true) ~= nil then
        return "rokakaka"
    elseif low == "arrow" or string.sub(low, -6) == " arrow" then
        return "arrows"
    elseif string.find(low, "coin", 1, true) ~= nil then
        return "coins"
    elseif string.find(low, "diamond", 1, true) ~= nil then
        return "diamonds"
    elseif string.sub(low, -4) == "mask" then
        return "masks"
    elseif string.find(low, "saint's corpse", 1, true) ~= nil then
        return "corpse"
    elseif string.find(low, "candy", 1, true) ~= nil or string.find(low, "present", 1, true) ~= nil then
        return "event"
    end

    return nil
end

local function kindOfName(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end

    -- the spaces around it and the case of the letters do not matter
    local low = string.lower(string.match(name, "^%s*(.-)%s*$"))
    return byName[low] or byWords(low)
end

-- the kind of an item: by the text of its prompt, failing that by the name of the model it is
function item_kinds.of(name, model)
    return kindOfName(name) or kindOfName(model) or "unknown"
end

-- the color of the labels of a kind, nil for the color the user picked
function item_kinds.color(id)
    local kind = byId[id]
    return if kind ~= nil then kind.color else nil
end

-- a short text that tells which kinds are on, the same for the same choice: what the matching is remembered by
function item_kinds.key(kinds)
    local parts = {}
    for _, kind in item_kinds.list do
        table.insert(parts, if kinds ~= nil and kinds[kind.id] == true then "1" else "0")
    end

    return table.concat(parts)
end

-- what the settings start with: every kind of item, and not what is outside the catalogue (the shops and quests of
-- the map have prompts too; an item newer than the catalogue is there as well, for whoever switches it on)
function item_kinds.defaults()
    local kinds = item_kinds.all()
    kinds.unknown = false
    return kinds
end

-- every kind switched on
function item_kinds.all()
    local kinds = {}
    for _, kind in item_kinds.list do
        kinds[kind.id] = true
    end

    return kinds
end

return item_kinds
end

__modules["items"] = function(require)
-- the prompts of the world the item esp labels: which ones there are, where each is and what it is called
-- the owner feeds it the prompts that appear and go, see main.lua; checked by tests/items_test.lua
local item_kinds = require("./item_kinds")
local num = require("./num")
local prompt_place = require("./prompt_place")

local Items = {}
Items.__index = Items

-- root is the workspace: a prompt that is not under it any more is not shown
function Items.new(root)
    return setmetatable({
        root = root,
        entries = {},           -- { prompt, part, name, action, shown, slot }, in no particular order
        index = {},             -- prompt -> its entry
        dirty = false,          -- prompts were added since the last settle
        found = 0,              -- entries that are items of the catalogue with a place, as of the last settle
        version = 0,            -- goes up whenever what match() works with has changed
        matchedVersion = -1,
        matchedKinds = nil,
        shownCount = 0,
    }, Items)
end

-- a new prompt is only remembered here: its texts may be set a moment after it appears, settle() reads them
function Items:add(prompt)
    if self.index[prompt] ~= nil then
        return
    end

    local entry = { prompt = prompt, part = nil, name = "", action = "", kind = "unknown", shown = false, slot = #self.entries + 1 }
    self.entries[entry.slot] = entry
    self.index[prompt] = entry
    self.dirty = true
end

function Items:remove(prompt)
    local entry = self.index[prompt]
    if entry == nil then
        return
    end

    -- the last entry takes the freed place
    local last = self.entries[#self.entries]
    self.entries[entry.slot] = last
    last.slot = entry.slot
    self.entries[#self.entries] = nil
    self.index[prompt] = nil
    self.version += 1
end

-- every prompt that is in the world right now; under: the folder to look through, the whole root by default
function Items:scan(under)
    for _, object in (under or self.root):GetDescendants() do
        if object.ClassName == "ProximityPrompt" then
            self:add(object)
        end
    end
end

function Items:clear()
    table.clear(self.entries)
    table.clear(self.index)
    self.dirty = false
    self.found = 0
    self.version += 1
end

-- looks at every prompt again: is it an item, where is it, what is it called
-- cheap enough to repeat now and then, a game can rename or move what a prompt belongs to
function Items:settle()
    local found = 0

    for _, entry in self.entries do
        local prompt = entry.prompt
        local part = nil
        local name = ""
        local action = ""
        local kind = "unknown"

        if not prompt_place.excluded(prompt, self.root) then
            local named
            part, named = prompt_place.locate(prompt)
            if part ~= nil then
                name, action = prompt_place.describe(prompt, named)
                -- the kind by the text of the prompt, failing that by the name of what it sits in
                kind = item_kinds.of(name, named.Name)
                -- a shop or a quest is not counted as an item
                if kind ~= "unknown" then
                    found += 1
                end
            end
        end

        if entry.part ~= part or entry.name ~= name or entry.action ~= action or entry.kind ~= kind then
            entry.part = part
            entry.name = name
            entry.action = action
            entry.kind = kind
            self.version += 1
        end
    end

    self.found = found
    self.dirty = false
end

-- marks the entries the user wants shown, the ones of a kind switched on (kinds is a set of the ids of item_kinds),
-- returns how many there are; worked out again only when the entries or the choice changed
function Items:match(kinds)
    local key = item_kinds.key(kinds)
    if self.matchedVersion == self.version and self.matchedKinds == key then
        return self.shownCount
    end

    local count = 0
    for _, entry in self.entries do
        entry.shown = entry.part ~= nil and kinds ~= nil and kinds[entry.kind] == true
        if entry.shown then
            count += 1
        end
    end

    self.matchedVersion = self.version
    self.matchedKinds = key
    self.shownCount = count
    return count
end

-- where the item is right now; nil when it is not to be shown: taken out of the world, switched off, no place
-- a picked up item is usually removed as a whole model, so the prompt and the part are both asked
function Items:position(entry)
    local prompt = entry.prompt
    local part = entry.part
    if part == nil or not prompt.Enabled then
        return nil
    end

    if not prompt:IsDescendantOf(self.root) or not part:IsDescendantOf(self.root) then
        return nil
    end

    local position = part.Position
    local x, y, z = position.X, position.Y, position.Z
    if not num.plausible(x, y, z) then
        return nil
    end

    return x, y, z
end

return Items
end

__modules["kit"] = function(require)
-- what a player fights with in Your Bizarre Adventure: the stand and the fighting style ("spec")
-- both are plain strings the game keeps in Player.PlayerStats ("Stand" and "Spec"), seen in a dump
-- pure logic, checked by tests/kit_test.lua; a port of rbx/kit.h of the external
local kit = {}

kit.max_length = 48     -- longer than any name the game has

-- "None" is how the game writes that a player has none; empty is "not read yet"
function kit.has(value)
    return value ~= nil and value ~= "" and value ~= "None"
end

-- the value as it goes on the screen
function kit.printable(value)
    local text = string.sub(value, 1, kit.max_length)
    return (string.gsub(text, "[%z\1-\31]", "?"))
end

-- the few stands whose initials collide or that have a nickname
local known = {
    ["Six Pistols"] = "6P",         -- SP is Star Platinum
    ["Stone Free"] = "StF",         -- SF is Sticky Fingers
    ["Chariot Requiem"] = "SCR",    -- the requiem of Silver Chariot, the user calls it SCR
    ["Whitesnake"] = "WS",
    ["Aerosmith"] = "Aero",
}

-- the short name players use for a stand: the initials of its words, "King Crimson Requiem" -> "KCR"
-- a name of one word stays as it is
function kit.shortStand(stand)
    local brief = known[stand]
    if brief ~= nil then
        return brief
    end

    local initials = ""
    local words = 0

    for word in string.gmatch(stand, "[^ ]+") do
        if word == "&" then
            initials ..= "&"
            words += 1
        elseif string.find(word, "%d") ~= nil then
            -- a number ("4"), or a word that is an abbreviation already ("D4C"): kept whole, without punctuation
            initials ..= (string.gsub(word, "[^%a%d]", ""))
            words += 1
        elseif string.find(word, "%a") ~= nil then
            -- as it is written: the small word of "Made in Heaven" stays small
            initials ..= string.match(word, "%a")
            words += 1
        end
    end

    if words < 2 then
        return kit.printable(stand)
    end

    return kit.printable(initials)
end

-- the palette the stands are written in; the names are the user's words for the colours
kit.color = {
    red = { 235, 60, 60 },
    lightRed = { 255, 125, 115 },
    pinkRed = { 255, 85, 125 },
    pink = { 255, 140, 200 },
    purpleRed = { 205, 65, 145 },
    purple = { 170, 100, 240 },
    navy = { 70, 95, 190 },             -- dark blue, as dark as still reads over a black outline
    blue = { 70, 130, 255 },
    lightBlue = { 100, 200, 255 },
    ice = { 190, 235, 255 },
    turquoise = { 55, 215, 195 },
    tropical = { 70, 220, 110 },        -- bright green
    green = { 70, 160, 85 },            -- darker green
    yellow = { 255, 228, 70 },
    gold = { 255, 170, 40 },            -- gold on the orange side
    white = { 255, 255, 255 },
    grey = { 170, 170, 178 },
    other = { 190, 200, 255 },          -- a stand that is not listed, and the fighting style
}

-- a family shares a colour by the start of the name, so the more specific name has to come first
local rules = {
    { "King Crimson", kit.color.red },
    { "Star Platinum", kit.color.purple },
    { "The World Alternate Universe", kit.color.yellow },
    { "The World", kit.color.gold },
    { "Shadow The World", kit.color.purple },
    { "Crazy Diamond", kit.color.lightBlue },
    { "Gold Experience Requiem", kit.color.gold },
    { "Gold Experience", kit.color.yellow },
    { "Silver Chariot", kit.color.navy },
    { "Chariot Requiem", kit.color.navy },
    { "Made in Heaven", kit.color.white },
    { "Tusk", kit.color.pink },
    { "Soft & Wet", kit.color.lightBlue },
    { "D4C", kit.color.lightBlue },
    { "Killer Queen", kit.color.pinkRed },
    { "Sticky Fingers", kit.color.blue },
    { "Purple Haze", kit.color.purple },
    { "Hermit Purple", kit.color.purple },
    { "White Album", kit.color.ice },
    { "Beach Boy", kit.color.turquoise },
    { "Diver Down", kit.color.turquoise },
    { "The Hand", kit.color.blue },
    { "Scary Monsters", kit.color.tropical },
    { "Mr. President", kit.color.yellow },
    { "Cream", kit.color.grey },
    { "Anubis", kit.color.purpleRed },
    { "C-Moon", kit.color.green },
    { "Six Pistols", kit.color.purple },
    { "Stone Free", kit.color.lightBlue },
    { "Whitesnake", kit.color.white },
    { "Aerosmith", kit.color.lightRed },
}

-- the colour of a stand, as the user assigned them
function kit.standColor(stand)
    for _, rule in rules do
        if string.sub(stand, 1, #rule[1]) == rule[1] then
            return rule[2]
        end
    end

    return kit.color.other
end

-- the line of the esp in two pieces, since the stand has a colour of its own:
-- stand is empty when there is none to show, rest is the fighting style with the separator when a stand goes before it
-- brief asks for the short name of the stand
function kit.parts(stand, spec, showStand, showSpec, brief)
    local result = { stand = "", rest = "" }

    if showStand and kit.has(stand) then
        result.stand = if brief then kit.shortStand(stand) else kit.printable(stand)
    end

    if showSpec and kit.has(spec) then
        result.rest = (if result.stand == "" then "" else " / ") .. kit.printable(spec)
    end

    return result
end

-- the same as one string, empty when there is nothing to say
function kit.line(stand, spec, showStand, showSpec, brief)
    local pieces = kit.parts(stand, spec, showStand, showSpec, brief)
    return pieces.stand .. pieces.rest
end

-- limbs: PlayerStats also has "LeftArm", "LeftLeg" and "RightLeg" (no right arm), "Normal" unless something
-- happened to the limb; "Amputated" was seen in a dump, on a character that still had all its body parts
-- limbName is written in lower case ("left arm"); the result is empty when there is nothing to tell
function kit.limb(limbName, state)
    if state == nil or state == "" or state == "Normal" or limbName == "" then
        return ""
    end

    if state == "Amputated" then
        return "No " .. limbName
    end

    -- a state not met before is shown as the game writes it
    return string.upper(string.sub(limbName, 1, 1)) .. string.sub(limbName, 2) .. ": " .. kit.printable(state)
end

return kit
end

__modules["library"] = function(require)
-- loads the menu library: the files of one fixed commit, kept on disk after the first download
-- takes the functions of the executor as a table, so tests/library_test.lua runs it without one
local library = {}

library.commit = "d62041eda54085a03259c789d4af2be76077379f"         -- of deividcomsono/Obsidian
library.icons_commit = "04f2bbae632268b1c165b4e477340b1566606958"   -- of notpoiu/lucide-roblox-direct

local base = "https://raw.githubusercontent.com/deividcomsono/Obsidian/" .. library.commit .. "/"
local icons_url = "https://raw.githubusercontent.com/notpoiu/lucide-roblox-direct/" .. library.icons_commit .. "/source.lua"

-- the library fetches its icons from the head of somebody's branch on every load: code that can change under
-- the script; this is that call as it is written in Library.lua of the commit above
library.icons_call = 'game:HttpGet("https://raw.githubusercontent.com/notpoiu/lucide-roblox-direct/refs/heads/main/source.lua")'

local root = "Calcite"
library.folder = root .. "/lib/" .. string.sub(library.commit, 1, 7)
library.icons_path = library.folder .. "/lucide-" .. string.sub(library.icons_commit, 1, 7) .. ".lua"

function library.url(file)
    return base .. file
end

-- "addons/SaveManager.lua" is kept as "SaveManager.lua"
function library.path(file)
    return library.folder .. "/" .. string.match(file, "([^/]+)$")
end

local function ensureFolders(env)
    for _, folder in { root, root .. "/lib", library.folder } do
        if not env.isfolder(folder) then
            env.makefolder(folder)
        end
    end
end

-- nothing that could be code: not a text at all, or a text with nothing in it. An empty text compiles,
-- so asking the compiler does not tell an answer that came empty from the code
local function blank(text)
    return type(text) ~= "string" or string.find(text, "%S") == nil
end

-- replaces the call that fetches the icons with a read of the copy kept on disk
-- when that cannot be done the library is left as it is and the user is told
function library.pinIcons(env, source)
    local from, to = string.find(source, library.icons_call, 1, true)
    if from == nil then
        env.warn("Calcite: the icon loader of the menu library was not found, the icons come from the network")
        return source
    end

    -- a copy that was cut short to nothing while it was written is fetched again
    local kept = env.isfile(library.icons_path) and env.readfile(library.icons_path)
    if blank(kept) then
        local fetched, icons = pcall(env.httpGet, icons_url)
        if not fetched or blank(icons) or env.loadstring(icons, "=lucide") == nil then
            env.warn("Calcite: the icons of the menu could not be downloaded, the menu library fetches them itself")
            return source
        end

        ensureFolders(env)
        env.writefile(library.icons_path, icons)
    end

    return string.sub(source, 1, from - 1) .. 'readfile("' .. library.icons_path .. '")' .. string.sub(source, to + 1)
end

-- the text of a file as it is given to the compiler
local function prepared(env, file, source)
    if file == "Library.lua" then
        return library.pinIcons(env, source)
    end

    return source
end

-- runs a compiled file of the library. Every one of them gives back a table; a file that fails, or gives back
-- anything else, is not the library: nil comes back then, with what went wrong
local function run(chunk)
    local ok, value = pcall(chunk)
    if ok and type(value) == "table" then
        return value, nil
    end

    return nil, value
end

-- the value a file of the library returns; an error when it can be had neither from disk nor from the network
function library.load(env, file)
    local path = library.path(file)

    if env.isfile(path) then
        local chunk = env.loadstring(prepared(env, file, env.readfile(path)), "=" .. file)
        if chunk ~= nil then
            local value = run(chunk)
            if value ~= nil then
                return value
            end
        end
        -- a damaged copy: it does not compile, fails, or was cut short to nothing. Fetched again below
    end

    local fetched, source = pcall(env.httpGet, library.url(file))
    if not fetched or type(source) ~= "string" then
        error("Calcite: " .. file .. " could not be downloaded: " .. tostring(source), 0)
    end

    -- a page with an error in place of the code
    if env.loadstring(source, "=" .. file) == nil then
        error("Calcite: what was downloaded as " .. file .. " is not code", 0)
    end

    local chunk, problem = env.loadstring(prepared(env, file, source), "=" .. file)
    if chunk == nil then
        error("Calcite: " .. file .. " does not compile: " .. tostring(problem), 0)
    end

    -- an answer that came empty compiles too, so the file is kept on disk only once it has run as the library;
    -- what is kept is the file as it came
    local value, failure = run(chunk)
    if value == nil then
        error("Calcite: what was downloaded as " .. file .. " is not the library: " .. tostring(failure), 0)
    end

    ensureFolders(env)
    env.writefile(path, source)

    return value
end

return library
end

__modules["main"] = function(require)
-- the entry of the script: one running copy, the mode of the game, the frame that draws, the unload
-- everything of the game and of the executor comes in one table, see env.lua; tests/app_test.lua starts the script
-- on stand-ins of all of it
local aim = require("./aim")
local fullbright = require("./fullbright")
local town = require("./town")
local mvs = require("./mvs")
local hud = require("./hud")
local autofarm = require("./autofarm")
local flier = require("./fly")
local noclip = require("./noclip")
local chams = require("./chams")
local hitbox = require("./hitbox")
local item_asylum = require("./item_asylum")
local glider = require("./glider")
local yba_npcs = require("./yba_npcs")
local yba_waypoints = require("./yba_waypoints")
local autostop = require("./autostop")
local bhop = require("./bhop")
local clouds = require("./clouds")
local diag = require("./diag")
local draw = require("./draw")
local environment = require("./env")
local esp_items = require("./esp_items")
local esp_players = require("./esp_players")
local grenades = require("./grenades")
local guard = require("./guard")
local hitchance = require("./hitchance")
local Items = require("./items")
local library = require("./library")
local menu = require("./menu")
local modes = require("./modes")
local num = require("./num")
local penetration = require("./penetration")
local players = require("./players")
local settingsModule = require("./settings")
local sounds = require("./sounds")
local spectators = require("./spectators")
local nospread = require("./nospread")
local status = require("./status")
local steal_egg_data = require("./steal_egg_data")
local steal_farm = require("./steal_farm")
local steal_mover = require("./steal_mover")
local strike = require("./strike")
local strike_move = require("./strike_move")
local strike_net = require("./strike_net")
local throw = require("./throw")
local trigger = require("./trigger")
local weapon = require("./weapon")
local ui_preferences = require("./ui_preferences")

local main = {}

main.version = "1.30.3"

local sound_packet = "ReplicatedStorage.NetworkRemotes.Sound.ReplicateSound"    -- through which Blox Strike tells about sounds
-- and about its grenades: a throw, every bounce, the end
local spawn_packet = "ReplicatedStorage.NetworkRemotes.Projectile.Spawn"
local bounce_packet = "ReplicatedStorage.NetworkRemotes.Projectile.Bounce"
local resolve_packet = "ReplicatedStorage.NetworkRemotes.Projectile.Resolve"
-- and about the smokes and the fires on the ground, see clouds.lua
local cloud_packets = {
    ["ReplicatedStorage.NetworkRemotes.VFX.CreateVoxelSmoke"] = { kind = "smoke", act = "create" },
    ["ReplicatedStorage.NetworkRemotes.VFX.DestroyVoxelSmoke"] = { kind = "smoke", act = "destroy" },
    ["ReplicatedStorage.NetworkRemotes.VFX.CreateVoxelFire"] = { kind = "fire", act = "create" },
    ["ReplicatedStorage.NetworkRemotes.VFX.UpdateVoxelFire"] = { kind = "fire", act = "update" },
    ["ReplicatedStorage.NetworkRemotes.VFX.DestroyVoxelFire"] = { kind = "fire", act = "destroy" },
}
local sound_near = 8            -- studs: a sound this close to somebody in sight tells nothing new

local bhop_step = "CalciteBhop"  -- the name the step of the bhop is bound under
local stop_step = "CalciteAutoStop" -- and the one of the auto stop
local see_through = 20          -- parts nobody can see that a look passes through before it gives up
                                -- (accessories, оружия, visual effects — повышено для MVS с кучей частей)

local first_person_reach = 2    -- studs: a camera this close to the head of the character is the first person

local slow_interval = 0.3      -- seconds between two passes over what changes rarely, as the cache of the external
local settle_interval = 5       -- seconds between two looks at where every item is and what it is called

-- starts the script; gives back a handle with unload(), or nil when it could not start
function main.start(env)
    env = env or environment.fromGlobals()

    if env.DrawingImmediate == nil or env.Drawing == nil then
        env.warn("Calcite: this executor has no DrawingImmediate, the script needs Potassium")
        return nil
    end

    -- one copy at a time: the one started before is taken down first
    local shared = env.getgenv()
    local previous = shared.Calcite
    if type(previous) == "table" and type(previous.unload) == "function" then
        pcall(previous.unload)
    end
    shared.Calcite = nil

    local game = env.game
    local workspace = env.cloneref(env.workspace)
    local Players = env.cloneref(game:GetService("Players"))
    local UserInputService = env.cloneref(game:GetService("UserInputService"))
    local ReplicatedStorage = env.cloneref(game:GetService("ReplicatedStorage"))
    local HttpService = env.cloneref(game:GetService("HttpService"))
    local RunService = env.cloneref(game:GetService("RunService"))
    local localPlayer = Players.LocalPlayer
    local universeId = game.GameId

    -- asked for by Fullbright only, and only while it has something to do
    local function lighting()
        return env.cloneref(game:GetService("Lighting"))
    end

    -- the menu library first: when it cannot be had, nothing is left running
    local loaded, Library, ThemeManager, SaveManager = pcall(function()
        return library.load(env, "Library.lua"),
            library.load(env, "addons/ThemeManager.lua"),
            library.load(env, "addons/SaveManager.lua")
    end)
    if not loaded then
        env.warn("Calcite: the menu could not be loaded. " .. tostring(Library))
        return nil
    end

    -- as the mode the game is told to be starts; a config the menu loads later may set anything otherwise
    local settings = settingsModule.defaults(modes.detect(universeId))
    settings.interface = ui_preferences.load(ui_preferences.executorIO(env, HttpService))

    -- what the script is doing, written to workspace\Calcite\diag.txt while the user has asked for it, see diag.lua
    local D = diag.new({
        started = env.clock(),
        write = function(text)
            if not env.isfolder("Calcite") then
                env.makefolder("Calcite")
            end

            env.writefile("Calcite/diag.txt", text)
        end,
    })

    -- a warning goes to the console of the game, and into the diagnostics
    local function warn(message)
        D:event("warn: " .. tostring(message), env.clock())
        env.warn(message)
    end
    local d = draw.new(env)
    local esp = esp_players.new()
    local items = Items.new(workspace)
    local roster = {}               -- player -> record of players.lua
    local targets = {}

    -- the characters of a game that builds them by itself, see strike.lua
    local ownCharacters = strike.new({
        workspace = workspace,
        replicatedStorage = ReplicatedStorage,
        players = Players,
        localPlayer = localPlayer,
        -- the game keeps some of what it tells as JSON texts; nil for a text that is not one
        decode = function(text)
            local ok, value = pcall(function()
                return HttpService:JSONDecode(text)
            end)

            if ok and type(value) == "table" then
                return value
            end

            return nil
        end,
    })

    local connections = {}
    local itemConnections = {}
    local itemsOn = false
    local unloaded = false
    local libraryGone = false
    local lastSlow = -math.huge
    local lastSettle = -math.huge
    local camera = nil
    local ui = nil
    local frameGuard = nil
    local farm = nil                -- the auto farm, see autofarm.lua
    local farmGuard = nil
    local aimGuard = nil
    local fireGuard = nil
    local hopGuard = nil
    local stopGuard = nil
    local flyGuard = nil
    local noclipper = nil   -- NoClip (Town): создаётся ниже в setup, тут объявлен для unload-pcall
    local chammer = nil     -- Chams: создаётся ниже в setup, тут объявлен для unload-pcall
    local walker = nil      -- forward-declared: menu callbacks (onTeleport) use it before walker is actually created below
    local stealer = nil     -- the auto steal of Steal an Egg, see steal_farm.lua; declared here for the unload
    -- the settings in effect in the mode of the last frame (settings.inEffect): what runs outside the frame, a click
    -- or the hook on the shot of a game, goes by these, never by the switches as they are written
    local current = nil
    local shooter = nil             -- the auto fire, see trigger.lua
    local handle = nil

    -- what the executor gives back for a connection is known from its documentation only: one that cannot be
    -- taken back the expected way must not stop the others from being taken back
    local function disconnect(list)
        for _, connection in list do
            pcall(function()
                connection:Disconnect()
            end)
        end

        table.clear(list)
    end

    -- the prompts of the world are followed only while the items are on; on YBA the items are under
    -- Workspace.Item_Spawns.Items. Only the workspace: items.lua leaves out a prompt that is not under it
    local function setItems(on)
        if on == itemsOn then
            return
        end

        itemsOn = on

        if on then
            items:scan()

            table.insert(itemConnections, workspace.DescendantAdded:Connect(function(object)
                if object.ClassName == "ProximityPrompt" then
                    items:add(object)
                end
            end))

            table.insert(itemConnections, workspace.DescendantRemoving:Connect(function(object)
                if object.ClassName == "ProximityPrompt" then
                    items:remove(object)
                end
            end))
        else
            disconnect(itemConnections)
            items:clear()
        end
    end

    -- the packets of the game the script listens to, see strike_net.lua: looked for once, all of them in one pass
    -- over the tables of the game, the first time something needs one
    local packets = {}              -- the full name of the remote -> the packet
    local packetSearch = "none"     -- "none", "running" or "done"
    local packetWaiters = {}

    -- runs fn once the packets were looked for: at once when they were
    local function withPackets(fn)
        if packetSearch == "done" then
            fn()
            return
        end

        table.insert(packetWaiters, fn)
        if packetSearch == "none" then
            packetSearch = "running"
            local names = { sound_packet, spawn_packet, bounce_packet, resolve_packet }
            for name in cloud_packets do
                table.insert(names, name)
            end

            strike_net.findMany(env, names, function(found)
                packets = found
                packetSearch = "done"

                local waiting = packetWaiters
                packetWaiters = {}
                for _, waiter in waiting do
                    waiter()
                end
            end)
        end
    end

    -- listens to a packet; gives back what takes the listener away, nil when the packet is not there
    local function listen(name, handler)
        local packet = packets[name]
        if packet == nil then
            return nil
        end

        local ok, stop = pcall(function()
            return packet.Listen(handler)
        end)

        if ok and type(stop) == "function" then
            return stop
        end

        return nil
    end

    -- the clock of the server: the one the game stamps what it tells with
    local function serverNow()
        local ok, now = pcall(function()
            return workspace:GetServerTimeNow()
        end)

        if ok and type(now) == "number" then
            return now
        end

        return env.clock()
    end

    -- the sounds the server tells about: the game hands them to whoever listens to its packet
    local heard = sounds.new()
    local soundStop = nil           -- takes the listener away
    local soundsWanted = false
    local soundWarned = false

    local function onSound(payload)
        -- comes from the game at any moment, with whatever the server sent
        pcall(function()
            if unloaded or not soundsWanted or type(payload) ~= "table" then
                return
            end

            local position = payload.Position
            local x, y, z = position.X, position.Y, position.Z

            -- a step of somebody who is in sight anyway, or of the user, is not worth a mark
            if num.plausible(x, y, z) and not ownCharacters:nearVisible(x, y, z, sound_near) then
                heard:push(x, y, z, payload.Class, payload.Name, env.clock())
            end
        end)
    end

    local function listenToSounds()
        if soundStop ~= nil or not soundsWanted or unloaded then
            return
        end

        soundStop = listen(sound_packet, onSound)

        if packets[sound_packet] == nil and not soundWarned then
            soundWarned = true
            warn("Calcite: the sound packet of the game was not found, the marks of sounds are off")
        end
    end

    local function setSounds(on)
        if on == soundsWanted then
            return
        end

        soundsWanted = on

        if not on then
            if soundStop ~= nil then
                pcall(soundStop)
                soundStop = nil
            end

            heard:clear()
            return
        end

        withPackets(listenToSounds)
    end

    -- the grenades, see grenades.lua. Their way is worked out with rays through the world, cast the way the game
    -- casts them for its own grenades (Controllers.Observers.Game.Grenade): what a grenade meets goes by its
    -- collision group alone, and only what lies thrown away and the user himself are left out
    local grenadeParams = nil
    local grenadeGroup = false      -- the group the parameters are set to; false before the first ray
    local grenadeIgnored = {}
    local grenadeIgnoredAt = -math.huge
    if env.RaycastParams ~= nil then
        grenadeParams = env.RaycastParams.new()
        grenadeParams.FilterType = env.Enum.RaycastFilterType.Exclude
        grenadeParams.RespectCanCollide = false
        grenadeParams.IgnoreWater = true
    end

    local function grenadeRay(x, y, z, dx, dy, dz, group)
        if grenadeParams == nil then
            return nil
        end

        -- a way is hundreds of rays, the list of what is left out is made anew once a second
        local now = env.clock()
        if now - grenadeIgnoredAt >= 1 or now < grenadeIgnoredAt then
            grenadeIgnoredAt = now
            grenadeIgnored = {}

            local eye = workspace.CurrentCamera
            if eye ~= nil then
                table.insert(grenadeIgnored, eye)
            end

            -- the grenades themselves are drawn there, and the weapons that were dropped
            local debris = workspace:FindFirstChild("Debris")
            if debris ~= nil then
                table.insert(grenadeIgnored, debris)
            end

            local character = localPlayer.Character
            if character ~= nil then
                table.insert(grenadeIgnored, character)
            end

            for _, model in ownCharacters.own do
                if model ~= character then
                    table.insert(grenadeIgnored, model)
                end
            end
        end
        grenadeParams.FilterDescendantsInstances = grenadeIgnored

        if group ~= grenadeGroup then
            grenadeGroup = group
            -- a group this client has not heard of is an error of the engine; the default one is the next best
            local known = group ~= nil and pcall(function()
                grenadeParams.CollisionGroup = group
            end)

            if not known then
                pcall(function()
                    grenadeParams.CollisionGroup = "Default"
                end)
            end
        end

        local hit = workspace:Raycast(env.Vector3.new(x, y, z), env.Vector3.new(dx, dy, dz), grenadeParams)
        if hit == nil then
            return nil
        end

        -- off a player a grenade keeps less of its speed; the game tells a player by the model its part is in
        local isPlayer = false
        pcall(function()
            local parent = hit.Instance.Parent
            isPlayer = parent ~= nil and parent:IsA("Model") and parent:GetAttribute("CharacterType") == "PlayerCustomCharacter"
        end)

        local position, normal = hit.Position, hit.Normal
        return position.X, position.Y, position.Z, normal.X, normal.Y, normal.Z, isPlayer
    end

    local thrown = grenades.new({ ray = grenadeRay })
    local grenadeStops = {}         -- take the listeners away
    local grenadesWanted = false
    local grenadeWarned = false
    local grenadeFailed = false

    local function listenToGrenades()
        if #grenadeStops > 0 or not grenadesWanted or unloaded then
            return
        end

        local handlers = {
            [spawn_packet] = function(payload)
                thrown:spawn(payload, serverNow())
            end,
            [bounce_packet] = function(payload)
                thrown:bounce(payload, serverNow())
            end,
            [resolve_packet] = function(payload)
                thrown:resolve(payload, env.clock())
            end,
        }

        for name, handler in handlers do
            local stop = listen(name, function(payload)
                -- comes from the game at any moment, with whatever the server sent; an error must not get back
                -- into the code of the game
                if unloaded or not grenadesWanted then
                    return
                end

                local ok, message = pcall(handler, payload)
                if not ok and not grenadeFailed then
                    grenadeFailed = true
                    warn("Calcite: a grenade could not be followed\n" .. tostring(message))
                end
            end)

            if stop ~= nil then
                table.insert(grenadeStops, stop)
            end
        end

        -- without the word of a throw there is nothing to follow
        if packets[spawn_packet] == nil and not grenadeWarned then
            grenadeWarned = true
            warn("Calcite: the grenade packets of the game were not found, the ways of grenades are off")
        end
    end

    local function setGrenades(on)
        if on == grenadesWanted then
            return
        end

        grenadesWanted = on

        if not on then
            for _, stop in grenadeStops do
                pcall(stop)
            end

            table.clear(grenadeStops)
            thrown:clear()
            return
        end

        withPackets(listenToGrenades)
    end

    -- the smokes and the fires on the ground, see clouds.lua: what the server tells about them, as it tells it
    local sky = clouds.new()
    local cloudStops = {}
    local cloudsWanted = false
    local cloudsWarned = false
    local cloudFailed = false
    local cloudKinds = { smoke = true, fire = true }

    local function listenToClouds()
        if #cloudStops > 0 or not cloudsWanted or unloaded then
            return
        end

        local any = false
        for name, what in cloud_packets do
            local stop = listen(name, function(payload)
                -- comes from the game at any moment, with whatever the server sent
                if unloaded or not cloudsWanted then
                    return
                end

                local ok, message = pcall(function()
                    if what.act == "create" then
                        sky:create(what.kind, payload, env.clock())
                    elseif what.act == "update" then
                        sky:update(what.kind, payload, env.clock())
                    else
                        sky:destroy(what.kind, payload)
                    end
                end)

                if not ok and not cloudFailed then
                    cloudFailed = true
                    warn("Calcite: a smoke or a fire could not be read\n" .. tostring(message))
                end
            end)

            if stop ~= nil then
                any = true
                table.insert(cloudStops, stop)
            end
        end

        if not any and not cloudsWarned then
            cloudsWarned = true
            warn("Calcite: the packets of the smokes and the fires of the game were not found, their rings are off")
        end
    end

    local function setClouds(on)
        if on == cloudsWanted then
            return
        end

        cloudsWanted = on

        if not on then
            for _, stop in cloudStops do
                pcall(stop)
            end

            table.clear(cloudStops)
            sky:clear()
            return
        end

        withPackets(listenToClouds)
    end

    -- the movement of the game, see strike_move.lua: looked for once, the first time something needs it; the
    -- bhop steps by it and the way of the grenade in the hand starts from it
    local movement = nil            -- what strike_move.find gave, once it was found
    local moveSearch = "none"       -- "none", "running", "found" or "missing"
    local moveWaiters = {}

    -- runs onFound(movement) once the movement was found, onMissing() when it was not: at once when that is known
    local function withMovement(onFound, onMissing)
        if moveSearch == "found" then
            onFound(movement)
            return
        elseif moveSearch == "missing" then
            onMissing()
            return
        end

        table.insert(moveWaiters, { found = onFound, missing = onMissing })
        if moveSearch == "none" then
            moveSearch = "running"

            local function tell(key)
                local waiting = moveWaiters
                moveWaiters = {}
                for _, waiter in waiting do
                    waiter[key](movement)
                end
            end

            strike_move.find(env, function(link)
                movement = link
                moveSearch = "found"
                tell("found")
            end, function()
                moveSearch = "missing"
                tell("missing")
            end)
        end
    end

    -- the bhop: while it is on, it steps right before the game steps its movement
    local hopper = nil
    local hopBound = false
    local hopWanted = false

    local function bindHop()
        if hopBound or hopper == nil then
            return
        end

        hopBound = pcall(function()
            -- the game steps its movement two priorities before the camera; one earlier, the state the bhop reads
            -- is the one after the last tick, and what it tells is in time for the next
            RunService:BindToRenderStep(bhop_step, env.Enum.RenderPriority.Camera.Value - 3, function()
                if not unloaded and hopWanted and hopGuard ~= nil then
                    hopGuard.run()
                end
            end)
        end)
    end

    local function unbindHop()
        if not hopBound then
            return
        end

        hopBound = false
        pcall(function()
            RunService:UnbindFromRenderStep(bhop_step)
        end)
    end

    local function setBhop(on)
        if on == hopWanted then
            return
        end

        hopWanted = on

        if not on then
            unbindHop()
            return
        end

        withMovement(function(link)
            if link.setJump == nil then
                warn("Calcite: the switch of the jump of the game was not found, the bhop is off")
                if ui ~= nil then
                    ui.notify("Calcite", "Бхоп: переключатель прыжка игры не найден.")
                end

                return
            end

            if hopper == nil then
                hopper = bhop.new({
                    state = link.state,
                    setJump = link.setJump,
                    jumpDown = link.jumpDown,
                    ineffective = function()
                        warn("Calcite: the game does not follow the jump it is told, the bhop does nothing")
                        if ui ~= nil then
                            ui.notify("Calcite", "Бхоп: игра не слушается переключателя прыжка, прыжки остаются твоими.")
                        end
                    end,
                })
            end

            if hopWanted and not unloaded then
                bindHop()
            end
        end, function()
            warn("Calcite: the movement of the game was not found, the bhop is off")
            if ui ~= nil then
                ui.notify("Calcite", "Бхоп: движение игры не найдено. Зайди в матч и переключи «Включить» ещё раз.")
            end
        end)
    end

    -- the auto stop: while the auto fire wants the user still, he is walked against his motion right before the game
    -- steps it, see autostop.lua; whether he is wanted still is worked out on every frame by the auto fire
    local stopOn = false            -- a kind of the auto stop is picked, and the auto fire is on
    local stopBound = false
    local stopWanted = false
    local stopWarned = false
    local stopTold = nil            -- whether the last walk reached a character; nil before the first
    local walkWarned = false

    local function bindStop()
        if stopBound then
            return
        end

        stopBound = pcall(function()
            -- as the bhop: after the controls of Roblox have told the game the keys, before the game steps
            RunService:BindToRenderStep(stop_step, env.Enum.RenderPriority.Camera.Value - 3, function()
                if not unloaded and stopWanted and stopGuard ~= nil then
                    stopGuard.run()
                end
            end)
        end)
    end

    local function unbindStop()
        if not stopBound then
            return
        end

        stopBound = false
        pcall(function()
            RunService:UnbindFromRenderStep(stop_step)
        end)
    end

    local function setStop(on)
        if on == stopOn then
            return
        end

        stopOn = on

        if not on then
            stopWanted = false
            unbindStop()
            return
        end

        withMovement(function(link)
            if link.setMove == nil then
                if not stopWarned then
                    stopWarned = true
                    warn("Calcite: the walk of the character of the game was not found, the auto stop is off")
                    if ui ~= nil then
                        ui.notify("Calcite", "Автостоп: управление ходьбой игры не найдено, автостоп выключен.")
                    end
                end

                return
            end

            if stopOn and not unloaded then
                bindStop()
            end
        end, function()
            if not stopWarned then
                stopWarned = true
                warn("Calcite: the movement of the game was not found, the auto stop is off")
                if ui ~= nil then
                    ui.notify("Calcite", "Автостоп: движение игры не найдено. Зайди в матч и выбери режим ещё раз.")
                end
            end
        end)
    end

    -- another look for the movement of the game, when it was not there the last time: the bhop and the auto stop
    -- ask for it once the user switches them on again
    local function lookAgain()
        if moveSearch == "missing" then
            moveSearch = "none"
            hopWanted = false
            stopOn = false
            stopWarned = false
            previewWarned = false
        end

        stopTold = nil
        walkWarned = false
    end

    -- the grenade in the hand: where it would go if it were thrown now, see throw.lua
    -- what the user holds is told by an attribute of the player, as a JSON text; decoded once per text
    local heldText = nil
    local heldName = nil
    local wayOfHeld = nil           -- the way worked out last, and what it was worked out for
    local wayKey = nil
    local wayAt = -math.huge
    local previewWarned = false
    local previewFailed = false

    local function heldWeapon()
        local text = localPlayer:GetAttribute("CurrentEquipped")
        if text ~= heldText then
            heldText = text
            heldName = nil

            if type(text) == "string" and text ~= "" then
                local ok, decoded = pcall(function()
                    return HttpService:JSONDecode(text)
                end)

                if ok and type(decoded) == "table" and type(decoded.Name) == "string" then
                    heldName = decoded.Name
                end
            end
        end

        return heldName
    end

    -- the way of the grenade in the hand, nil when the user holds none or the game cannot be read
    local function previewWay(now)
        local weapon = heldWeapon()

        -- the two sides have a collision group each for their grenades
        local group = if localPlayer:GetAttribute("Team") == "Terrorists" then "TGrenade" else "CTGrenade"
        local config = grenades.configFor(weapon, group)
        if config == nil then
            wayOfHeld = nil
            wayKey = nil
            if D.on then
                D:state("preview", "no grenade in the hand; the game says: " .. tostring(weapon) .. " <- " .. tostring(heldText), now)
            end

            return nil, weapon
        end

        if moveSearch ~= "found" then
            withMovement(function() end, function()
                if not previewWarned then
                    previewWarned = true
                    warn("Calcite: the movement of the game was not found, the way of the grenade in the hand is not shown")
                end
            end)

            if moveSearch ~= "found" then
                D:state("preview", "holds " .. tostring(weapon) .. "; the movement of the game: " .. moveSearch, now)
                return nil, weapon
            end
        end

        local state = movement.state()
        if type(state) ~= "table" then
            D:state("preview", "holds " .. tostring(weapon) .. "; the movement has no state: " .. type(state), now)
            return nil, weapon
        end

        local ok, way = pcall(function()
            local place, speed = state.Position, state.Velocity
            local yaw, pitch = state.LookYaw, state.VerticalLook

            -- the right button throws near; both at once came out near more often than not
            local kind = if UserInputService:IsMouseButtonPressed(env.Enum.UserInputType.MouseButton2) then "Near" else "Far"

            -- worked out anew when something it depends on changed, and not more often than fifteen times a second:
            -- a way is hundreds of rays
            local key = string.format("%s|%s|%s|%.2f|%.2f|%.2f|%.4f|%.4f|%.1f|%.1f|%.1f", weapon, group, kind, place.X, place.Y, place.Z, yaw, pitch,
                speed.X, speed.Y, speed.Z)
            if key == wayKey then
                return wayOfHeld
            end

            if wayOfHeld ~= nil and now - wayAt < 1 / 15 and now >= wayAt then
                return wayOfHeld
            end

            local lx, ly, lz = throw.look(yaw, pitch)
            local start = throw.start(place.X, place.Y, place.Z, lx, ly, lz, kind, speed.X, speed.Y, speed.Z)
            if start == nil then
                return nil
            end

            wayKey = key
            wayAt = now
            wayOfHeld = thrown:way(config, start.x, start.y, start.z, start.vx, start.vy, start.vz, 0, 0, false, start.jump)
            return wayOfHeld
        end)

        if not ok then
            if not previewFailed then
                previewFailed = true
                warn("Calcite: the way of the grenade in the hand could not be worked out\n" .. tostring(way))
            end

            D:state("preview", "holds " .. tostring(weapon) .. "; error: " .. tostring(way), now)
            return nil, weapon
        end

        if D.on then
            if way == nil then
                D:state("preview", "holds " .. tostring(weapon) .. "; no throw could be made of the state", now)
            else
                D:state("preview", string.format("holds %s; way: %s, %d points, ends %.0f studs from its start", tostring(weapon), way.reason,
                    #way.points, math.sqrt((way.endX - way.points[1].x) ^ 2 + (way.endY - way.points[1].y) ^ 2 + (way.endZ - way.points[1].z) ^ 2)), now)
            end
        end

        return way, weapon
    end

    local function unload()
        if unloaded then
            return
        end

        -- every step by itself: unloading happens once, so a step that fails must not leave the rest standing
        unloaded = true
        -- first of all: a button the script holds down must not stay down
        if shooter ~= nil then
            pcall(function()
                shooter:release()
            end)
        end

        disconnect(connections)
        pcall(unbindHop)
        pcall(unbindStop)
        pcall(setItems, false)
        pcall(setSounds, false)
        pcall(setGrenades, false)
        pcall(setClouds, false)
        if farm ~= nil then
            pcall(function()
                farm:stop()
            end)
        end

        if stealer ~= nil then
            pcall(function()
                stealer:stop()
            end)
        end

        if walker ~= nil then
            pcall(function()
                walker:stop()
            end)
        end

        pcall(hud.destroy)
        pcall(fullbright.step, false, lighting)
        -- NoClip: при выгрузке восстанавливаем коллизию, чтобы персонаж не остался невидимым для стен
        pcall(function() if noclipper ~= nil then noclipper:step(false) end end)
        -- Chams: при выгрузке убираем Highlight'ы со всех моделей, иначе зависнут поверх игроков
        pcall(function() if chammer ~= nil then chammer:cleanup() end end)
        pcall(d.destroy)

        -- when it is the library that is going away, it must not be told to go again
        if ui ~= nil and not libraryGone then
            pcall(ui.unload)
        end

        if shared.Calcite == handle then
            shared.Calcite = nil
        end
    end

    local built, result = pcall(menu.create, {
        Library = Library,
        ThemeManager = ThemeManager,
        SaveManager = SaveManager,
        Color3 = env.Color3,
        settings = settings,
        universeId = universeId,
        version = main.version,
        env = env,
        username = localPlayer.Name,
        userId = localPlayer.UserId,
        onInterfaceChanged = function(preferences)
            local ok, problem = ui_preferences.save(ui_preferences.executorIO(env, HttpService), preferences)
            if not ok then warn("Calcite: could not save interface preferences: " .. tostring(problem)) end
        end,
        onUnload = unload,
        onLibraryUnload = function()
            libraryGone = true
            unload()
        end,
        -- switching the esp on is how the user asks for another try after an error stopped the drawing
        onEnabled = function()
            if frameGuard ~= nil then
                frameGuard.reset()
            end
        end,
        -- and the same for the aim and for the auto fire
        onAimEnabled = function()
            if aimGuard ~= nil then
                aimGuard.reset()
            end
        end,
        onFireEnabled = function()
            if fireGuard ~= nil then
                fireGuard.reset()
            end
        end,
        -- for the bhop it also means "look for the movement of the game again", when it was not there the last time
        onFarmEnabled = function()
            if farmGuard ~= nil then
                farmGuard.reset()
            end
        end,
        onBhopEnabled = function()
            if hopGuard ~= nil then
                hopGuard.reset()
            end

            lookAgain()
        end,
        -- and so for the auto stop, when a kind of it is picked
        onAutoStopPicked = function()
            if stopGuard ~= nil then
                stopGuard.reset()
            end

            lookAgain()
        end,
        -- NPC dialogue trigger: looks up a model in Workspace.Dialogues by its Dialogue StringValue (or by model
        -- name when the dialogue is shared by many NPCs — Item Machine, FastTravel) and fires its prompt. Works
        -- without teleport thanks to fireproximityprompt. See yba_npcs.lua for the catalogue
        -- Steal an Egg teleport buttons: glider to the point. Works regardless of farm/steal state
        onTeleport = function(x, y, z)
            if walker == nil then return end
            walker:goTo(x, y + 3, z)
        end,
        onCallNpc = function(dialogueValue, modelName)
            local dialogues = workspace:FindFirstChild("Dialogues")
            if dialogues == nil then
                ui.notify("Calcite", "Нет папки Workspace.Dialogues (не YBA?)")
                return
            end

            local target = nil
            for _, model in dialogues:GetChildren() do
                if model:IsA("Model") then
                    if modelName ~= nil then
                        if model.Name == modelName then target = model break end
                    else
                        local sv = model:FindFirstChild("Dialogue")
                        if sv and sv:IsA("StringValue") and sv.Value == dialogueValue then
                            target = model
                            break
                        end
                    end
                end
            end

            if target == nil then
                ui.notify("Calcite", "NPC '" .. tostring(modelName or dialogueValue) .. "' сейчас не в мире (может ещё не заспавнился)")
                return
            end

            local prompt = nil
            for _, d in target:GetDescendants() do
                if d:IsA("ProximityPrompt") then prompt = d break end
            end
            if prompt == nil then
                ui.notify("Calcite", "У NPC '" .. target.Name .. "' нет ProximityPrompt")
                return
            end

            if type(env.fireproximityprompt) ~= "function" then
                ui.notify("Calcite", "executor не предоставляет fireproximityprompt — нужен другой")
                return
            end

            local ok, err = pcall(env.fireproximityprompt, prompt)
            if not ok then
                ui.notify("Calcite", "fireproximityprompt упал: " .. tostring(err))
            end
        end,
    })
    if not built then
        warn("Calcite: the menu could not be built. " .. tostring(result))
        pcall(function()
            Library:Unload()
        end)
        unload()
        return nil
    end

    ui = result

    local function project(x, y, z)
        local point = camera:WorldToViewportPoint(env.Vector3.new(x, y, z))
        return point.X, point.Y, point.Z > 0
    end

    -- the aim moves the mouse and nothing else; an executor that cannot do that has no aim
    local canAim = type(env.mousemoverel) == "function"
    local aimWarned = false
    local aimOwn = false            -- whether the frame that aims is of a game that builds its characters by itself

    local rayParams = nil
    if env.RaycastParams ~= nil then
        rayParams = env.RaycastParams.new()
        rayParams.FilterType = env.Enum.RaycastFilterType.Exclude
        rayParams.IgnoreWater = true
    end

    -- the characters of the players, looked up once a frame: every ray of sees() lets them through, and asking the
    -- game for all of them again for every ray of every target was a hitch in a full server
    local frameNumber = 0
    local bodiesFrame = -1
    local bodies = {}
    local function playerBodies()
        if bodiesFrame ~= frameNumber then
            bodiesFrame = frameNumber
            table.clear(bodies)
            for _, player in Players:GetPlayers() do
                local body = player.Character
                if body ~= nil then
                    table.insert(bodies, body)
                end
            end
        end

        return bodies
    end

    -- whether nothing of the world stands between the camera and that point of that character
    local function sees(x, y, z, record)
        if rayParams == nil then
            return true
        end

        local origin = camera.CFrame.Position
        local direction = env.Vector3.new(x - origin.X, y - origin.Y, z - origin.Z)

        -- not walls: what hangs on the camera (the hands and the weapon of a shooter), the user, the one looked at,
        -- and in a game that builds its characters by itself all of them: they stand in one folder with the user's own.
        -- также игнорим ВСЕ живые Character-ы других игроков — иначе союзник/противник между нами и целью считается
        -- стеной. Для «visible = нет геометрии мира между нами», что чаще всего и нужно
        local ignored = { camera }
        local character = localPlayer.Character
        if character ~= nil then
            table.insert(ignored, character)
        end

        if record.body ~= nil then
            table.insert(ignored, record.body)
        end

        -- живые игроки — не стены
        for _, c in playerBodies() do
            if c ~= character and c ~= record.body then
                table.insert(ignored, c)
            end
        end

        if aimOwn then
            local folder = workspace:FindFirstChild("Characters")
            if folder ~= nil then
                table.insert(ignored, folder)
            end

            for _, fence in ownCharacters.fences do
                table.insert(ignored, fence)
            end
        end

        for _ = 0, see_through do
            rayParams.FilterDescendantsInstances = ignored
            local hit = workspace:Raycast(origin, direction, rayParams)
            if hit == nil then
                return true
            end

            local part = hit.Instance
            -- не стены:
            --   • полностью прозрачные (Transparency >= 1) — маркеры/зоны
            --   • visual-only: non-collidable AND полупрозрачные (Transparency > 0.5) — effect-parts, beams,
            --     HandleBeamAttach и прочее что оружие шлёпает в Workspace при выстреле
            --   • всё что принадлежит какому-то Character (игрок/NPC)
            --   • всё что внутри какого-либо Tool (своё оружие, чужое — визуальные detail-parts)
            local skip = false
            if part == nil then skip = true end
            local transparency = part and part.Transparency
            if not skip and type(transparency) == "number" and transparency >= 1 then skip = true end
            if not skip and part.CanCollide == false and type(transparency) == "number" and transparency > 0.5 then
                skip = true
            end
            if not skip then
                local p = part.Parent
                if p ~= nil and (p:FindFirstChildOfClass("Humanoid") or (p.Parent and p.Parent:FindFirstChildOfClass("Humanoid"))) then
                    skip = true
                end
            end
            if not skip and part:FindFirstAncestorOfClass("Tool") ~= nil then
                skip = true
            end

            if not skip then
                return false
            end

            table.insert(ignored, part)
        end

        return false
    end

    -- the mouse is not the script's while the game is not the window in front
    local function focused()
        if type(env.isrbxactive) ~= "function" then
            return true
        end

        local ok, active = pcall(env.isrbxactive)
        return not ok or active ~= false
    end

    local aimer = aim.new({
        project = project,
        mouse = function()
            local location = UserInputService:GetMouseLocation()
            return location.X, location.Y
        end,
        move = function(dx, dy)
            env.mousemoverel(dx, dy)
        end,
        sees = sees,
    })

    -- NoSpread + Silent Aim: both ride on one hook on the game's _performRaycast, see nospread.lua. The target
    -- picker reuses the aim's own picker so Silent Aim respects the same zones, FOV radius, max distance and
    -- visibility as the regular aim. Put on only in the game whose module it is; the switches are read as they are
    -- in effect, and since the hook stays on the module of the game after an unload, it is off from then on
    if modes.has(modes.detect(universeId), "ShotHook") then
        nospread.start({
            task = env.task,
            gameRequire = env.gameRequire,
            replicatedStorage = ReplicatedStorage,
            workspace = workspace,
            isNoSpreadEnabled = function()
                return not unloaded and current ~= nil and current.nospread.enabled == true
            end,
            isSilentEnabled = function()
                return not unloaded and current ~= nil and current.silentaim.enabled == true
            end,
            pickSilentTarget = function()
                return aimer:pickWorld(targets, settings.aim, settings.teamCheck)
            end,
        })
    end

    -- Town: Silent Aim стоит хуком на workspace.Raycast через hookfunction + newcclosure (НЕ
    -- hookmetamethod на __namecall — Town ловит namecallInstance detector). Фильтр по caller
    -- script: сработает ТОЛЬКО если raycast из LocalScript в Tool в руках локального игрока.
    -- Один клик = один родной FireEvent с подменённой целью, никаких дублей пакетов. См. town.lua
    town.setup({ task = env.task, players = Players, workspace = workspace,
        virtualInputManager = env.virtualInputManager,
        gameRequire = env.gameRequire,
        -- Hit logs: уведомление в правом верхнем углу «Hit <name> in <zone> for <X> hp» после
        -- успешного выстрела autoFire. Показывается только если тумблер включён (settings.hitLogs)
        onHit = function(name, zone, damage)
            if current == nil or current.hitLogs == nil or not current.hitLogs.enabled then return end
            local text = string.format("Hit %s in %s for %d hp", tostring(name), tostring(zone), math.floor(damage + 0.5))
            pcall(ui.notify, "Calcite", text)
        end,
    })
    town.start({
        env = env,
        localPlayer = localPlayer,
        isEnabled = function()
            return not unloaded and current ~= nil and current.townSilent ~= nil and current.townSilent.enabled == true
        end,
    })
    mvs.setup({
        players = Players,
        workspace = workspace,
        replicatedStorage = ReplicatedStorage,
        gameRequire = env.gameRequire,
    })
    hud.setup({
        players = Players,
        workspace = workspace,
        game = game,
        Instance = env.Instance,
        UDim = env.UDim,
        UDim2 = env.UDim2,
        Color3 = env.Color3,
        Enum = env.Enum,
        Vector2 = env.Vector2,
    })

    -- a click of the left button: the silent aim of MVS shoots (один GunKill поверх родного fire+showBeam),
    -- the reload bar starts. Town silent aim стоит отдельным хуком на workspace.Raycast (town.start),
    -- отдельный вызов на клик не нужен. By the settings in effect, so that a click in one game does nothing of another
    table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
        if processed or current == nil or input.UserInputType ~= env.Enum.UserInputType.MouseButton1 then
            return
        end

        if current.mvsSilent.enabled then
            mvs.shootOnce()
        end

        -- reload bar: любой ЛКМ клик с MVS-пушкой в руках = выстрел (свой или родной)
        if current.reloadBar.enabled then
            local char = localPlayer.Character
            local tool = char and char:FindFirstChildOfClass("Tool")
            if tool and tool:FindFirstChild("fire") then
                hud.markShot(env.clock())
            end
        end
    end))

    -- the auto fire presses the left button and nothing else; an executor that cannot do that has none
    local canFire = type(env.mouse1press) == "function" and type(env.mouse1release) == "function"
    local fireWarned = false

    shooter = trigger.new({
        press = function()
            D:event("fire: the left button goes down", env.clock())
            env.mouse1press()
        end,
        release = function()
            D:event("fire: the left button comes up", env.clock())
            env.mouse1release()
        end,
        userHolds = function()
            return UserInputService:IsMouseButtonPressed(env.Enum.UserInputType.MouseButton1) == true
        end,
    })

    -- the look through the crosshair: from where the camera is, along the ray the pixel under the cursor looks along
    local lookOrigin, lookDirection = nil, nil

    local function castLook(ignored)
        rayParams.FilterDescendantsInstances = ignored
        local hit = workspace:Raycast(lookOrigin, lookDirection, rayParams)
        return hit and hit.Instance
    end

    -- not in the way of a look: what hangs on the camera and the user himself; the bodies of the others stay, the look
    -- is for them
    local function lookIgnored()
        local ignored = { camera }
        local character = localPlayer.Character
        if character ~= nil then
            table.insert(ignored, character)
        end

        if aimOwn then
            for _, model in ownCharacters.own do
                table.insert(ignored, model)
            end

            for _, fence in ownCharacters.fences do
                table.insert(ignored, fence)
            end
        end

        return ignored
    end

    -- whether the crosshair rests on what is to be shot at, and who that is, see trigger.onTarget; range is how far the
    -- look goes
    local function crosshairOnTarget(s, trace, range)
        if rayParams == nil then
            return false
        end

        local location = UserInputService:GetMouseLocation()
        local ray = camera:ViewportPointToRay(location.X, location.Y)
        local direction = ray.Direction
        range = range or s.aim.maxDistance
        lookOrigin = ray.Origin
        lookDirection = env.Vector3.new(direction.X * range, direction.Y * range, direction.Z * range)

        return trigger.onTarget(targets, s.aim, s.teamCheck, castLook, lookIgnored(), trace)
    end

    -- whether a shot would hit often enough: the share of the cone of the spread of the weapon (weapon.spread) whose
    -- rays end on a part of somebody to shoot at, drawn the way the game draws a shot, from the middle of the screen
    local cone = {}

    local function wouldHit(s, spread, range)
        -- Silent Aim redirects the ray to whoever the aim picker chose, so any valid target in the FOV is a sure
        -- shot regardless of what the game's spread says. In the jump the game's spread would normally hold the
        -- auto fire back, but with Silent Aim the bullet goes where we send it
        if s.silentaim.enabled and aimer:pickWorld(targets, s.aim, s.teamCheck) ~= nil then
            return true
        end

        -- NoSpread forces the raycast through the crosshair, so the game's cone collapses to a single ray
        if s.nospread.enabled then
            spread = 0
        end

        if s.aim.hitChance <= 0 or spread == nil or rayParams == nil then
            return true
        end

        local viewport = camera.ViewportSize
        local ray = camera:ViewportPointToRay(viewport.X * 0.5, viewport.Y * 0.5)
        local forward = ray.Direction
        local count = hitchance.directions(forward.X, forward.Y, forward.Z, math.rad(spread * 0.5), cone)
        local ignored = lookIgnored()
        lookOrigin = ray.Origin

        return hitchance.enough(cone, count, s.aim.hitChance / 100, function(x, y, z)
            lookDirection = env.Vector3.new(x * range, y * range, z * range)
            return trigger.onTarget(targets, s.aim, s.teamCheck, castLook, table.clone(ignored))
        end)
    end

    -- by itself: an error of the aim stops the aim and leaves the drawing
    aimGuard = guard.new(function(s, now, held)
        aimer:update(targets, s.mouseAim, s.teamCheck, held, now, d)
    end, function(message)
        warn("Calcite: the aim stopped after an error\n" .. tostring(message))
        ui.notify("Calcite", "Ошибка аима, аим остановлен. Подробности в консоли. Чтобы включить снова, "
            .. "переключи «Включено» на вкладке «Аим».")
    end)

    -- whether a bullet gets through what is in front of the user, by the rule of the game, see penetration.lua
    -- what a weapon is told by the module of the game that describes it: its Penetration and Range
    local weaponProps = {}          -- name -> { power, range }, or false for one that cannot be read
    local propsWarned = false

    local function propsOf(name)
        if type(name) ~= "string" then
            return nil
        end

        local known = weaponProps[name]
        if known == nil then
            known = false
            pcall(function()
                local database = ReplicatedStorage:FindFirstChild("Database")
                local custom = database and database:FindFirstChild("Custom")
                local weapons = custom and custom:FindFirstChild("Weapons")
                local module = weapons and weapons:FindFirstChild(name)
                if module ~= nil then
                    local ok, props = pcall(env.gameRequire, module)
                    if not ok and not propsWarned then
                        -- without it no weapon is known, and the mark at the crosshair stays empty
                        propsWarned = true
                        warn("Calcite: the module of a weapon could not be read, whether walls can be shot through is not shown\n"
                            .. tostring(props))
                    end

                    if ok and type(props) == "table" and type(props.Penetration) == "number" then
                        known = { power = props.Penetration, range = if type(props.Range) == "number" then props.Range else 500 }
                    end
                end
            end)
            weaponProps[name] = known
        end

        return known or nil
    end

    local bulletParams, exitParams = nil, nil
    if env.RaycastParams ~= nil then
        bulletParams = env.RaycastParams.new()
        bulletParams.FilterType = env.Enum.RaycastFilterType.Exclude
        exitParams = env.RaycastParams.new()
        exitParams.FilterType = env.Enum.RaycastFilterType.Include
        -- the group the game shoots in; one the client has not heard of is an error of the engine
        pcall(function()
            bulletParams.CollisionGroup = "Bullet"
            exitParams.CollisionGroup = "Bullet"
        end)
    end

    local bulletIgnored = {}

    local bulletWorld = {
        cast = function(x, y, z, dx, dy, dz)
            bulletParams.FilterDescendantsInstances = bulletIgnored
            local hit = workspace:Raycast(env.Vector3.new(x, y, z), env.Vector3.new(dx, dy, dz), bulletParams)
            if hit == nil then
                return nil
            end

            local position, normal = hit.Position, hit.Normal
            return { instance = hit.Instance, x = position.X, y = position.Y, z = position.Z, nx = normal.X, ny = normal.Y, nz = normal.Z }
        end,
        ignore = function(instance)
            table.insert(bulletIgnored, instance)
        end,
        filtered = function(instance)
            return instance:FindFirstAncestorWhichIsA("Accessory") ~= nil or instance:HasTag("CharacterAccessory")
                or instance.Name == "CollisionCapsule" or instance.Name == "HumanoidRootPart"
        end,
        -- the way out of a part: a ray from far beyond, back to the part alone
        exitOf = function(instance, x, y, z, ux, uy, uz)
            exitParams.FilterDescendantsInstances = { instance }
            local fromX, fromY, fromZ = x + ux * 1000, y + uy * 1000, z + uz * 1000
            local hit = workspace:Raycast(env.Vector3.new(fromX, fromY, fromZ), env.Vector3.new(x - fromX, y - fromY, z - fromZ), exitParams)
            if hit == nil then
                return nil
            end

            local position, normal = hit.Position, hit.Normal
            return position.X, position.Y, position.Z, normal.X, normal.Y, normal.Z
        end,
        allowance = function(instance)
            local parent = instance.Parent
            local isDoor = parent ~= nil and parent:HasTag("BreakableDoor")
            local mapName = workspace:GetAttribute("Map")
            return penetration.allowance(instance.Material.Name, instance.MaterialVariant, isDoor,
                if type(mapName) == "string" then mapName else nil)
        end,
    }

    -- what the game leaves out of a shot (Components.Common.GetRayIgnore): what lies thrown away, the camera, the
    -- parts of a map that are not for bullets, and the user himself
    local function shotIgnored()
        local list = { camera }
        local debris = workspace:FindFirstChild("Debris")
        if debris ~= nil then
            table.insert(list, debris)
        end

        local map = workspace:FindFirstChild("Map")
        if map ~= nil then
            for _, name in { "Cameras", "Barriers", "Ambience" } do
                local folder = map:FindFirstChild(name)
                if folder ~= nil then
                    table.insert(list, folder)
                end
            end

            local zones = map:FindFirstChild("Zones")
            if zones ~= nil then
                for _, name in { "Spawns", "Sites" } do
                    local folder = zones:FindFirstChild(name)
                    if folder ~= nil then
                        table.insert(list, folder)
                    end
                end
            end
        end

        local character = localPlayer.Character
        if character ~= nil then
            table.insert(list, character)
        end
        for _, model in ownCharacters.own do
            if model ~= character then
                table.insert(list, model)
            end
        end

        return list
    end

    local shot = nil                -- what the last way of a bullet came to, see penetration.read
    local shotAt = -math.huge

    -- the way of a bullet from the middle of the screen, as the game shoots, with the weapon in the hand; not more
    -- often than thirty times a second: it is a ray, and two more for every part on the way
    local function traceShot(s, now)
        if now - shotAt < 1 / 30 and now >= shotAt then
            return shot
        end
        shotAt = now
        shot = nil

        local props = propsOf(heldWeapon())
        if props == nil or bulletParams == nil then
            return nil
        end

        local viewport = camera.ViewportSize
        local ray = camera:ViewportPointToRay(viewport.X * 0.5, viewport.Y * 0.5)
        local origin, direction = ray.Origin, ray.Direction

        bulletIgnored = shotIgnored()
        local result = penetration.trace(origin.X, origin.Y, origin.Z, direction.X, direction.Y, direction.Z, props.range, props.power, bulletWorld)

        -- who of the others it reaches: one the aim would go for, not a teammate nor one the game has put away
        shot = penetration.read(result, function(instance)
            for _, target in targets do
                local body = target.record.body
                if body ~= nil and instance:IsDescendantOf(body) and not target.hidden and not (s.teamCheck and target.sameTeam) then
                    return target
                end
            end

            return nil
        end)

        return shot
    end

    -- whether a shot of the user would go where the crosshair is, see autostop.accurate; nil when that cannot be
    -- told, or when nothing would stop him: then a shot is not held back. The second value: he is on the ground
    local function stillEnough()
        if not stopBound or movement == nil or stopTold == false or stopGuard.broken then
            return nil, false
        end

        local state = movement.state()
        local velocity = if type(state) == "table" then state.Velocity else nil
        if velocity == nil then
            return nil, false
        end

        return autostop.accurate(velocity.X, velocity.Z, state.OnGround), state.OnGround == true
    end

    -- for the early stop: somebody the aim would go for is in its circle, and can be seen
    local function inCircle(s, now)
        if aimer.pickedAt == now and aimer.pickedWith == s.aim and s.aim.visibleOnly then
            return aimer.picked ~= nil
        end

        return aimer:pick(targets, setmetatable({ visibleOnly = true }, { __index = s.aim }), s.teamCheck) ~= nil
    end

    local waitingSince = nil        -- since when a shot waits for a stop on the ground
    local slowWarned = false

    -- the weapon in the hands, where the game is one whose weapons the script can read (see weapon.lua): what
    -- weapon.read gives (nil when there is nothing to shoot with in them), and whether it could be read at all
    local inHands = {}
    local armsWarned = false

    local function weaponOf(smart)
        if not smart then
            return nil, false
        end

        if moveSearch ~= "found" then
            if moveSearch == "none" then
                withMovement(function() end, function() end)
            end

            if moveSearch ~= "found" then
                return nil, false
            end
        end

        if movement.weapon == nil then
            if not armsWarned then
                armsWarned = true
                warn("Calcite: the weapons of the game were not found, the auto fire clicks by its interval")
            end

            return nil, false
        end

        return weapon.read(movement.weapon(), env.tick(), inHands), true
    end

    -- and so does an error of the auto fire; the button is let go of whatever happened
    fireGuard = guard.new(function(s, firing, free, held, dt, now, smart)
        -- the menu is open, the window is not in front, or the auto fire was switched off with the button down
        if not firing or not free then
            shooter:release()
            return
        end

        -- the weapon in the hands: with nothing to shoot with in them (a knife, a grenade, the bomb) nothing is looked at
        local w, known = weaponOf(smart)
        if D.on then
            D:state("fire.weapon", if w ~= nil then string.format("%s: %s, %s, due in %s, %d rounds, %s, spread %s",
                tostring(w.name), if w.automatic then "held" else "clicked", if w.shooting then "between shots" else "ready",
                if w.due ~= nil then string.format("%.3f", w.due - now) else "-", w.rounds, if w.usable then "usable" else "not usable",
                if w.spread ~= nil then string.format("%.2f", w.spread) else "?") elseif known then "nothing to shoot with" else "not known", now)
        end

        if known and w == nil then
            shooter:release()
            return
        end

        -- as far as the bullet of the weapon goes, when that is known
        local range = s.aim.maxDistance
        if w ~= nil and w.range ~= nil then
            range = math.min(range, w.range)
        end

        -- a look is a ray through the world: not cast while the key it waits for is up, nor while the button is down
        -- for a click; while it is held for a spray it goes on, it is what lets go of the button
        local looking = (not shooter:holding() or shooter:spraying()) and (held or not s.aim.autoFireNeedsKey)
        local on = false
        local aimedAt = nil         -- the target under the crosshair
        if looking then
            if D.on then
                local trace = {}
                on, aimedAt = crosshairOnTarget(s, trace, range)
                D:state("fire.look", table.concat(trace, " | "), env.clock())
            else
                on, aimedAt = crosshairOnTarget(s, nil, range)
            end
        elseif D.on and not shooter:holding() then
            D:state("fire.look", "not cast: waits for the key of the aim", env.clock())
        end

        -- somebody behind a wall the bullet gets through
        local throughWall = false
        if not on and looking and s.aim.autoFireThroughWalls then
            local seen = traceShot(s, env.clock())
            if seen ~= nil and seen.target ~= nil and seen.walls > 0 then
                on = trigger.allowed(seen.target, seen.part.Name, s.aim)
                throughWall = on
                aimedAt = seen.target
                if D.on then
                    D:state("fire.throughWall", tostring(seen.target.record.name) .. " behind " .. seen.walls .. " wall(s): " .. tostring(on), env.clock())
                end
            end
        end

        -- the auto stop: the user is stopped while there is somebody to shoot at, and the shot waits until he is slow
        local kind = s.aim.autoStop
        if kind ~= "Off" and (held or not s.aim.autoFireNeedsKey) then
            local early = kind == "Early" and not on and not shooter:holding() and inCircle(s, now)
            stopWanted = autostop.wanted(kind, on or shooter:holding(), early)
        end

        local waits = false
        if on and kind ~= "Off" and (not shooter:holding() or shooter:spraying()) then
            local still, grounded = stillEnough()
            if still == false and not grounded then
                -- in the air walking stops nothing: the shot waits for the ground
                on = false
            elseif still == false then
                -- on the ground a stop takes a fraction of a second; one that does not come is not waited for: the
                -- game did not follow, or something pushes the user
                waits = true
                waitingSince = waitingSince or now
                if now - waitingSince < autostop.patience then
                    on = false
                elseif not slowWarned then
                    slowWarned = true
                    warn("Calcite: the auto stop did not stop the user in " .. autostop.patience .. " s, the shot went anyway")
                end
            end

            if D.on then
                D:state("stop.shot", if on then "goes" else "waits: " .. (if grounded then "too fast" else "in the air"), now)
            end
        end

        if not waits then
            waitingSince = nil
        end

        if w == nil then
            shooter:update(on, held, s.aim, dt)
            return
        end

        -- whether the shot would hit often enough: asked only when the answer decides something, it costs rays (a
        -- shot through a wall is left to the rule of the wall, the rays of a look stop at it)
        local decides = w.usable and (shooter:spraying() or (not shooter:holding() and (w.automatic or not w.shooting
            or w.due == nil or w.due - now <= trigger.press_ahead)))
        -- an automatic weapon fires in bursts as long as weapon.burst says for how far the target is, and a new burst
        -- waits until the weapon has come back from the last one (weapon.recovered), unless the target is near
        local distance = if aimedAt ~= nil and aimedAt.haveDistance then aimedAt.distance else nil
        local burst = nil
        if w.automatic then
            burst = weapon.burst(distance)
            if on and burst ~= math.huge and not shooter:spraying() and not w.recovered then
                on = false
                if D.on then
                    D:state("fire.chance", "a new burst waits for the weapon to come back", now)
                end
            end
        end

        if on and decides and not throughWall then
            -- a semi-automatic weapon that has not come back from its last shot (weapon.recovered): the next one only
            -- where even its widest spread hits, that is from up close; elsewhere it waits, as a player taps a pistol
            local recovering = not w.automatic and not w.recovered
            on = wouldHit(s, if recovering then w.worst else w.spread, range)
            if D.on then
                D:state("fire.chance", (if on then "enough" else "too low") .. (if recovering then ", recovering: by the widest spread" else "")
                    .. (if burst ~= nil then ", burst " .. tostring(burst) .. " at " .. (if distance ~= nil then string.format("%.0f st", distance) else "?") else ""), now)
            end
        end

        shooter:updateWeapon(on, held, s.aim, w, now, burst)
    end, function(message)
        pcall(function()
            shooter:release()
        end)

        warn("Calcite: the auto fire stopped after an error\n" .. tostring(message))
        ui.notify("Calcite", "Ошибка автовыстрела, он остановлен. Подробности в консоли. Чтобы включить снова, "
            .. "переключи «Включить» в группе «Автовыстрел».")
    end)

    -- and so does an error of the bhop
    -- the glider: short CFrame steps every frame instead of a snap to the item (tools/yba_probe3.lua shows this is
    -- the pattern Slowc2960 and other YBA farmers use). The glider is driven from the auto-farm guard below, so it
    -- only moves while the farm is running
    walker = glider.new({
        rootPosition = function()
            local character = localPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if root == nil then
                return nil, nil, nil
            end
            local pos = root.Position
            return pos.X, pos.Y, pos.Z
        end,
        setRootPosition = function(x, y, z)
            local character = localPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if root ~= nil then
                root.CFrame = env.CFrame.new(x, y, z)
                root.AssemblyLinearVelocity = env.Vector3.new(0, 0, 0)
            end
        end,
    })

    -- the fly, see fly.lua: same CFrame-step technique as the glider, but driven by WASD + Space + Shift relative
    -- to the camera; keeps the velocity zero every frame so Humanoid physics does not drop the character
    local flyer = flier.new({
        rootPosition = function()
            local character = localPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if root == nil then
                return nil, nil, nil
            end
            local pos = root.Position
            return pos.X, pos.Y, pos.Z
        end,
        setRootPosition = function(x, y, z)
            local character = localPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if root ~= nil then
                root.CFrame = env.CFrame.new(x, y, z)
                root.AssemblyLinearVelocity = env.Vector3.new(0, 0, 0)
            end
        end,
    })

    -- NoClip (Town): CanCollide=false на всех BaseParts персонажа каждый кадр. step() вызывается в frame-loop
    noclipper = noclip.new({
        character = function() return localPlayer.Character end,
    })

    -- Chams: Highlight-подсветка моделей чужих. step() в кадре со списком targets
    chammer = chams.new({
        Instance = env.Instance,
        Color3 = env.Color3,
        Enum = env.Enum,
    })

    -- Steal an Egg auto-steal, see steal_farm.lua. Shares the glider with the auto farm (they don't run at the
    -- same time since the modes are different). Carrying state comes from two EggWorld remotes
    local stealCarrying = false

    local function enabledStealPrompts()
        local result = {}
        for _, part in workspace:GetChildren() do
            if part.Name == "SmartPromptPart" and part:IsA("BasePart") then
                for _, p in part:GetChildren() do
                    if p:IsA("ProximityPrompt") and p.Enabled
                            and p.ObjectText == "Egg" and p.ActionText == "Steal" then
                        local pos = part.Position
                        table.insert(result, { prompt = p, x = pos.X, y = pos.Y, z = pos.Z })
                        break
                    end
                end
            end
        end
        return result
    end

    -- Движок перемещения stealer'а: Walk/Glide/TP + Z-detour. См. steal_mover.lua
    local stealMover = steal_mover.new({
        stealSettings = function() return settings.steal end,
        humanoid = function()
            local char = localPlayer.Character
            return char and char:FindFirstChildOfClass("Humanoid") or nil
        end,
        rootPart = function()
            local char = localPlayer.Character
            return char and char:FindFirstChild("HumanoidRootPart") or nil
        end,
        env = env,
        task = env.task,
        walker = walker,
    })

    stealer = steal_farm.new({
        moveTo = function(x, y, z) stealMover:moveTo(x, y, z) end,
        arrived = function() return stealMover:arrived() end,
        stopMoving = function() stealMover:stop() end,
        firePrompt = function(prompt)
            if type(env.fireproximityprompt) == "function" then
                pcall(env.fireproximityprompt, prompt)
            end
        end,
        isCarrying = function() return stealCarrying end,
        areas = steal_egg_data.areas,
        enabledPrompts = enabledStealPrompts,
    })

    -- what follows listens to Steal an Egg and looks through its plots: in any other game there is nothing of it
    local stealGame = modes.detect(universeId) == "StealEgg" and env.task ~= nil
    local stealWasOn = false        -- whether the auto steal ran in the last frame: it is stopped once when it goes off

    if stealGame then
        env.task.spawn(function()
            local function connectRemote(name, handler)
                local pkgs = ReplicatedStorage:FindFirstChild("Packages")
                local net = pkgs and pkgs:FindFirstChild("Networking")
                if net == nil then return end
                for _, c in net:GetDescendants() do
                    if (c:IsA("RemoteEvent") or c:IsA("UnreliableRemoteEvent"))
                            and string.find(c.Name, name, 1, true) then
                        pcall(function()
                            table.insert(connections, c.OnClientEvent:Connect(handler))
                        end)
                    end
                end
            end
            connectRemote("FieldEggCarry", function() stealCarrying = true end)
            connectRemote("FieldEggRedeemVerdict", function() stealCarrying = false end)
            connectRemote("FieldEggGone", function() stealCarrying = false end)
        end)
    end

    -- авто-детект собственного Plot: ищем в Workspace.Plots.N.PlotSign TextLabel с именем игрока. Повторяется
    -- раз в 5 с пока не найдёт — plot назначается сервером не сразу
    local function detectMyPlot()
        local plots = workspace:FindFirstChild("Plots")
        if plots == nil then return nil end
        local me = localPlayer.Name
        local meDisplay = localPlayer.DisplayName
        for i = 1, 7 do
            local plot = plots:FindFirstChild(tostring(i))
            if plot ~= nil then
                for _, d in plot:GetDescendants() do
                    if d:IsA("TextLabel") or d:IsA("TextButton") then
                        local text = d.Text
                        if type(text) == "string" and text ~= "" then
                            if text == me or text == meDisplay
                                    or string.find(text, me, 1, true)
                                    or string.find(text, meDisplay, 1, true) then
                                return i
                            end
                        end
                    end
                end
            end
        end
        return nil
    end

    if stealGame then
        env.task.spawn(function()
            while not unloaded do
                if settings.steal and settings.steal.autoPlot ~= false then
                    local p = detectMyPlot()
                    if p ~= nil and p ~= settings.steal.myPlot then
                        settings.steal.myPlot = p
                    end
                end
                env.task.wait(5)
            end
        end)
    end

    -- the auto farm, see autofarm.lua: the character is sent to an item through the glider, settles, then the key
    -- of the prompt is held
    farm = autofarm.new({
        moveTo = function(x, y, z)
            walker:goTo(x, y, z)
        end,
        arrived = function()
            return walker:phase() == "arrived"
        end,
        stopMoving = function()
            walker:stop()
        end,
        holdBegin = function(prompt)
            prompt:InputHoldBegin()
        end,
        holdEnd = function(prompt)
            prompt:InputHoldEnd()
        end,
    })

    -- the roam: when the farm has nothing to go for, the glider amb­les to a waypoint so new spawns come in sight.
    -- Three sources of waypoints, picked in order (yba_spawner_probe showed the game keeps spawn coordinates on the
    -- server and the client never sees them; the trick is to use the live items we already see as goals, since the
    -- paths between them cover the places that spawn things):
    --   1. any live model in Workspace.Item_Spawns.Items, even if not of a kind the user picked — the glider passes
    --      others on the way, and the farm takes anything streamed in while we move
    --   2. a point from the spawn history (where models have appeared before), old enough to have respawned
    --   3. a scored random point around the character (last resort), with a short memory of recent picks and a
    --      radius that grows the longer the farm goes dry
    -- a filter that excludes the user's own character is rebuilt as the character respawns
    local roamParams = env.RaycastParams.new()
    roamParams.FilterType = env.Enum.RaycastFilterType.Exclude
    roamParams.IgnoreWater = false
    local lastRoam = -math.huge
    local lastTakenAt = -math.huge
    local lastTakenCount = 0
    local roamMemory = {}               -- recent random-roam waypoints: { x, y, z, at }
    local roamMemoryMax = 8
    local recentWaypoints = {}          -- where the glider last tried to go to (for the "do not re-pick" check)
    local recentWaypointsMax = 6
    local recentWaypointCooldown = 20   -- seconds a visited waypoint is not picked again
    local spawnHistory = {}             -- { x, y, z, at } of models seen in Workspace.Item_Spawns.Items
    local spawnHistoryMax = 150
    local spawnHistoryMinAge = 60       -- seconds: a history point is reused only after this long (so the server has respawned)
    local roam_cooldown = 0.4
    local tries_per_pick = 8
    local dry_grow_after = 20
    local dry_grow_cap = 3.0

    local function remember(x, y, z, at)
        table.insert(roamMemory, 1, { x = x, y = y, z = z, at = at })
        while #roamMemory > roamMemoryMax do
            table.remove(roamMemory)
        end
    end

    local function noteWaypoint(x, y, z, at)
        table.insert(recentWaypoints, 1, { x = x, y = y, z = z, at = at })
        while #recentWaypoints > recentWaypointsMax do
            table.remove(recentWaypoints)
        end
    end

    local function isRecentWaypoint(x, z, now)
        for _, p in recentWaypoints do
            if now - p.at < recentWaypointCooldown then
                local dx, dz = x - p.x, z - p.z
                if dx * dx + dz * dz < 25 * 25 then
                    return true
                end
            end
        end
        return false
    end

    -- "центральная" часть модели — верхняя BasePart, как в пробе; nil если BasePart'ов нет
    local function modelCenter(model)
        local center, topY = nil, -math.huge
        for _, desc in model:GetDescendants() do
            if desc:IsA("BasePart") and desc.Position.Y > topY then
                topY = desc.Position.Y
                center = desc
            end
        end
        return center and center.Position or nil
    end

    local function recordSpawn(x, y, z, at)
        table.insert(spawnHistory, { x = x, y = y, z = z, at = at })
        while #spawnHistory > spawnHistoryMax do
            table.remove(spawnHistory, 1)
        end
    end

    -- слушатель Items/.ChildAdded — помечает каждый спавн как исторически известную точку
    local function hookSpawnHistory()
        local spawnFolder = workspace:FindFirstChild("Item_Spawns")
        local itemsFolder = spawnFolder and spawnFolder:FindFirstChild("Items")
        if itemsFolder == nil then
            return
        end
        for _, model in itemsFolder:GetChildren() do
            local p = modelCenter(model)
            if p ~= nil then
                recordSpawn(p.X, p.Y, p.Z, env.clock())
            end
        end
        -- при добавлении модели нужно подождать чтобы descendants появились
        pcall(function()
            table.insert(connections, itemsFolder.ChildAdded:Connect(function(model)
                env.task.wait(0.1)
                local p = modelCenter(model)
                if p ~= nil then
                    recordSpawn(p.X, p.Y, p.Z, env.clock())
                end
            end))
        end)
    end
    if modes.detect(universeId) == "Yba" and env.task ~= nil then
        env.task.spawn(hookSpawnHistory)
    end

    -- waypoint #1: любая живая модель в Workspace.Item_Spawns.Items, не недавно посещённая
    local function pickLiveItem(cx, cy, cz, now)
        local spawnFolder = workspace:FindFirstChild("Item_Spawns")
        local itemsFolder = spawnFolder and spawnFolder:FindFirstChild("Items")
        if itemsFolder == nil then
            return nil, nil, nil
        end
        local best, bestD2 = nil, math.huge
        for _, model in itemsFolder:GetChildren() do
            local p = modelCenter(model)
            if p ~= nil and not isRecentWaypoint(p.X, p.Z, now) then
                local dx, dy, dz = p.X - cx, p.Y - cy, p.Z - cz
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 < bestD2 then
                    bestD2 = d2
                    best = p
                end
            end
        end
        if best == nil then
            return nil, nil, nil
        end
        return best.X, best.Y + 2.5, best.Z
    end

    -- waypoint #2: user-hand-picked точки из src/yba_waypoints.lua, цикл по порядку. Пропускаем те, что находятся
    -- в arrivedRadius от персонажа — не стоим на точке, в которой только что были
    local waypointIdx = 0
    local function pickUserWaypoint(cx, cz)
        local n = #yba_waypoints
        if n == 0 then
            return nil, nil, nil
        end
        local arrivedRadius = 30            -- студов: ближе — считаем что уже тут, идём к следующему
        for _ = 1, n do
            waypointIdx = (waypointIdx % n) + 1
            local p = yba_waypoints[waypointIdx]
            local dx, dz = p.x - cx, p.z - cz
            if dx * dx + dz * dz > arrivedRadius * arrivedRadius then
                return p.x, p.y + 2.5, p.z
            end
        end
        -- все точки близко к персонажу (невероятно): возвращаем текущую, пусть глайдер постоит
        local p = yba_waypoints[waypointIdx]
        return p.x, p.y + 2.5, p.z
    end

    -- waypoint #3: точка из истории спавнов (где раньше был предмет), давностью ≥ spawnHistoryMinAge
    local function pickHistoryPoint(cx, cy, cz, now)
        local best, bestScore = nil, -math.huge
        for _, p in spawnHistory do
            if now - p.at >= spawnHistoryMinAge and not isRecentWaypoint(p.x, p.z, now) then
                local dx, dz = p.x - cx, p.z - cz
                local d2 = dx * dx + dz * dz
                -- ближе — лучше, но слегка штрафуем совсем близкие (<30 студ) чтоб не прыгать на месте
                local score = -d2
                if d2 < 900 then score -= 10000 end
                if score > bestScore then
                    bestScore = score
                    best = p
                end
            end
        end
        if best == nil then
            return nil, nil, nil
        end
        return best.x, best.y + 2.5, best.z
    end

    -- waypoint #3: случайная точка (старый поведение) — fallback
    local function pickRoamPoint(cx, cy, cz, baseRadius, now)
        local character = localPlayer.Character
        roamParams.FilterDescendantsInstances = character and { character } or {}

        -- stretch the radius while the farm has been dry: more ground covered means more chance to touch a spawn
        local dry = now - lastTakenAt
        local factor = 1
        if dry > dry_grow_after then
            factor = 1 + math.min(dry_grow_cap - 1, (dry - dry_grow_after) / 15)
        end
        local radius = baseRadius * factor

        local best = nil
        local bestScore = -math.huge
        for _ = 1, tries_per_pick do
            local angle = math.random() * math.pi * 2
            local r = radius * (0.5 + math.random() * 0.5)      -- 50..100% of radius
            local tx = cx + math.cos(angle) * r
            local tz = cz + math.sin(angle) * r

            local ray = workspace:Raycast(env.Vector3.new(tx, cy + 500, tz), env.Vector3.new(0, -2000, 0), roamParams)
            if ray == nil then
                continue        -- void below: no ground to stand on
            end

            -- score: start at the chosen distance (so a 100% pick beats a 50% pick); subtract repulsion from recent
            -- waypoints and from the character's current spot, so the roam actually moves to new ground
            local score = r
            local hit = ray.Position
            for _, past in roamMemory do
                local dx, dz = hit.X - past.x, hit.Z - past.z
                local d2 = dx * dx + dz * dz
                if d2 < radius * radius then
                    score -= (radius - math.sqrt(d2)) * 0.6
                end
            end
            local ownDx, ownDz = hit.X - cx, hit.Z - cz
            local ownD = math.sqrt(ownDx * ownDx + ownDz * ownDz)
            if ownD < radius * 0.3 then
                score -= (radius * 0.3 - ownD) * 1.5
            end

            if score > bestScore then
                bestScore = score
                best = { x = hit.X, y = hit.Y + 5, z = hit.Z }
            end
        end

        if best == nil then
            return nil
        end
        return best.x, best.y, best.z
    end

    -- the fly guard: runs on every frame while the fly's keypicker says it is on, moves the character through
    -- fly:step. Reads WASD + Space + Shift directly from UserInputService; the menu holds the key picker
    local lastFly = nil
    flyGuard = guard.new(function(now)
        local s = current
        if not (s.fly ~= nil and s.fly.enabled) then
            lastFly = nil
            return
        end
        if ui.menuOpen() or not focused() or not ui.flyHeld() then
            lastFly = nil
            return
        end
        local dt = if lastFly == nil then 1 / 60 else math.max(0, math.min(0.1, now - lastFly))
        lastFly = now

        local KC = env.Enum.KeyCode
        local function down(k) return UserInputService:IsKeyDown(k) end
        local forward = (if down(KC.W) then 1 else 0) - (if down(KC.S) then 1 else 0)
        local right = (if down(KC.D) then 1 else 0) - (if down(KC.A) then 1 else 0)
        local up = (if down(KC.Space) then 1 else 0) - (if down(KC.LeftShift) then 1 else 0)

        local cam = workspace.CurrentCamera
        if cam == nil then return end
        flyer:step(dt, forward, right, up, cam.CFrame, s.fly.speed or 60)
    end, function(message)
        warn("Calcite: the fly stopped after an error\n" .. tostring(message))
    end)

    local lastWalk = nil
    farmGuard = guard.new(function(now, haveLocal, localX, localY, localZ)
        local s = current
        local dt = if lastWalk == nil then 1 / 60 else math.max(0, math.min(0.1, now - lastWalk))
        if lastWalk == nil then
            lastTakenAt = now       -- so the dry-grow timer starts counting from the first tick, not from -inf
        end
        lastWalk = now
        if type(s.farm.speed) == "number" and s.farm.speed > 0 then
            walker.maxSpeed = s.farm.speed
        end
        walker:step(dt)
        if haveLocal then
            local target = farm:update(now, items.entries, s.farm.kinds, function(entry)
                return items:position(entry)
            end, localX, localY, localZ)

            -- reset the dry timer whenever the farm's own counter goes up: the radius returns to the setting value
            -- and the memory is cleared so the next roam does not immediately bounce off the spot we picked at
            if farm.taken ~= lastTakenCount then
                lastTakenCount = farm.taken
                lastTakenAt = now
                table.clear(roamMemory)
            end

            -- nothing in the catalogue to go for right now: the glider amb­les to a chosen point so new spawns are
            -- pulled into view. The pick goes in order:
            --   live model in Items/ (even off-category — we might stream a wanted one on the way)
            --   → user's hand-picked waypoint (yba_waypoints.lua) cycled in order
            --   → old spawn-history point (place that used to have an item, long enough ago to have respawned)
            --   → scored random point (last resort)
            -- Not run while the glider is still on the way; only when roaming is on in the mode
            if target == nil and s.farm.roam and now - lastRoam >= roam_cooldown then
                local phase = walker:phase()
                if phase ~= "going" then
                    local rx, ry, rz = pickLiveItem(localX, localY, localZ, now)
                    local source = "live"
                    if rx == nil then
                        rx, ry, rz = pickUserWaypoint(localX, localZ)
                        source = "user"
                    end
                    if rx == nil then
                        rx, ry, rz = pickHistoryPoint(localX, localY, localZ, now)
                        source = "history"
                    end
                    if rx == nil then
                        rx, ry, rz = pickRoamPoint(localX, localY, localZ, s.farm.roamRadius, now)
                        source = "random"
                    end
                    if rx ~= nil then
                        walker:goTo(rx, ry, rz)
                        noteWaypoint(rx, ry, rz, now)
                        if source == "random" then
                            remember(rx, ry, rz, now)
                        end
                        lastRoam = now
                    end
                end
            end
        else
            farm:stop()
        end
        ui.setTaken(farm.taken)
    end, function(message)
        pcall(function()
            farm:stop()
        end)
        warn("Calcite: the auto farm stopped after an error\n" .. tostring(message))
        ui.notify("Calcite", "Ошибка автофарма, он остановлен. Подробности в консоли. Чтобы включить снова, "
            .. "переключи «Включить» на вкладке AutoFarm.")
    end)

    hopGuard = guard.new(function()
        -- the jump of the game is on the space bar; a space typed into the chat is not a jump
        local held = UserInputService:IsKeyDown(env.Enum.KeyCode.Space) == true and UserInputService:GetFocusedTextBox() == nil
            and not ui.menuOpen() and focused()
        D:state("bhop.spaceDown", held, env.clock())
        hopper:update(held, env.clock())
    end, function(message)
        warn("Calcite: the bhop stopped after an error\n" .. tostring(message))
        ui.notify("Calcite", "Ошибка бхопа, он остановлен. Подробности в консоли. Чтобы включить снова, "
            .. "переключи «Включить» на вкладке «Движение».")
    end)

    -- and so does an error of the auto stop
    stopGuard = guard.new(function()
        local state = movement.state()
        local velocity = if type(state) == "table" then state.Velocity else nil
        if velocity == nil then
            return
        end

        local x, z = autostop.input(velocity.X, velocity.Z, state.OnGround)
        if x == nil then
            return
        end

        stopTold = movement.setMove(x, z)
        if not stopTold and not walkWarned then
            walkWarned = true
            warn("Calcite: there was no character of the game to walk, the auto stop does nothing")
            ui.notify("Calcite", "Автостоп: персонаж игры не найден, выстрелы не задерживаются. Зайди в матч и выбери режим ещё раз.")
        end
    end, function(message)
        warn("Calcite: the auto stop stopped after an error\n" .. tostring(message))
        ui.notify("Calcite", "Ошибка автостопа, он остановлен. Подробности в консоли. Чтобы включить снова, "
            .. "выбери режим «Автостоп» ещё раз.")
    end)

    -- who watches the user: worked out on every frame from the attributes the game gives every player, see
    -- spectators.lua; on every frame so that two changes are seen apart as often as the game sends them apart
    local watch = spectators.new()
    local watchRows = {}

    local function readWatchers()
        table.clear(watchRows)
        for _, player in Players:GetPlayers() do
            table.insert(watchRows, {
                key = player,
                name = player.Name,
                watching = player:GetAttribute("IsSpectating") == true,
                watchers = player:GetAttribute("Spectators"),
            })
        end

        watch:update(watchRows)
    end

    local lastFrame = nil

    local function frame()
        camera = workspace.CurrentCamera
        if camera == nil then
            return
        end

        local now = env.clock()
        -- the very first frame is taken for an ordinary one; a long pause is a hitch, not time to make up for
        local dt = 1 / 60
        if lastFrame ~= nil then
            dt = math.clamp(now - lastFrame, 0, 0.1)
        end
        lastFrame = now

        -- what the mode does not have is off here, whatever its switch says
        local mode = modes.resolve(settings.modeChoice, universeId)
        local s = settingsModule.inEffect(settings, mode)
        local overlayHidden = settings.interface.hideOverlay and ui.menuOpen()
        d.setVisible(not overlayHidden)
        current = s
        frameNumber += 1
        -- whether the characters are the ones the game builds by itself, and not the stock ones of the players
        local own = modes.has(mode, "OwnCharacters")

        -- no switch in the menu: asked for by setting CalciteDiagnostics = true in the table an executor shares
        -- between scripts (getgenv), when something does not work and has to be looked at
        D:set(shared.CalciteDiagnostics == true, now)

        -- the auto farm takes the items the esp of items finds
        setItems(s.items.enabled or s.farm.enabled)
        setSounds(s.sounds)
        setGrenades(s.grenades)
        setClouds(s.clouds)
        setBhop(s.bhop.enabled)
        setStop(s.aim.autoStop ~= "Off" and s.aim.autoFire)

        -- new items are settled the very frame they appear: the farm picks them up without waiting for the next
        -- slow pass. The periodic re-settle (same items may rename or move) still goes through the slow pass below
        if itemsOn and items.dirty then
            items:settle()
            lastSettle = now
            ui.setCounts(items.found, items:match(s.items.kinds))
        end

        if now - lastSlow >= slow_interval then
            lastSlow = now

            if own then
                ownCharacters:refresh()
            else
                local wantYba = status.wantsEffects(s.statusKinds) or s.stand or s.spec
                local townWeapon = s.townWeapon and s.townWeapon.enabled
                local iaWeapon = s.iaWeapon and s.iaWeapon.enabled
                for _, record in roster do
                    players.refresh(record, wantYba)
                    if townWeapon and record.character ~= nil then
                        local info = town.weaponInfo(record.character)
                        if info ~= nil then
                            local label = info.name
                            if info.reloading then
                                label = label .. " reload"
                            elseif info.ammo ~= nil and info.maxAmmo ~= nil then
                                label = string.format("%s %d/%d", label, info.ammo, info.maxAmmo)
                            end
                            record.weapon = label
                        else
                            record.weapon = ""
                        end
                    elseif iaWeapon and record.character ~= nil then
                        local info = item_asylum.weaponInfo(record.character)
                        if info ~= nil then
                            local label = info.name
                            if info.ammo ~= nil then
                                label = label .. " [" .. info.ammo .. "]"
                            end
                            if s.iaWeapon.showAbilities then
                                if info.eAbility then label = label .. " E:" .. info.eAbility end
                                if info.rAbility then label = label .. " R:" .. info.rAbility end
                            end
                            record.weapon = label
                        else
                            record.weapon = ""
                        end
                    end
                end
            end

            if itemsOn then
                if now - lastSettle >= settle_interval then
                    lastSettle = now
                    -- a safety-net rescan: the DescendantAdded listener may have missed something while the host
                    -- was busy (reparent races, modules that create a prompt and reparent in the same tick). Only
                    -- the folder of the items of YBA where there is one: the whole world of a big map is tens of
                    -- thousands of objects, a hitch every few seconds
                    items:scan(workspace:FindFirstChild("Item_Spawns") or workspace)
                    items:settle()
                end

                ui.setCounts(items.found, items:match(s.items.kinds))
            end
        end

        local viewport = camera.ViewportSize
        local screenW, screenH = viewport.X, viewport.Y

        -- where the user is; unknown while the character is not spawned
        local haveLocal, localX, localY, localZ = false, 0, 0, 0
        local character = localPlayer.Character
        local localRoot = character and character:FindFirstChild("HumanoidRootPart")
        if localRoot and localRoot:IsA("BasePart") then
            local position = localRoot.Position
            if num.plausible(position.X, position.Y, position.Z) then
                haveLocal = true
                localX, localY, localZ = position.X, position.Y, position.Z
            end
        end

        local aiming = s.aim.enabled
        if aiming and not canAim then
            aiming = false
            if not aimWarned then
                aimWarned = true
                warn("Calcite: this executor has no mousemoverel, the aim is off")
            end
        end

        local firing = s.aim.autoFire
        if firing and not canFire then
            firing = false
            if not fireWarned then
                fireWarned = true
                warn("Calcite: this executor has no mouse1press, the auto fire is off")
            end
        end

        -- the aim and the auto fire need to know where everybody is, whether they are drawn or not.
        -- Также собираем targets для Town/MVS Silent Aim и их autoFire — они стреляют FireServer напрямую,
        -- без canFire/mouse1press
        local needTargets = s.enabled or aiming or firing
            or (s.townSilent and s.townSilent.enabled)
            or (s.mvsSilent and s.mvsSilent.enabled)
            or (s.aim and s.aim.autoFire)
            or (s.chams and s.chams.enabled)
        if needTargets then
            table.clear(targets)

            if own then
                ownCharacters:targets(targets, haveLocal, localX, localY, localZ, now)
            else
                local localTeam = localPlayer.Team
                for _, record in roster do
                    local target = players.target(record, localTeam, haveLocal, localX, localY, localZ, now)
                    if target ~= nil then
                        table.insert(targets, target)
                    end
                end
            end
        end

        if s.enabled then
            esp:draw(targets, s, screenW, screenH, project, d, now)
        end

        -- Chams: Highlight-подсветка моделей чужих. Независимо от s.enabled (ESP-boxes/HP) — chams
        -- работает отдельно; свои фильтры читает из s.chams + глобальных s.teamCheck/s.hideInvincible.
        -- Если targets не собирались (needTargets false), пропускаем, иначе chammer:step cleanup'нёт
        -- все Highlight'ы кадра зря
        if chammer ~= nil and needTargets then
            if overlayHidden then chammer:cleanup() else chammer:step(targets, s) end
        end

        if D.on then
            local sameTeam, hidden = 0, 0
            for _, target in targets do
                if target.sameTeam then
                    sameTeam += 1
                end
                if target.hidden then
                    hidden += 1
                end
            end

            D:state("mode", mode, now)
            D:state("esp.on", s.enabled, now)
            D:state("teamCheck", s.teamCheck, now)
            D:state("me.team", tostring(localPlayer:GetAttribute("Team")), now)
            D:state("me.hasCharacter", haveLocal, now)
            D:number("targets", #targets)
            D:number("targets.sameTeam", sameTeam)
            D:number("targets.putAway", hidden)

            D:state("input.menuOpen", ui.menuOpen(), now)
            D:state("input.gameInFront", focused(), now)
            D:state("input.aimKey", ui.aimKeyName(), now)
            D:state("input.aimKeyDown", ui.aimHeld(), now)
            D:state("input.leftDown", UserInputService:IsMouseButtonPressed(env.Enum.UserInputType.MouseButton1), now)
            D:state("input.rightDown", UserInputService:IsMouseButtonPressed(env.Enum.UserInputType.MouseButton2), now)

            D:state("aim.on", s.aim.enabled, now)
            D:state("aim.canMoveMouse", canAim, now)
            D:state("aim.stoppedByError", aimGuard.broken, now)
            D:state("fire.on", s.aim.autoFire, now)
            D:state("fire.canPress", canFire, now)
            D:state("fire.needsKey", s.aim.autoFireNeedsKey, now)
            D:state("fire.stoppedByError", fireGuard.broken, now)
            D:state("fire.holdsButton", shooter:holding(), now)
            if not s.aim.autoFire then
                D:state("fire.look", "not cast: the auto fire is off", now)
            end

            local found = {}
            for name in packets do
                table.insert(found, (string.gsub(name, "^ReplicatedStorage%.NetworkRemotes%.", "")))
            end
            table.sort(found)
            D:state("packets", packetSearch .. ": " .. table.concat(found, ", "), now)
            D:state("grenades.on", grenadesWanted, now)
            D:number("grenades.followed", thrown:count())
            D:number("clouds", sky:count())
            D:state("preview.on", s.grenadePreview, now)
            if not s.grenadePreview then
                D:state("preview", "off", now)
            end

            D:state("movement", moveSearch .. (if movement ~= nil and movement.setJump == nil then ", no switch of the jump" else ""), now)
            D:state("bhop.on", hopWanted, now)
            D:state("bhop.steps", hopBound, now)
            D:state("bhop.stoppedByError", hopGuard.broken, now)
            D:state("stop.kind", s.aim.autoStop, now)
            D:state("stop.steps", stopBound, now)
            D:state("stop.wanted", stopWanted, now)
            D:state("stop.stoppedByError", stopGuard.broken, now)
            D:number("fences", #ownCharacters.fences)
            D:number("own models", #ownCharacters.own)
        end

        -- worked out again by the auto fire on every frame it runs
        stopWanted = false

        if aiming or firing or shooter:holding() then
            aimOwn = own

            -- the mouse is the user's while the menu is open, and another window's while the game is not in front
            local free = not ui.menuOpen() and focused()
            local held = free and ui.aimHeld()

            if aiming then
                -- Aim и Silent Aim — независимые фичи как в CS-читах: Aim двигает мышь при зажатой
                -- клавише, Silent шлёт пулю в цель отдельно (через хук/пакет). Можно включать
                -- вместе: тогда и прицел ведётся, и пуля летит; отдельно Silent без Aim.Включено —
                -- мышь стоит, пуля летит сама
                aimGuard.run(s, now, held)
            end

            if firing or shooter:holding() then
                fireGuard.run(s, firing, free, held, dt, now, modes.has(mode, "SmartFire"))
            end
        end

        if soundsWanted then
            heard:draw(haveLocal, localX, localY, localZ, screenW, screenH, project, d, now)
        end

        if cloudsWanted then
            sky:draw(now, cloudKinds, project, d)
        end

        if grenadesWanted then
            thrown:draw(serverNow(), now, haveLocal, localX, localY, localZ, project, d)
        end

        -- the wall under the crosshair: whether the bullet of the weapon in the hand gets through, and who is behind it
        if s.wallbang then
            local seen = traceShot(s, now)
            local x, y = math.floor(screenW * 0.5 + 0.5), math.floor(screenH * 0.5 + 0.5) + 26
            if seen ~= nil then
                if seen.target ~= nil and seen.walls > 0 then
                    d.textCentered(x, y, 255, 160, 60, "WALLBANG " .. tostring(seen.target.record.name)
                        .. (if seen.walls > 1 then " x" .. seen.walls else ""))
                elseif seen.target == nil and seen.firstWall == "through" then
                    d.textCentered(x, y, 120, 230, 120, "THROUGH")
                elseif seen.target == nil and seen.firstWall == "blocked" then
                    d.textCentered(x, y, 230, 90, 90, "BLOCKED")
                end
            end
        end

        if s.spectators then
            readWatchers()
            local sure, maybe = watch:of(localPlayer)
            spectators.draw(d, screenW, screenH, watch:count(localPlayer), sure, maybe)
        end

        if s.grenadePreview then
            local way, weapon = previewWay(now)
            if way ~= nil then
                local label, r, g, b = grenades.describe(weapon)
                grenades.drawWay(way, 0, r, g, b, label, haveLocal, localX, localY, localZ, project, d)
            end
        end

        -- one step of the auto farm: it moves the character, so not while there is none
        if s.farm.enabled and itemsOn then
            farmGuard.run(now, haveLocal, localX, localY, localZ)
        elseif farm.state ~= "idle" then
            farm:stop()
        end

        -- one step of the fly: the guard checks on its own whether the fly is on and the key is held
        if s.fly ~= nil and s.fly.enabled and haveLocal then
            flyGuard.run(now)
        end

        -- Fullbright: применяет Lighting-свойства каждый тик пока включено (игра может их перезаписывать);
        -- выключение восстанавливает оригинал
        if s.fullbright ~= nil then
            fullbright.step(s.fullbright.enabled == true, lighting)
        end

        -- NoClip (Town): Humanoid каждый тик возвращает CanCollide=true, поэтому цикл нужен каждый кадр;
        -- при выключении шаг восстанавливает коллизию у частей, которые мы трогали
        if s.noclip ~= nil then
            noclipper:step(s.noclip.enabled == true)
        end

        -- HUD overlays: watermark (всегда), reload bar (MVS), hotkeys панель
        if s.watermark ~= nil then
            local dt = 1 / 60
            hud.step(dt, now, not overlayHidden and s.watermark.enabled == true, not overlayHidden and s.reloadBar and s.reloadBar.enabled == true)
            if not overlayHidden and s.hotkeys and s.hotkeys.enabled then
                hud.setHotkeys(ui.hotkeys(s), true)
            else
                hud.setHotkeys(nil, false)
            end
        end

        -- Town/MVS: обновляем цель для Silent Aim и дёргаем AutoFire. Пересчитываем pickWorld только когда
        -- какая-то фича может использовать результат. Each in its own mode only: the switch of the auto fire is
        -- common to every mode, and by itself it sent the auto fire of MVS off in Town
        local townGun = modes.has(mode, "TownGun")
        local mvsGun = modes.has(mode, "MvsGun")
        if (townGun or mvsGun) and (s.townSilent.enabled or s.mvsSilent.enabled or s.aim.autoFire) then
            local picked = aimer:pickWorld(targets, s.aim, s.teamCheck)
            local targetPart, targetPlayer, targetPoint = nil, nil, nil
            if picked ~= nil and picked.target ~= nil and picked.target.record ~= nil then
                local rec = picked.target.record
                local char = rec.character
                if char ~= nil then
                    -- берём part по выбранной zone (голова → Head, грудь → UpperTorso/Torso, живот →
                    -- LowerTorso, конечности → соседний torso part). Точка picked.x/y/z — результат
                    -- hitbox multipoint, уже проверена на видимость в aim.lua. Хук town.lua отдаст
                    -- серверу эту точку как hitPos, а part как hitInstance — попадание именно в хитбокс
                    local zone = picked.zone or hitbox.Head
                    if zone == hitbox.Head then
                        targetPart = char:FindFirstChild("Head")
                    elseif zone == hitbox.Chest then
                        targetPart = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
                    elseif zone == hitbox.Stomach then
                        targetPart = char:FindFirstChild("LowerTorso") or char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
                    elseif zone == hitbox.Arms then
                        targetPart = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or char:FindFirstChild("Head")
                    elseif zone == hitbox.Legs then
                        targetPart = char:FindFirstChild("LowerTorso") or char:FindFirstChild("Torso") or char:FindFirstChild("HumanoidRootPart")
                    end
                    targetPart = targetPart or char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
                    targetPoint = { x = picked.x, y = picked.y, z = picked.z }
                end
                targetPlayer = rec.player
            end
            local pickedZone = picked ~= nil and picked.zone or nil
            town.setTarget(if townGun then targetPart else nil,
                           if townGun then targetPoint else nil,
                           if townGun then pickedZone else nil)
            mvs.setTarget(if mvsGun then targetPlayer else nil)
            if s.aim.autoFire then
                if townGun then
                    town.autoFire(s, now)
                end

                if mvsGun and mvs.autoFire(s) then
                    hud.markShot(env.clock())
                end
            end
        else
            town.setTarget(nil)
            mvs.setTarget(nil)
        end

        -- Steal an Egg: one step of the auto-steal loop; shares the glider with the auto farm so they don't run
        -- at the same time (modes are mutually exclusive via menu visibility, but guard the overlap anyway)
        if s.steal ~= nil and s.steal.enabled and haveLocal and not (s.farm ~= nil and s.farm.enabled) then
            local plotData = steal_egg_data.plots[s.steal.myPlot or 1]
            -- в Glide-режиме применяем отдельную скорость; в Walk — WalkSpeed применяется внутри stealMoveTo
            if s.steal.moveMode == "Glide" and type(s.steal.speed) == "number" and s.steal.speed > 0 then
                walker.maxSpeed = s.steal.speed
            end
            -- продвигаем waypoint-очередь stealMover: он идёт к промежуточной точке (safeZ-коридор),
            -- при прибытии переключается на следующую. steal_farm:update использует финальный target
            stealMover:arrived()
            stealer:update(now, s.steal.zones, plotData, localX, localY, localZ)
            -- hover применяется только в Glide-режиме. В Walk персонаж на ногах, hover нечем держать
            if s.steal.moveMode == "Glide" then
                local hx, hy, hz = stealer:hoverTarget()
                if hx ~= nil then
                    walker:goTo(hx, hy, hz)
                end
            end

            stealWasOn = true
        elseif stealWasOn then
            stealWasOn = false
            stealer:stop()
        end

        -- always step the glider while it has a goal: covers manual Teleport buttons (walker:goTo without farm or
        -- steal running) and lets farm/steal naturally continue. farmGuard.run already steps it when the farm is
        -- on, so this guard avoids a double step
        if haveLocal and (s.farm == nil or not s.farm.enabled) and walker:phase() == "going" then
            local dt = if lastWalk == nil then 1 / 60 else math.max(0, math.min(0.1, now - lastWalk))
            lastWalk = now
            walker:step(dt)
        end

        if itemsOn and s.items.enabled then
            -- distances are measured from the character; while it is not spawned, from the camera,
            -- so that the range keeps working and the whole map is not labelled after every death
            local refX, refY, refZ = localX, localY, localZ
            if not haveLocal then
                local eye = camera.CFrame.Position
                refX, refY, refZ = eye.X, eye.Y, eye.Z
            end

            esp_items.draw(items, s.items, screenW, screenH, project, d, refX, refY, refZ)
        end

        -- Force Crosshair: статичный прицел по центру viewport. 4 плеча (сверху/снизу/слева/справа) с
        -- отступом gap от центра + опциональная точка. Рисуется поверх всего остального в кадре.
        -- Only in the first person: the camera is in the head of the character (a camera pulled back from it is the
        -- third person, where the middle of the screen is not where the gun points)
        local firstPerson = false
        if s.crosshair ~= nil and s.crosshair.enabled then
            local character = localPlayer.Character
            local head = character and character:FindFirstChild("Head")
            if head ~= nil then
                local eye, at = camera.CFrame.Position, head.Position
                firstPerson = (eye.X - at.X) ^ 2 + (eye.Y - at.Y) ^ 2 + (eye.Z - at.Z) ^ 2 < first_person_reach ^ 2
            end
        end

        if firstPerson then
            local c = s.crosshair
            local cx = math.floor(screenW * 0.5)
            local cy = math.floor(screenH * 0.5)
            local size = c.size or 10
            local gap = c.gap or 3
            local col = c.color or { 255, 255, 255 }
            local r, g, b = col[1], col[2], col[3]
            d.line(cx - gap - size, cy, cx - gap, cy, r, g, b)
            d.line(cx + gap, cy, cx + gap + size, cy, r, g, b)
            d.line(cx, cy - gap - size, cx, cy - gap, r, g, b)
            d.line(cx, cy + gap, cx, cy + gap + size, r, g, b)
            if c.dot then
                d.dot(cx, cy, 1, r, g, b)
            end
        end

        D:flush(now, "Calcite " .. main.version .. ", " .. modes.name(mode))
    end

    frameGuard = guard.new(frame, function(message)
        warn("Calcite: the drawing stopped after an error\n" .. tostring(message))
        ui.notify("Calcite", "Ошибка отрисовки, рисование остановлено. Подробности в консоли. Чтобы включить снова, "
            .. "переключи «Включено» на вкладке «Игроки».")
    end)

    local function addPlayer(player)
        if player ~= localPlayer then
            roster[player] = players.newRecord(player)
        end
    end

    for _, player in Players:GetPlayers() do
        addPlayer(player)
    end

    table.insert(connections, Players.PlayerAdded:Connect(addPlayer))
    table.insert(connections, Players.PlayerRemoving:Connect(function(player)
        roster[player] = nil
    end))

    table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
        -- processed means the key went to the chat or to a text field
        if not processed and input.KeyCode == env.Enum.KeyCode.End then
            unload()
        end
    end))

    -- the documentation of Potassium says Connect gives nothing back; the handler checks the flag itself then
    local painting = env.DrawingImmediate.GetPaint(1):Connect(function()
        if not unloaded then
            frameGuard.run()
        end
    end)
    if painting ~= nil then
        table.insert(connections, painting)
    end

    handle = { unload = unload, version = main.version }
    shared.Calcite = handle
    return handle
end

return main
end

__modules["menu"] = function(require)
-- the window of the script, built with the Obsidian library; whatever the user sets is written into the settings
-- table at once, the frame reads it from there. Takes the library as a parameter: tests/menu_test.lua gives it a stand-in
local item_kinds = require("./item_kinds")
local modes = require("./modes")
local status = require("./status")
local steal_egg_data = require("./steal_egg_data")
local yba_npcs = require("./yba_npcs")
local i18n = require("./i18n")
local ui_localize = require("./ui_localize")
local ui_style = require("./ui_style")
local ui_preferences = require("./ui_preferences")

local menu = {}

-- the parts of a body the aim may go for, in the order of hitbox.lua, as the user reads them
local zoneLabels = { "Голова", "Грудь", "Живот", "Руки", "Ноги" }
local zoneIds = { "AimZoneHead", "AimZoneChest", "AimZoneStomach", "AimZoneArms", "AimZoneLegs" }

-- the kinds of the auto stop, as the user reads them
local stopLabels = { "Выкл", "Обычный", "Ранний" }
local stopOf = { ["Выкл"] = "Off", ["Обычный"] = "OnTarget", ["Ранний"] = "Early" }

-- who goes first among the ones in the circle, and which point of a body is taken
local orderLabels = { "Ближнего", "Слабого" }
local pointLabels = { "По списку", "Ближнюю" }

-- the list of the modes as the user reads it
local choiceLabels = { "Авто", "Universal", "YBA", "Blox Strike", "Steal an Egg", "Town", "MVS", "Item Asylum", "Rivals" }
local choiceOf = { ["Авто"] = "Auto", ["Universal"] = "Universal", ["YBA"] = "Yba", ["Blox Strike"] = "Strike", ["Steal an Egg"] = "StealEgg", ["Town"] = "Town", ["MVS"] = "Mvs", ["Item Asylum"] = "ItemAsylum", ["Rivals"] = "Rivals" }

function menu.create(deps)
    local Library = deps.Library
    local Color3 = deps.Color3
    local settings = deps.settings
    settings.interface = ui_preferences.normalize(settings.interface)
    local translator = i18n.new(settings.interface.language)
    ui_localize.attach(Library, translator)
    local itemSettings = settings.items
    local Options = Library.Options
    local Toggles = Library.Toggles

    -- the settings keep colours as { r, g, b } of 0..255, the library works with Color3
    local function toColor(rgb)
        return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
    end

    local function fromColor(color)
        return { math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255) }
    end

    -- a switch bound to a field of a settings table
    local function toggle(group, id, text, target, field)
        local element = group:AddToggle(id, { Text = text, Default = target[field] })
        element:OnChanged(function()
            target[field] = Toggles[id].Value
        end)

        return element
    end

    -- a colour picker next to a switch or a label
    local function color(element, id, title, target, field)
        element:AddColorPicker(id, { Default = toColor(target[field]), Title = title })
        Options[id]:OnChanged(function()
            target[field] = fromColor(Options[id].Value)
        end)
    end

    -- the suffix is studs unless another one is given
    local function slider(group, id, text, target, field, min, max, suffix)
        local element = group:AddSlider(id, { Text = text, Default = target[field], Min = min, Max = max, Rounding = 0, Suffix = suffix or " st" })
        Options[id]:OnChanged(function()
            target[field] = Options[id].Value
        end)

        return element
    end

    local Window = Library:CreateWindow(ui_style.configure(deps))

    -- the auto farm, the user's own character, then what is drawn, the aim, and the menu itself
    local visualsTab = Window:AddTab("Visuals", "eye", "Игроки, предметы и игровые метки")
    local aimTab = Window:AddTab("Aim", "crosshair", "Выбор цели и управление прицелом")
    local hitboxTab = Window:AddTab("Hitboxes", "scan", "Части тела и точки наведения")
    local playerTab = Window:AddTab("Player", "user", "Перемещение персонажа")
    local farmTab = Window:AddTab("AutoFarm", "bot", "Автоматический сбор предметов")
    local npcTab = Window:AddTab("NPC", "message-circle", "Диалоги и взаимодействия")
    local stealTab = Window:AddTab("Steal", "egg", "Зоны и доставка яиц")
    local teleportTab = Window:AddTab("Teleport", "map-pin", "Быстрое перемещение")
    local settingsTab = Window:AddTab("Settings", "settings", "Язык, оформление и конфигурации")

    local presentation
    local function saveInterface()
        if deps.onInterfaceChanged then deps.onInterfaceChanged(settings.interface) end
    end
    local interfaceGroup = settingsTab:AddLeftGroupbox("Интерфейс")
    interfaceGroup:AddDropdown("InterfaceLanguage", {
        Text = "Язык / Language", Values = { "Русский", "English" },
        Default = if settings.interface.language == "en" then 2 else 1,
    })
    interfaceGroup:AddLabel("Применяется сразу", true)
    local accentNames = { "Сиреневый", "Голубой", "Шалфей", "Розовый" }
    local accentIds = { "Lilac", "Blue", "Sage", "Rose" }
    interfaceGroup:AddDropdown("InterfaceAccent", {
        Text = "Акцент", Values = accentNames, Default = table.find(accentIds, settings.interface.accent) or 1,
    })
    Options.InterfaceAccent:OnChanged(function()
        settings.interface.accent = accentIds[table.find(accentNames, Options.InterfaceAccent.Value) or 1]
        if presentation then presentation:setAccent(settings.interface.accent) end
        saveInterface()
    end)
    interfaceGroup:AddDropdown("InterfaceScale", {
        Text = "Масштаб интерфейса", Values = { "80%", "90%", "100%", "110%", "120%" }, Default = tostring(settings.interface.scale) .. "%",
    })
    Options.InterfaceScale:OnChanged(function()
        settings.interface.scale = tonumber(string.match(Options.InterfaceScale.Value or "", "%d+")) or 100
        if presentation then presentation:setScale(settings.interface.scale) end
        saveInterface()
    end)
    interfaceGroup:AddLabel("Клавиша меню"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Клавиша меню" })
    toggle(interfaceGroup, "InterfaceHideOverlay", "Скрывать оверлей при открытом меню", settings.interface, "hideOverlay")
    Toggles.InterfaceHideOverlay:OnChanged(function()
        settings.interface.hideOverlay = Toggles.InterfaceHideOverlay.Value
        saveInterface()
    end)

    -- players
    local espGroup = visualsTab:AddLeftGroupbox("Игроки")

    espGroup:AddToggle("Enabled", { Text = "Включено", Default = settings.enabled })
    Toggles.Enabled:OnChanged(function()
        settings.enabled = Toggles.Enabled.Value
        if settings.enabled then
            deps.onEnabled()
        end
    end)

    color(toggle(espGroup, "Box", "Рамка", settings, "box"), "BoxColor", "Цвет рамки", settings, "boxColor")
    toggle(espGroup, "Name", "Ник", settings, "name")
    toggle(espGroup, "Distance", "Дистанция", settings, "distance")
    color(toggle(espGroup, "HealthBar", "Полоска HP", settings, "healthBar"),
        "HealthBarFullColor", "Цвет полного HP", settings, "healthBarFullColor")
    color(espGroup:AddLabel("Цвет пустого HP"),
        "HealthBarEmptyColor", "Цвет пустого HP", settings, "healthBarEmptyColor")
    toggle(espGroup, "Protection", "Неуязвимость", settings, "protection")
    toggle(espGroup, "HideInvincible", "Не отображать неуязвимых", settings, "hideInvincible")
    local teamCheck = toggle(espGroup, "TeamCheck", "Проверка команды", settings, "teamCheck")
    color(espGroup:AddLabel("Цвет текста"), "TextColor", "Цвет текста", settings, "textColor")
    slider(espGroup, "MaxDistance", "Дальность", settings, "maxDistance", 50, 5000)

    -- Chams: Highlight-подсветка моделей чужих. Фильтры «Проверка команды» и «Не отображать неуязвимых»
    -- берутся те же, что у ESP (chams.lua смотрит в s.teamCheck и s.hideInvincible)
    local chamsGroup = visualsTab:AddLeftGroupbox("Chams")
    color(toggle(chamsGroup, "ChamsEnabled", "Включено", settings.chams, "enabled"),
        "ChamsFill", "Цвет заливки", settings.chams, "fillColor")
    slider(chamsGroup, "ChamsFillT", "Прозрачность заливки", settings.chams, "fillTransparency", 0, 100, "%")
    color(chamsGroup:AddLabel("Цвет контура"), "ChamsOutline", "Цвет контура", settings.chams, "outlineColor")
    slider(chamsGroup, "ChamsOutlineT", "Прозрачность контура", settings.chams, "outlineTransparency", 0, 100, "%")
    toggle(chamsGroup, "ChamsWalls", "Сквозь стены", settings.chams, "throughWalls")
    chamsGroup:AddLabel("Нативный Highlight API Roblox: красит модель через Fill/Outline, при респавне " ..
        "сам освобождается. Сквозь стены = DepthMode.AlwaysOnTop, иначе Occluded (только видимое).", true)

    local ybaGroup = visualsTab:AddRightGroupbox("YBA")
    -- which states of a player are shown, several at once, as the kinds of items are
    local statusLabels, statusDefault, statusOf = {}, {}, {}
    for _, kind in status.kinds do
        table.insert(statusLabels, kind.label)
        statusOf[kind.label] = kind.id
        if settings.statusKinds[kind.id] then
            table.insert(statusDefault, kind.label)
        end
    end
    ybaGroup:AddDropdown("StatusKinds", { Text = "Статусы", Values = statusLabels, Default = statusDefault, Multi = true })
    Options.StatusKinds:OnChanged(function()
        local chosen = Options.StatusKinds.Value or {}
        for label, id in statusOf do
            settings.statusKinds[id] = chosen[label] == true
        end
    end)
    toggle(ybaGroup, "Stand", "Стенд", settings, "stand")
    toggle(ybaGroup, "Spec", "Спек", settings, "spec")

    local strikeGroup = visualsTab:AddRightGroupbox("Blox Strike")
    toggle(strikeGroup, "Ping", "Пинг", settings, "ping")
    toggle(strikeGroup, "Weapon", "Оружие в руках", settings, "weapon")
    toggle(strikeGroup, "LastSeen", "Спрятанные: последнее место", settings, "lastSeen")
    toggle(strikeGroup, "Sounds", "Звуки: шаги тех, кого не видно", settings, "sounds")
    toggle(strikeGroup, "Grenades", "Гранаты: путь и место падения", settings, "grenades")
    toggle(strikeGroup, "GrenadePreview", "Гранаты: куда полетит своя", settings, "grenadePreview")
    toggle(strikeGroup, "Clouds", "Дым и огонь: радиус и время", settings, "clouds")
    toggle(strikeGroup, "Spectators", "Кто за мной наблюдает", settings, "spectators")
    toggle(strikeGroup, "Wallbang", "Прострел стены у прицела", settings, "wallbang")

    -- Town ESP: имя оружия + ammo + reload над чужими. Данные читаются из town.weaponInfo (town.lua)
    local townEspGroup = visualsTab:AddRightGroupbox("Town")
    toggle(townEspGroup, "TownWeapon", "ESP оружия", settings.townWeapon, "enabled")
    townEspGroup:AddLabel("Показывает Tool в руках чужих + патроны + reload. " ..
        "Данные читаются из Tool.GunScript.ClientAmmo и Tool.Settings, без хуков.", true)

    -- Item Asylum ESP: имя тулзы + патроны (ToolIconText) + E/R абилки
    local iaEspGroup = visualsTab:AddRightGroupbox("Item Asylum")
    toggle(iaEspGroup, "IaWeapon", "ESP предметов", settings.iaWeapon, "enabled")
    toggle(iaEspGroup, "IaWeaponAbilities", "Абилки E/R", settings.iaWeapon, "showAbilities")
    iaEspGroup:AddLabel("Показывает Tool в руках чужих. ToolIconText = патроны/счётчик. " ..
        "Абилки берутся из атрибутов EABILITY/RABILITY тулзы.", true)

    -- items
    local itemsGroup = visualsTab:AddLeftGroupbox("Предметы")
    color(toggle(itemsGroup, "ItemsEnabled", "Включено", itemSettings, "enabled"), "ItemsColor", "Цвет меток", itemSettings, "color")
    slider(itemsGroup, "ItemsMaxDistance", "Дальность", itemSettings, "maxDistance", 50, 2000)
    -- which kinds are shown, several at once; each kind has a color of its own, the rest takes the one picked above
    local kindLabels, kindDefault, kindOf = {}, {}, {}
    for _, kind in item_kinds.list do
        table.insert(kindLabels, kind.label)
        kindOf[kind.label] = kind.id
        if itemSettings.kinds[kind.id] then
            table.insert(kindDefault, kind.label)
        end
    end
    itemsGroup:AddDropdown("ItemKinds", { Text = "Отображать", Values = kindLabels, Default = kindDefault, Multi = true })
    Options.ItemKinds:OnChanged(function()
        local chosen = Options.ItemKinds.Value or {}
        for label, id in kindOf do
            itemSettings.kinds[id] = chosen[label] == true
        end
    end)
    itemsGroup:AddLabel("«Не из каталога» — магазины, квесты и предметы, которых нет в каталоге игры.", true)
    local counts = itemsGroup:AddLabel("Предметов: 0, показано: 0")

    -- the auto farm
    local farmGroup = farmTab:AddLeftGroupbox("Предметы")
    farmGroup:AddToggle("FarmEnabled", { Text = "Включить", Default = settings.farm.enabled })
    Toggles.FarmEnabled:OnChanged(function()
        settings.farm.enabled = Toggles.FarmEnabled.Value
        -- switching it on is how the user asks for another try after an error stopped it
        if settings.farm.enabled and deps.onFarmEnabled ~= nil then
            deps.onFarmEnabled()
        end
    end)
    local farmLabels, farmDefault, farmOf = {}, {}, {}
    for _, kind in item_kinds.list do
        if kind.id ~= "unknown" then
            table.insert(farmLabels, kind.label)
            farmOf[kind.label] = kind.id
            if settings.farm.kinds[kind.id] then
                table.insert(farmDefault, kind.label)
            end
        end
    end
    farmGroup:AddDropdown("FarmKinds", { Text = "Собирать", Values = farmLabels, Default = farmDefault, Multi = true })
    Options.FarmKinds:OnChanged(function()
        local chosen = Options.FarmKinds.Value or {}
        for label, id in farmOf do
            settings.farm.kinds[id] = chosen[label] == true
        end
    end)
    toggle(farmGroup, "FarmRoam", "Ходить, пока нет цели", settings.farm, "roam")
    slider(farmGroup, "FarmSpeed", "Скорость глайдера", settings.farm, "speed", 300, 5000, " ст/с")
    farmGroup:AddLabel("Персонаж идёт глайдером к ближайшему предмету и держит E, как игрок. Пока в поле зрения "
        .. "нет цели — с «Ходить» глайдер амблит по кругу в пределах ~350 студов, чтобы в поле зрения приходили "
        .. "новые спавны. 1800 ст/с — как у Slowc2960; выше можно, но может дёргать камеру игры.", true)
    local farmCount = farmGroup:AddLabel("Подобрано: 0")

    -- aim
    local aimGroup = aimTab:AddLeftGroupbox("Наведение")
    -- the keypicker is attached to the toggle so a right-click on "Включено" opens its binding and mode (Always,
    -- Hold or Toggle). By default the aim works while the right button is held, as it did before the picker had
    -- modes; "Always" (no key at all) is for the user to pick through the right-click
    aimGroup:AddToggle("AimEnabled", { Text = "Включено", Default = settings.aim.enabled }):AddKeyPicker("AimKey", {
        Default = "MB2",
        Mode = "Hold",
        Modes = { "Always", "Hold", "Toggle" },
        NoUI = true,
        Text = "Аим",
    })
    Toggles.AimEnabled:OnChanged(function()
        settings.aim.enabled = Toggles.AimEnabled.Value
        -- switching the aim on is how the user asks for another try after an error stopped it
        if settings.aim.enabled and deps.onAimEnabled ~= nil then
            deps.onAimEnabled()
        end
    end)

    -- the silent aim of the game, next to the aim whose choice of target it takes: a switch for every game, the one
    -- of the mode in effect is shown (ui.applyMode). The ids are the ones the switches had before, so configs keep them
    local silentToggles = {
        ShotHook = toggle(aimGroup, "SilentAim", "Silent Aim", settings.silentaim, "enabled"),
        TownGun = toggle(aimGroup, "TownSilent", "Silent Aim", settings.townSilent, "enabled"),
        MvsGun = toggle(aimGroup, "MvsSilent", "Silent Aim", settings.mvsSilent, "enabled"),
    }
    -- Town: тумблер «игнорировать блокировки клиента» — rage стреляет даже в спринте/прыжке/осмотре.
    -- Виден только в режиме Town, живёт рядом с Silent Aim MVS Rage
    local townIgnoreLimitsToggle = toggle(aimGroup, "TownIgnoreLimits", "Игнорировать блокировки (Town)", settings.townSilent, "ignoreLimits")
    local silentNotes = {
        ShotHook = aimGroup:AddLabel("Silent Aim: при выстреле пуля уходит в цель аима. Берутся круг, дальность, "
            .. "«Только видимые» и «Проверка команды». Без оружия в руках или без цели в круге выстрел обычный. "
            .. "Наводка мышью работает вместе с ним; чтобы мышь не двигалась, выключи «Включено».", true),
        TownGun = aimGroup:AddLabel("Silent Aim: клик ЛКМ отправляет выстрел в цель аима. Берутся круг, дальность, "
            .. "видимость и команда. Наводка мышью работает вместе с ним; чтобы мышь не двигалась, выключи «Включено».", true),
        MvsGun = aimGroup:AddLabel("Silent Aim: клик ЛКМ отправляет выстрел по цели аима, цель ищется на всём экране "
            .. "и только среди видимых. Работает с пистолетом, нож пока не поддержан. Rage Aim = включи «Аим» "
            .. "+ «Silent Aim» + «Автовыстрел», тогда само ищет цель и стреляет по кулдауну револьвера.", true),
    }
    slider(aimGroup, "AimRadius", "Круг", settings.aim, "radius", 20, 600, " px")
    toggle(aimGroup, "AimFullScreen", "Полный экран", settings.aim, "fullScreen")
    slider(aimGroup, "AimSpeed", "Скорость", settings.aim, "speed", 1, 40, "")
    slider(aimGroup, "AimMaxDistance", "Дальность", settings.aim, "maxDistance", 50, 2000)
    toggle(aimGroup, "AimShowFov", "Показывать круг", settings.aim, "showFov")
    toggle(aimGroup, "AimShowPoint", "Точка наведения", settings.aim, "showPoint")

    local aimRules = aimTab:AddRightGroupbox("Цели")
    aimRules:AddDropdown("AimOrder", {
        Text = "Сначала",
        Values = orderLabels,
        Default = if settings.aim.weakestFirst then 2 else 1,
    })
    Options.AimOrder:OnChanged(function()
        settings.aim.weakestFirst = Options.AimOrder.Value == orderLabels[2]
    end)
    local visibleOnlyToggle = toggle(aimRules, "AimVisibleOnly", "Только видимые", settings.aim, "visibleOnly")
    toggle(aimRules, "AimSkipProtected", "Не трогать неуязвимых", settings.aim, "skipProtected")
    aimRules:AddLabel("Своих пропускает «Проверка команды» на вкладке «Игроки».", true)

    local fireGroup = aimTab:AddRightGroupbox("Автовыстрел")
    fireGroup:AddToggle("AutoFire", { Text = "Включить", Default = settings.aim.autoFire })
    Toggles.AutoFire:OnChanged(function()
        settings.aim.autoFire = Toggles.AutoFire.Value
        -- as with the aim: switching it on is how the user asks for another try after an error stopped it
        if settings.aim.autoFire and deps.onFireEnabled ~= nil then
            deps.onFireEnabled()
        end
    end)
    toggle(fireGroup, "AutoFireNeedsKey", "Только с клавишей аима", settings.aim, "autoFireNeedsKey")
    local throughWalls = toggle(fireGroup, "AutoFireThroughWalls", "Сквозь простреливаемые стены", settings.aim, "autoFireThroughWalls")
    -- stopping before a shot: the normal one when the crosshair is on somebody, the early one as soon as somebody to
    -- shoot at is in the circle of the aim
    local autoStop = fireGroup:AddDropdown("AutoStop", {
        Text = "Автостоп",
        Values = stopLabels,
        Default = table.find({ "Off", "OnTarget", "Early" }, settings.aim.autoStop) or 1,
    })
    Options.AutoStop:OnChanged(function()
        settings.aim.autoStop = stopOf[Options.AutoStop.Value] or "Off"
        -- picking a kind is how the user asks for another try: after an error, or once a match has begun
        if settings.aim.autoStop ~= "Off" and deps.onAutoStopPicked ~= nil then
            deps.onAutoStopPicked()
        end
    end)
    local stopNote = fireGroup:AddLabel("Автостоп: выстрел ждёт, пока ты почти не остановишься, а скрипт сам "
        .. "идёт против хода. «Обычный» — когда прицел на противнике, «Ранний» — как только противник в круге аима.", true)
    -- where the weapon in the hands is known, its own rate of fire is the interval
    local interval = slider(fireGroup, "FireInterval", "Интервал", settings.aim, "fireInterval", 60, 1000, " мс")
    local hitChance = slider(fireGroup, "HitChance", "Шанс попадания", settings.aim, "hitChance", 0, 100, "%")
    local smartNote = fireGroup:AddLabel("Темп — как у оружия в руках: автомат зажимается очередью, пистолет и снайперка "
        .. "кликаются к готовности выстрела; нож и гранаты не трогаются. «Шанс попадания» — сколько процентов конуса "
        .. "разброса игры должно попасть в выбранные части тела (0 — не проверять).", true)
    fireGroup:AddLabel("Кликает ЛКМ сам, пока прицел стоит на выбранной части тела противника. Работает и без "
        .. "включённого наведения.", true)

    -- NoSpread rides on a hook on Blox Strike's _performRaycast, see nospread.lua, together with the silent aim of
    -- that game (whose switch is in the group of the aim)
    local weaponGroup = aimTab:AddRightGroupbox("Оружие")
    toggle(weaponGroup, "NoSpread", "Без разброса", settings.nospread, "enabled")
    weaponGroup:AddLabel("Blox Strike. Угол отклонения луча зануляется, каждая пуля летит точно в центр экрана. " ..
        "Разброс визуально у прицела продолжает плыть как у игры, но попадание идёт точно в прицел.", true)

    -- hitboxes: which point of a body the aim goes for, and the auto fire shoots at
    local zonesGroup = hitboxTab:AddLeftGroupbox("Части тела")
    local zonesWarning = zonesGroup:AddLabel("Ничего не выбрано: аим ни на кого не наведётся.", true)

    local function showZonesWarning()
        local any = false
        for zone = 1, #zoneIds do
            any = any or settings.aim.zones[zone] == true
        end

        zonesWarning:SetVisible(not any)
    end

    for zone, id in zoneIds do
        zonesGroup:AddToggle(id, { Text = zoneLabels[zone], Default = settings.aim.zones[zone] == true })
        Toggles[id]:OnChanged(function()
            settings.aim.zones[zone] = Toggles[id].Value == true
            showZonesWarning()
        end)
    end
    showZonesWarning()

    local pointGroup = hitboxTab:AddRightGroupbox("Выбор точки")
    pointGroup:AddDropdown("AimPointChoice", {
        Text = "Какую брать",
        Values = pointLabels,
        Default = if settings.aim.nearestPoint then 2 else 1,
    })
    Options.AimPointChoice:OnChanged(function()
        settings.aim.nearestPoint = Options.AimPointChoice.Value == pointLabels[2]
    end)
    pointGroup:AddLabel("«По списку»: части тела идут сверху вниз, берётся первая, в которую можно попасть. "
        .. "«Ближнюю»: точка, до которой ближе всего вести прицел.", true)

    local multiGroup = hitboxTab:AddRightGroupbox("Мультипоинты")
    toggle(multiGroup, "AimMultipoint", "Включить", settings.aim, "multipoint")
    -- the settings keep the share of the way to the edge, the user reads percent
    multiGroup:AddSlider("AimPointInset", {
        Text = "До края",
        Default = math.round(settings.aim.pointInset * 100),
        Min = 30,
        Max = 95,
        Rounding = 0,
        Suffix = " %",
    })
    Options.AimPointInset:OnChanged(function()
        settings.aim.pointInset = Options.AimPointInset.Value / 100
    end)
    multiGroup:AddLabel("Кроме центра части тела пробуются точки ближе к её краям: цель, которая высунулась из-за "
        .. "угла, не считается скрытой. Заметнее всего с «Только видимые».", true)

    -- Steal an Egg: multi-select список зон (все включены по умолчанию) + выбор Plot'а для доставки яйца
    local stealGroup = stealTab:AddLeftGroupbox("Авто-кража")
    stealGroup:AddToggle("StealEnabled", { Text = "Включить", Default = settings.steal.enabled })
    Toggles.StealEnabled:OnChanged(function()
        settings.steal.enabled = Toggles.StealEnabled.Value
    end)

    -- defaults: все зоны выбраны при первом запуске
    local zoneLabels = {}
    local zoneDefault = {}
    for _, a in steal_egg_data.areas do
        table.insert(zoneLabels, a.name)
        if settings.steal.zones[a.name] == nil then
            settings.steal.zones[a.name] = true
        end
        if settings.steal.zones[a.name] then
            table.insert(zoneDefault, a.name)
        end
    end
    stealGroup:AddDropdown("StealZones", { Text = "Зоны", Values = zoneLabels, Default = zoneDefault, Multi = true })
    Options.StealZones:OnChanged(function()
        local chosen = Options.StealZones.Value or {}
        for _, name in zoneLabels do
            settings.steal.zones[name] = chosen[name] == true
        end
    end)

    local plotLabels = {}
    for _, pl in steal_egg_data.plots do
        table.insert(plotLabels, pl.name)
    end
    toggle(stealGroup, "StealAutoPlot", "Автоопределять базу", settings.steal, "autoPlot")
    stealGroup:AddDropdown("StealPlot", {
        Text = "Моя база (ручной)",
        Values = plotLabels,
        Default = settings.steal.myPlot or 1,
    })
    Options.StealPlot:OnChanged(function()
        local idx = table.find(plotLabels, Options.StealPlot.Value)
        if idx then settings.steal.myPlot = idx end
    end)
    stealGroup:AddDropdown("StealMoveMode", {
        Text = "Режим перемещения",
        Values = { "TP", "Walk", "Glide" },
        Default = settings.steal.moveMode or "TP",
    })
    Options.StealMoveMode:OnChanged(function()
        settings.steal.moveMode = Options.StealMoveMode.Value
    end)
    slider(stealGroup, "StealTpUpHeight", "TP Up высота", settings.steal, "tpUpHeight", 10, 80, " ст")
    slider(stealGroup, "StealTpUpDelay", "TP Up задержка", settings.steal, "tpUpDelay", 50, 500, " мс")
    slider(stealGroup, "StealTpDelay", "TP задержка", settings.steal, "tpDelay", 50, 500, " мс")
    slider(stealGroup, "StealTpDownDelay", "TP Down задержка", settings.steal, "tpDownDelay", 50, 500, " мс")
    slider(stealGroup, "StealDropDelay", "Drop задержка", settings.steal, "dropDelay", 0, 300, " мс")
    slider(stealGroup, "StealWalkSpeed", "WalkSpeed (Walk mode)", settings.steal, "walkSpeed", 20, 200, "")
    slider(stealGroup, "StealSpeed", "Скорость глайдера (Glide mode)", settings.steal, "speed", 150, 2000, " ст/с")
    toggle(stealGroup, "StealDetour", "Z-detour (обход guard-зон)", settings.steal, "detour")
    slider(stealGroup, "StealSafeZ", "Z коридора обхода", settings.steal, "safeZ", -500, 500, " ст")
    stealGroup:AddLabel("Z-detour: все 13 guard-зон в полосе Z=[-440..-290]. Прямой путь через центры " ..
        "будит стражей — догонят. Обход выходит на safeZ (вне полосы), едет по X, заходит в целевую " ..
        "зону одним прыжком. Пересекает только 1 guard-зону вместо 13.", true)
    stealGroup:AddLabel("TP — 3 фазы (прыжок вверх → горизонт → вниз) с паузами, как в Pulse Hub. " ..
        "Пачки коротких CFrame-шагов с задержками обходят античит, который палит один длинный шаг. " ..
        "Walk — модифицирует Humanoid.WalkSpeed и шлёт настоящие шаги (безопасно, но игра может клампить скорость). " ..
        "Glide — прямой CFrame (быстро, палится). " ..
        "В любом режиме — settle 0.8-1.4 с перед нажатием E, пауза 2.5-5 с между циклами.", true)

    -- Teleport: 2 группы — зоны и базы. Клик = глайдер к точке. Работает в любом режиме пока walker жив
    local teleAreasGroup = teleportTab:AddLeftGroupbox("Зоны")
    for _, a in steal_egg_data.areas do
        local area = a
        teleAreasGroup:AddButton({
            Text = area.name,
            Func = function()
                if deps.onTeleport ~= nil then deps.onTeleport(area.x, area.y, area.z) end
            end,
        })
    end
    local telePlotsGroup = teleportTab:AddRightGroupbox("Базы")
    for _, p in steal_egg_data.plots do
        local plot = p
        telePlotsGroup:AddButton({
            Text = plot.name,
            Func = function()
                if deps.onTeleport ~= nil then deps.onTeleport(plot.x, plot.y, plot.z) end
            end,
        })
    end
    telePlotsGroup:AddLabel("Глайдер летит в точку. Работает со скоростью glider из AutoFarm.", true)

    -- NPC dialogues (YBA): one button per NPC, fires its ProximityPrompt without teleport (fireproximityprompt
    -- works from any distance). Layout: 7 groups split across 2 columns so no column grows too tall. See
    -- yba_npcs.lua for the catalogue
    local npcGroups = {}        -- for SetVisible from the mode filter
    local leftColumnTitles = { ["Сюжет"] = true, ["Тренеры"] = true, ["Fast Travel"] = true }
    for _, group in yba_npcs do
        local box
        if leftColumnTitles[group.title] then
            box = npcTab:AddLeftGroupbox(group.title)
        else
            box = npcTab:AddRightGroupbox(group.title)
        end
        table.insert(npcGroups, box)
        for _, item in group.items do
            local dialogue = item.dialogue
            local modelName = item.modelName
            box:AddButton({
                Text = item.label,
                Func = function()
                    if deps.onCallNpc ~= nil then
                        deps.onCallNpc(dialogue, modelName)
                    end
                end,
            })
        end
    end

    -- movement
    local bhopGroup = playerTab:AddLeftGroupbox("Бхоп")
    bhopGroup:AddToggle("BhopEnabled", { Text = "Включить", Default = settings.bhop.enabled })
    Toggles.BhopEnabled:OnChanged(function()
        settings.bhop.enabled = Toggles.BhopEnabled.Value
        -- switching it on is how the user asks for another try: after an error, or once a match has begun
        if settings.bhop.enabled and deps.onBhopEnabled ~= nil then
            deps.onBhopEnabled()
        end
    end)
    -- no key to set: the jump of the game is on the space bar, and that is the key the script watches
    bhopGroup:AddLabel("Держи пробел: скрипт отпускает прыжок в воздухе и нажимает его заново в тот тик, "
        .. "когда ты касаешься земли. Скорость набирается стрейфами, как обычно.", true)

    -- fly for YBA: right-click the toggle to bind a key (Always / Hold / Toggle). On the left column too so the
    -- tab is not visually lopsided when the mode only has Fly (YBA) or only has Bhop (Strike) — the two features
    -- are mutually exclusive by mode, so they never fight for the slot
    local flyGroup = playerTab:AddLeftGroupbox("Полёт")
    flyGroup:AddToggle("FlyEnabled", { Text = "Включено", Default = settings.fly.enabled }):AddKeyPicker("FlyKey", {
        Default = "F",
        Mode = "Toggle",
        Modes = { "Always", "Hold", "Toggle" },
        NoUI = true,
        Text = "Полёт",
    })
    Toggles.FlyEnabled:OnChanged(function()
        settings.fly.enabled = Toggles.FlyEnabled.Value
    end)
    slider(flyGroup, "FlySpeed", "Скорость", settings.fly, "speed", 10, 1500, " ст/с")
    flyGroup:AddLabel("WASD + Пробел (вверх) + ЛевыйShift (вниз). Направление по камере. Та же техника что и у " ..
        "глайдера автофарма: прямая установка CFrame каждый кадр. ПКМ по «Включено» — назначить клавишу и режим " ..
        "(всегда/удерживать/переключать).", true)

    -- NoClip: CanCollide=false на всех BaseParts персонажа каждый кадр (noclip.lua). Town-only
    local noclipGroup = playerTab:AddRightGroupbox("NoClip")
    toggle(noclipGroup, "NoClipEnabled", "Включено", settings.noclip, "enabled")
    noclipGroup:AddLabel("Проходишь сквозь стены — убирает коллизию у всех частей твоего персонажа каждый " ..
        "кадр. Чтобы пройти в чужую базу — просто иди вперёд. При выключении коллизия возвращается.", true)

    -- Fullbright: убирает ночь/туман/тени через Lighting (Town). Переехал в Visuals из Player
    local fullbrightGroup = visualsTab:AddRightGroupbox("Свет")
    toggle(fullbrightGroup, "FullbrightEnabled", "Fullbright", settings.fullbright, "enabled")
    fullbrightGroup:AddLabel("Ставит ClockTime=14 (день). Больше ничего не трогает. При выключении " ..
        "возвращает старое время. Применяется каждый тик — переживёт сервер, который крутит день/ночь.", true)

    -- Force Crosshair: статичный прицел по центру viewport. Town-only
    local crosshairGroup = visualsTab:AddRightGroupbox("Прицел")
    color(toggle(crosshairGroup, "CrosshairEnabled", "Включено", settings.crosshair, "enabled"),
        "CrosshairColor", "Цвет", settings.crosshair, "color")
    slider(crosshairGroup, "CrosshairSize", "Длина плеча", settings.crosshair, "size", 2, 30, " px")
    slider(crosshairGroup, "CrosshairGap", "Отступ от центра", settings.crosshair, "gap", 0, 15, " px")
    toggle(crosshairGroup, "CrosshairDot", "Точка в центре", settings.crosshair, "dot")
    crosshairGroup:AddLabel("Рисует крестик по центру экрана каждый кадр. Длина плеча = длина каждой из " ..
        "четырёх линий; отступ от центра — на сколько пикселей внутренний конец линии отступает от точки. " ..
        "Только от первого лица: при отдалённой камере крестик не рисуется.", true)

    -- HUD overlays: watermark и reload bar
    local hudGroup = settingsTab:AddLeftGroupbox("HUD")
    toggle(hudGroup, "Watermark", "Ватермарка (FPS/ping)", settings.watermark, "enabled")
    local reloadBarToggle = toggle(hudGroup, "ReloadBar", "Индикатор перезарядки (MVS)", settings.reloadBar, "enabled")
    toggle(hudGroup, "Hotkeys", "Hotkeys HUD", settings.hotkeys, "enabled")
    local hitLogsToggle = toggle(hudGroup, "HitLogs", "Hit logs (Town)", settings.hitLogs, "enabled")
    hudGroup:AddLabel("Ватермарка — в правом верхнем углу, стиль меню. Индикатор перезарядки — " ..
        "полоска внизу экрана, появляется после выстрела в MVS (2.5с кулдаун револьвера). " ..
        "Hit logs — уведомление «Hit [ник] in [часть] for [X] hp» после каждого autoFire-выстрела в Town.", true)


    -- settings
    local menuGroup = settingsTab:AddLeftGroupbox("Меню")
    menuGroup:AddDropdown("ModeChoice", {
        Text = "Режим",
        Values = choiceLabels,
        Default = table.find(modes.choices, settings.modeChoice) or 1,
    })
    menuGroup:AddLabel("Выгрузка: клавиша End или кнопка ниже")
    menuGroup:AddButton({ Text = "Выгрузить", Func = deps.onUnload, DoubleClick = true })

    Library.ToggleKeybind = Options.MenuKeybind

    local ui = {}
    local shownCounts = nil

    -- hides what the mode in effect does not have and says which mode that is
    function ui.applyMode()
        local mode = modes.resolve(settings.modeChoice, deps.universeId)

        ybaGroup:SetVisible(modes.has(mode, "Statuses") or modes.has(mode, "Kit"))
        strikeGroup:SetVisible(modes.has(mode, "Ping") or modes.has(mode, "Weapon") or modes.has(mode, "LastSeen")
            or modes.has(mode, "Sounds") or modes.has(mode, "Grenades"))
        itemsGroup:SetVisible(modes.has(mode, "Items"))
        aimTab:SetVisible(modes.has(mode, "Aim"))
        hitboxTab:SetVisible(modes.has(mode, "Aim"))
        playerTab:SetVisible(modes.has(mode, "Bhop") or modes.has(mode, "Fly") or modes.has(mode, "NoClip"))
        bhopGroup:SetVisible(modes.has(mode, "Bhop"))
        flyGroup:SetVisible(modes.has(mode, "Fly"))
        noclipGroup:SetVisible(modes.has(mode, "NoClip"))
        -- Visuals-only группы: Fullbright и Crosshair теперь в visualsTab, видимы только в своих режимах
        fullbrightGroup:SetVisible(modes.has(mode, "Fullbright"))
        crosshairGroup:SetVisible(modes.has(mode, "Crosshair"))
        weaponGroup:SetVisible(modes.has(mode, "ShotHook"))
        for feature, element in silentToggles do
            element:SetVisible(modes.has(mode, feature))
            silentNotes[feature]:SetVisible(modes.has(mode, feature))
        end
        pcall(function() townIgnoreLimitsToggle:SetVisible(modes.has(mode, "TownGun")) end)
        townEspGroup:SetVisible(modes.has(mode, "TownGun"))
        iaEspGroup:SetVisible(modes.has(mode, "IaWeapon"))
        -- в MVS visibleOnly форсится в settings.inEffect, тоггл прячем
        pcall(function() visibleOnlyToggle:SetVisible(mode ~= "Mvs") end)
        -- Reload bar работает только в MVS (gated через MvsGun), прячем toggle в других режимах
        pcall(function() reloadBarToggle:SetVisible(modes.has(mode, "MvsGun")) end)
        -- Hit logs — только в Town (там autoFire шлёт FireEvent сам и мы знаем кому попали)
        pcall(function() hitLogsToggle:SetVisible(modes.has(mode, "TownGun")) end)
        npcTab:SetVisible(modes.has(mode, "Npc"))
        stealTab:SetVisible(modes.has(mode, "Steal"))
        teleportTab:SetVisible(modes.has(mode, "Teleport"))
        farmTab:SetVisible(modes.has(mode, "AutoFarm"))
        teamCheck:SetVisible(modes.has(mode, "TeamCheck"))
        throughWalls:SetVisible(modes.has(mode, "Wallbang"))
        autoStop:SetVisible(modes.has(mode, "AutoStop"))
        interval:SetVisible(not modes.has(mode, "SmartFire"))
        hitChance:SetVisible(modes.has(mode, "SmartFire"))
        smartNote:SetVisible(modes.has(mode, "SmartFire"))
        stopNote:SetVisible(modes.has(mode, "AutoStop"))
        -- the version stands next to the mode: an executor keeps the text of a script it has open, and a copy that
        -- was not loaded again after an update is told by it at a glance
        local footer = modes.name(mode) .. (if settings.modeChoice == "Auto" then " (авто)" else "")
        if deps.version ~= nil then
            footer = footer .. " | v" .. deps.version
        end

        Window:SetFooter(translator:text(footer))
    end

    Options.ModeChoice:OnChanged(function()
        settings.modeChoice = choiceOf[Options.ModeChoice.Value] or "Auto"
        ui.applyMode()
    end)

    Options.InterfaceLanguage:OnChanged(function()
        settings.interface.language = if Options.InterfaceLanguage.Value == "English" then "en" else "ru"
        translator:set(settings.interface.language)
        ui.applyMode()
        saveInterface()
    end)

    -- how many items the auto farm has taken
    local shownTaken = nil
    function ui.setTaken(count)
        if count ~= shownTaken then
            shownTaken = count
            farmCount:SetText(string.format("Подобрано: %d", count))
        end
    end

    -- how many items of the catalogue the world has, and how many labels are shown
    function ui.setCounts(found, shown)
        local text = string.format("Предметов: %d, показано: %d", found, shown)
        if text ~= shownCounts then
            shownCounts = text
            counts:SetText(text)
        end
    end

    -- whether the key of the aim is down (or, when the user made it a switch, on).
    -- Клавиша None = «мышь не двигать вообще» (пользователь явно не назначил клавишу — aim-assist off,
    -- но Silent Aim/автовыстрел продолжают работать, они на этот тумблер не смотрят)
    function ui.aimHeld()
        local okKey, keyValue = pcall(function() return Options.AimKey.Value end)
        if okKey and (keyValue == nil or keyValue == "None" or tostring(keyValue) == "None") then
            return false
        end
        local ok, state = pcall(function()
            return Options.AimKey:GetState()
        end)
        return ok and state == true
    end

    -- whether the fly key is down (same KeyPicker modes as the aim's)
    function ui.flyHeld()
        local ok, state = pcall(function()
            return Options.FlyKey:GetState()
        end)
        return ok and state == true
    end

    -- which key the aim is on and how it is used, in words: for the diagnostics
    function ui.aimKeyName()
        return tostring(Options.AimKey.Value) .. " (" .. tostring(Options.AimKey.Mode) .. ")"
    end

    -- активные биндинги для HUD. Возвращает список { id, name, key, active } только для включённых фич
    function ui.hotkeys(settings)
        local out = {}
        local function keyOf(opt)
            local ok, v = pcall(function() return tostring(opt.Value) end)
            return ok and v or "?"
        end
        if settings.aim.enabled then
            table.insert(out, { id = "aim", name = translator:text("Aim"), key = keyOf(Options.AimKey), active = ui.aimHeld() })
        end
        if settings.fly and settings.fly.enabled then
            table.insert(out, { id = "fly", name = translator:text("Полёт"), key = keyOf(Options.FlyKey), active = ui.flyHeld() })
        end
        if settings.aim.autoFire then
            local needsKey = settings.aim.autoFireNeedsKey
            table.insert(out, { id = "autofire", name = translator:text("Автовыстрел"), key = needsKey and keyOf(Options.AimKey) or "ON", active = not needsKey or ui.aimHeld() })
        end
        return out
    end

    -- while the window is open the mouse is the user's
    function ui.menuOpen()
        return Library.Toggled == true
    end

    function ui.notify(title, description)
        Library:Notify({ Title = title, Description = description, Time = 8 })
    end

    function ui.unload()
        Library:Unload()
    end

    Library:OnUnload(deps.onLibraryUnload)

    -- configs and themes of the library, kept in workspace\Calcite, the configs of every game in a folder of its own
    -- (settings\Yba, settings\Town and so on: see SetSubFolder of the library); the key of the menu is not part of a config
    deps.ThemeManager:SetLibrary(Library)
    deps.SaveManager:SetLibrary(Library)
    deps.SaveManager:IgnoreThemeSettings()
    deps.SaveManager:SetIgnoreIndexes({ "MenuKeybind", "InterfaceLanguage", "InterfaceAccent", "InterfaceScale", "InterfaceHideOverlay" })
    deps.ThemeManager:SetFolder("Calcite")
    deps.SaveManager:SetFolder("Calcite")
    deps.SaveManager:SetSubFolder(modes.detect(deps.universeId))
    deps.SaveManager:BuildConfigSection(settingsTab)
    -- Four accent presets replace the external theme editor, which otherwise
    -- reloads its own theme over the approved Calcite palette on every startup.
    presentation = ui_style.mount(deps, Window)
    ui.profile = presentation.profile

    ui.applyMode()

    -- last: a config that loads sets the elements, and their handlers above write the settings
    deps.SaveManager:LoadAutoloadConfig()

    return ui
end

return menu
end

__modules["modes"] = function(require)
-- which game the script is set up for: decides which features run and what the menu shows
-- pure logic, checked by tests/modes_test.lua; the same rules as modes.h of the external
local modes = {}

-- Your Bizarre Adventure; a universe covers every place of a game, the main world and the arenas alike
modes.yba_universe = 1016936714

-- Blox Strike, a team shooter with rounds
modes.strike_universe = 7633926880

-- Steal an Egg, a PvE simulator with 7 player plots and 13 guard areas
modes.steal_universe = 10563114921

-- Town, a sandbox PvP; same feature set as Universal plus Fullbright
modes.town_universe = 1718755273

-- Murderers VS Sheriffs; two sides (team check), players carry one of two weapons
modes.mvs_universe = 7219654364

-- Item Asylum: FFA (no teams), players spawn with random weapons each round
modes.ia_universe = 1998835206

-- Rivals: a team shooter, players ESP + aim + team check as the basics
modes.rivals_universe = 6035872082

-- what the user can pick in the menu, in the order of the list there
modes.choices = { "Auto", "Universal", "Yba", "Strike", "StealEgg", "Town", "Mvs", "ItemAsylum", "Rivals" }

-- AutoFarm is taking the items of the world one after another, for the game whose items the script knows (autofarm.lua);
-- TimeErase is a mark on a player erasing time, whose model the game takes out of the world (King Crimson in YBA);
-- Kit is the stand and the fighting style of a player; Statuses are the effects on a player and its limbs;
-- OwnCharacters is for a game that builds its characters by itself and tells about them in attributes, see strike.lua;
-- Ping and Weapon are what such a game tells besides; LastSeen is the mark on the place a character was last at,
-- for a game whose server stops telling where the characters the user cannot see are; Sounds are the marks on the
-- places sounds were heard at, for a game whose server tells about those; Aim is moving the mouse towards a target,
-- for the games in which one shoots; Grenades are the ways of the grenades in the air, for a game whose server
-- tells about every throw; AutoStop is stopping the user before the auto fire shoots, for the game whose walking the
-- script can tell; SmartFire is the auto fire knowing the weapon in the hands (its rate of fire, its spread: see
-- weapon.lua), for the game whose weapons the script can read; Clouds are the smokes and the fires on the ground, for
-- a game whose server tells about them (clouds.lua); Wallbang is whether a bullet gets through what is in front, for the game whose rule of it
-- the script knows (penetration.lua); Spectators is who watches the user, for a game that tells how many watch each player;
-- Bhop is jumping again the moment the ground is touched, for the game whose
-- jump the script knows how to press, see strike_move.lua; ShotHook is the hook on the ray of a shot (no spread,
-- silent aim), for the game whose shooting code the script knows, see nospread.lua
local features = {
    Universal = { Players = true, Health = true, TeamCheck = true, Aim = true },
    -- no teams in this game
    Yba = { Players = true, Health = true, Items = true, Statuses = true, Kit = true, TimeErase = true, AutoFarm = true, Fly = true, Npc = true },
    Strike = {
        Players = true, Health = true, TeamCheck = true, OwnCharacters = true, Ping = true, Weapon = true, LastSeen = true,
        Sounds = true, Grenades = true, Aim = true, Bhop = true, Spectators = true, Wallbang = true, AutoStop = true,
        SmartFire = true, Clouds = true, ShotHook = true,
    },
    -- Steal an Egg: no players ESP, no fights; just teleport buttons + auto-steal loop + Fly
    StealEgg = { Teleport = true, Steal = true, Fly = true },
    -- Town: same core as Universal (players ESP + aim + team check) + Fullbright + TownGun (Silent Aim/AutoFire/Weapon ESP) + NoClip + Crosshair
    Town = { Players = true, Health = true, TeamCheck = true, Aim = true, Fullbright = true, TownGun = true, NoClip = true, Crosshair = true },
    -- MVS: team shooter (Murderers VS Sheriffs). Players ESP + aim + team check; Silent Aim/weapon details pending probe
    Mvs = { Players = true, Health = true, TeamCheck = true, Aim = true, MvsGun = true },
    -- Item Asylum: FFA с random weapons. Players ESP + aim + Weapon ESP (имя тулзы + патроны)
    ItemAsylum = { Players = true, Health = true, Aim = true, IaWeapon = true },
    -- Rivals: team shooter — пока основа (ESP с здоровьем + aim + team check)
    Rivals = { Players = true, Health = true, TeamCheck = true, Aim = true },
}

-- what a mode starts with set otherwise than the settings are written: fields of the table of settings.defaults
local overrides = {
    -- two sides shoot at each other, and the user's own side is not what the boxes and the aim are for
    Strike = { teamCheck = true },
}

local nothing = {}

function modes.overrides(mode)
    return overrides[mode] or nothing
end

-- the mode that suits a game, by the universe id of its data model
function modes.detect(universeId)
    if universeId == modes.yba_universe then
        return "Yba"
    end

    if universeId == modes.strike_universe then
        return "Strike"
    end

    if universeId == modes.steal_universe then
        return "StealEgg"
    end

    if universeId == modes.town_universe then
        return "Town"
    end

    if universeId == modes.mvs_universe then
        return "Mvs"
    end

    if universeId == modes.ia_universe then
        return "ItemAsylum"
    end

    if universeId == modes.rivals_universe then
        return "Rivals"
    end

    return "Universal"
end

-- the choice of the user wins; "Auto" and anything unknown follow the game
function modes.resolve(choice, universeId)
    if choice ~= nil and choice ~= "Auto" and features[choice] ~= nil then
        return choice
    end

    return modes.detect(universeId)
end

-- a feature a mode does not have is neither shown in the menu nor running
function modes.has(mode, feature)
    local list = features[mode] or features.Universal
    return list[feature] == true
end

function modes.name(mode)
    if mode == "Yba" then
        return "YBA"
    end

    if mode == "Strike" then
        return "Blox Strike"
    end

    if mode == "StealEgg" then
        return "Steal an Egg"
    end

    if mode == "Town" then
        return "Town"
    end

    if mode == "Mvs" then
        return "MVS"
    end

    if mode == "ItemAsylum" then
        return "Item Asylum"
    end

    if mode == "Rivals" then
        return "Rivals"
    end

    return "Universal"
end

return modes
end

__modules["mvs"] = function(require)
-- MVS (Murderers VS Sheriffs). Silent Aim для пистолета: один FireServer на GunKill убивает
-- Player по ссылке. Серверные проверки: same game, different team, Humanoid.Health > 0.
--
-- Поток выстрела (из decompile DefaultGun.LocalScript):
--   tool.fire:FireServer()                     -- визуал
--   tool.showBeam:FireServer(hitPos, startPos, handle)
--   Net:RemoteEvent("GunKill"):FireServer(weaponUid, enemyPlayer, lookVec, startPos, hitPos)
--
-- Старая схема шлёт сверх родного клика все три пакета — fire+showBeam дублируются и это палит
-- (на сервере два «выстрела без попадания» за клик + отдельный GunKill). Теперь шлём ТОЛЬКО GunKill:
--   • при клике ЛКМ родной клиент сам отправит fire+showBeam с его raycast'ом (может промах);
--     наш GunKill поверх выглядит как обычное попадание. Один доп. пакет вместо трёх.
--   • при autoFire trigger shooter из main.lua давит env.mouse1press — родной клик идёт тем же путём.
-- Запрос Net GunKill тащим из ReplicatedStorage.Packages.Net (это Sleitnick/Net или аналог).
-- weaponUid — захардкоженный GUID per weapon type: расширяем мапу по мере обнаружения.

local mvs = {}

local players = nil
local workspace_ = nil
local replicatedStorage = nil
local gameRequire = nil
local Net = nil
local gunKillRemote = nil
local resolveAttempted = false
local currentTarget = nil

-- кэш GUID оружий, автозаполняется при первом столкновении. DefaultGun — из probe.
local weaponUid = {
    DefaultGun = "72376a93-74c0-4fc7-b968-b3def980891c",
}

-- при неизвестном Tool пытается декомпилировать его LocalScript и выдернуть GUID литерал
-- (первая UUID-строка в коде = weapon uid). Кэширует результат. Если decompile недоступен, возвращает nil
local function resolveUid(tool)
    if tool == nil then return nil end
    local cached = weaponUid[tool.Name]
    if cached then return cached end
    local dec = decompile or (getgenv and getgenv().decompile)
    if type(dec) ~= "function" then return nil end
    for _, child in tool:GetChildren() do
        if child:IsA("LocalScript") then
            local ok, src = pcall(dec, child)
            if ok and type(src) == "string" then
                local guid = string.match(src, "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]")
                if guid then
                    weaponUid[tool.Name] = guid
                    return guid
                end
            end
        end
    end
    return nil
end

-- deps: players, workspace, replicatedStorage, gameRequire (env.gameRequire)
-- не ждём ничего синхронно: Packages в не-MVS играх отсутствует, WaitForChild блокировал бы меню.
-- Net:RemoteEvent("GunKill") резолвится лениво при первом shootOnce
function mvs.setup(deps)
    players = deps.players
    workspace_ = deps.workspace
    replicatedStorage = deps.replicatedStorage
    gameRequire = deps.gameRequire
end

local function ensureGunKill()
    if gunKillRemote ~= nil and gunKillRemote.Parent then return true end
    if replicatedStorage == nil then return false end
    local pkgs = replicatedStorage:FindFirstChild("Packages")
    local netMod = pkgs and pkgs:FindFirstChild("Net")
    if netMod == nil then return false end

    -- (1) прямой поиск: Sleitnick Net хранит remotes в своих детях/внутренних папках
    for _, d in netMod:GetDescendants() do
        if (d:IsA("RemoteEvent") or d:IsA("UnreliableRemoteEvent")) and d.Name == "GunKill" then
            gunKillRemote = d
            return true
        end
    end

    -- (2) fallback: require(Net):RemoteEvent("GunKill") — создаёт или получает existing
    if gameRequire == nil then return false end
    local ok, mod = pcall(gameRequire, netMod)
    if not ok or type(mod) ~= "table" or type(mod.RemoteEvent) ~= "function" then return false end
    Net = mod
    local okR, remote = pcall(function() return Net:RemoteEvent("GunKill") end)
    if okR and remote ~= nil then
        gunKillRemote = remote
        return true
    end
    return false
end

function mvs.setTarget(playerOrNil)
    currentTarget = playerOrNil
end

function mvs.target()
    return currentTarget
end


local function equippedTool(char)
    return char and char:FindFirstChildOfClass("Tool") or nil
end

-- выбирает видимую часть тела цели: пробуем голову первой (ваншот), потом корпус, потом конечности.
-- raycast из startPos (handle моего ствола) к центру части. Если ни одна не видна — nil (не стреляем)
local parts_order = { "Head", "UpperTorso", "LowerTorso", "Torso", "HumanoidRootPart",
    "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm",
    "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg",
    "LeftArm", "RightArm", "LeftLeg", "RightLeg" }

local function partVisible(startPos, part, myChar, targetChar)
    if workspace_ == nil then return true end
    local dir = part.Position - startPos
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    -- игнорим мои и target чары + ВСЕ живые Character'ы (союзники/противники не стены)
    local ignore = { myChar, targetChar }
    for _, pl in players:GetPlayers() do
        local c = pl.Character
        if c and c ~= myChar and c ~= targetChar then
            table.insert(ignore, c)
        end
    end
    params.FilterDescendantsInstances = ignore
    params.IgnoreWater = true
    -- несколько попыток: если первый hit прозрачный/Tool/accessory — пропускаем, продолжаем cast
    for i = 1, 10 do
        local hit = workspace_:Raycast(startPos, dir, params)
        if hit == nil then return true end
        local inst = hit.Instance
        local p = inst.Parent
        -- Humanoid parent — тело (чьё-то)
        if p and (p:FindFirstChildOfClass("Humanoid") or (p.Parent and p.Parent:FindFirstChildOfClass("Humanoid"))) then
            return true
        end
        -- Tool — чьё-то оружие
        if inst:FindFirstAncestorOfClass("Tool") then return true end
        -- Accessory — шапки/шлемы
        if inst:FindFirstAncestorOfClass("Accessory") then
            table.insert(ignore, inst)
            params.FilterDescendantsInstances = ignore
            continue
        end
        -- прозрачное — визуальный маркер
        if inst.Transparency and inst.Transparency >= 1 then
            table.insert(ignore, inst)
            params.FilterDescendantsInstances = ignore
            continue
        end
        -- non-collidable + полупрозрачный — effect-part (HandleBeamAttach и т.п.)
        if inst.CanCollide == false and inst.Transparency and inst.Transparency > 0.3 then
            table.insert(ignore, inst)
            params.FilterDescendantsInstances = ignore
            continue
        end
        -- всё остальное = стена
        return false
    end
    return false
end

local function pickVisiblePart(startPos, myChar, targetChar)
    for _, name in parts_order do
        local p = targetChar:FindFirstChild(name)
        if p and p:IsA("BasePart") and partVisible(startPos, p, myChar, targetChar) then
            return p
        end
    end
    return nil
end

local lastShotAt = 0
local reloadInterval = 2.5    -- кулдаун револьвера MVS

-- одиночный Silent Aim выстрел по currentTarget. Клик ЛКМ ловит хост, зовёт эту функцию
function mvs.shootOnce()
    local target = currentTarget
    if target == nil or not target.Parent then return false end
    local targetChar = target.Character
    if targetChar == nil then return false end
    local hum = targetChar:FindFirstChildOfClass("Humanoid")
    if hum == nil or hum.Health <= 0 then return false end

    local lp = players and players.LocalPlayer
    local myChar = lp and lp.Character
    local tool = equippedTool(myChar)
    if tool == nil then return false end
    local handle = tool:FindFirstChild("Handle")
    if handle == nil then return false end

    -- child "fire" — маркер «это пистолет MVS, а не нож». Сам fire-пакет шлёт родной клиент
    if tool:FindFirstChild("fire") == nil then return false end
    local uid = resolveUid(tool)
    if uid == nil then return false end
    if not ensureGunKill() then return false end

    local startPos = handle.Position
    -- пистолет ваншотит в любую точку → ищем первую видимую часть тела (приоритет голова)
    local part = pickVisiblePart(startPos, myChar, targetChar)
    if part == nil then return false end
    local hitPos = part.Position
    local lookVec = (hitPos - startPos).Unit

    -- fire:FireServer() и showBeam:FireServer() родной клиент отправит сам при клике ЛКМ (или при
    -- mouse1press'е от trigger shooter в autoFire). Мы шлём только GunKill — пакет попадания,
    -- параллельный родному потоку. На сервере картина = обычное попадание из бедра
    pcall(function() gunKillRemote:FireServer(uid, target, lookVec, startPos, hitPos) end)
    lastShotAt = os.clock()
    return true
end

-- приоритет: ближайший живой враг (без team-check, в MVS все часто в одной команде)
-- используем game:GetService напрямую — исключаем проблемы с deps.players
local function findClosestEnemy()
    local Players = game:GetService("Players")
    local lp = Players.LocalPlayer
    if lp == nil then return nil end
    local myChar = lp.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    local best, bestDistSq = nil, math.huge
    local list = Players:GetPlayers()
    for _, pl in list do
        if pl == lp then continue end
        local c = pl.Character
        if c == nil then continue end
        local h = c:FindFirstChildOfClass("Humanoid")
        if h == nil or h.Health <= 0 then continue end
        local root = c:FindFirstChild("HumanoidRootPart")
        if root == nil then continue end
        if myRoot then
            local dSq = (root.Position - myRoot.Position).Magnitude ^ 2
            if dSq < bestDistSq then bestDistSq = dSq; best = pl end
        else
            return pl
        end
    end
    return best
end

-- диагностика: причина молчания автофайра
local lastDiagAt = 0
local function diag(reason)
    local now = os.clock()
    if now - lastDiagAt < 1 then return end
    lastDiagAt = now
    print("[MVS autofire] " .. reason)
end

-- автофайр: берёт currentTarget (от aim pickWorld), если nil — ищет ближайшего живого напрямую.
-- Выстрел через GunKill (silent — без mouse1press, камера/курсор не двигаются)
function mvs.autoFire(settings)
    if settings == nil or settings.aim == nil or not settings.aim.autoFire then
        return false
    end
    if lastShotAt > 0 and (os.clock() - lastShotAt) < reloadInterval then
        diag(string.format("cooldown %.1fs", reloadInterval - (os.clock() - lastShotAt)))
        return false
    end
    local target = currentTarget
    if target == nil then target = findClosestEnemy() end
    if target == nil then diag("нет живых противников"); return false end
    if target.Character == nil then diag("target.Character nil"); return false end
    local hum = target.Character:FindFirstChildOfClass("Humanoid")
    if hum == nil or hum.Health <= 0 then diag("target hp<=0"); return false end

    local lp = players and players.LocalPlayer
    local myChar = lp and lp.Character
    local tool = equippedTool(myChar)
    if tool == nil then diag("нет Tool в руках"); return false end
    -- child "fire" остаётся маркером «это пистолет MVS» (нож его не имеет): шлёт его родной клиент сам,
    -- мы только GunKill
    if tool:FindFirstChild("fire") == nil then diag("tool '" .. tool.Name .. "' без child 'fire' (не пистолет MVS)"); return false end
    local uid = resolveUid(tool)
    if uid == nil then diag("не вытащил UID для '" .. tool.Name .. "' (decompile fail?)"); return false end
    if not ensureGunKill() then diag("Net:RemoteEvent('GunKill') не резолвнулся"); return false end

    local handle = tool:FindFirstChild("Handle")
    if handle == nil then diag("нет Handle у tool"); return false end
    local part = pickVisiblePart(handle.Position, myChar, target.Character)
    if part == nil then diag("pickVisiblePart: ни одна часть не видна"); return false end

    local saved = currentTarget
    currentTarget = target
    local ok = mvs.shootOnce()
    currentTarget = saved
    if ok then diag("FIRED → " .. target.Name) end
    return ok
end

return mvs
end

__modules["noclip"] = function(require)
-- NoClip: каждый кадр ставит CanCollide=false на всех BaseParts персонажа — классическая схема
-- Roblox-noclip. Humanoid физика через кадр возвращает CanCollide=true (особенно у HumanoidRootPart),
-- поэтому проход цикла нужен каждый тик. При выключении восстанавливаем те части, которые трогали.
-- Персонаж через стены проходит, но «проваливание в пол» не происходит мгновенно — Humanoid удерживает
-- ходьбу на поверхности пока луч под ногами что-то видит. На практике достаточно идти вперёд, чтобы пройти
-- сквозь стенку в чужую базу.
-- pure logic over deps, checked by tests/noclip_test.lua
local noclip = {}

local Noclip = {}
Noclip.__index = Noclip

-- deps:
--   character() -> Model | nil        текущий персонаж локального игрока
function noclip.new(deps)
    return setmetatable({
        deps = deps,
        changed = {},     -- [BasePart] = true, пока NoClip включён и часть мы делали non-collide
    }, Noclip)
end

-- один шаг: при enabled проходит по всем BaseParts и выставляет CanCollide=false, запоминая какие
-- трогал. При !enabled, если ранее трогал — ставит CanCollide=true и очищает память.
-- Возвращает true если что-то изменил на этом шаге
function Noclip:step(enabled)
    local char = self.deps.character()
    if enabled then
        if char == nil then return false end
        local changed = false
        for _, part in char:GetDescendants() do
            if part:IsA("BasePart") and part.CanCollide then
                self.changed[part] = true
                part.CanCollide = false
                changed = true
            end
        end
        return changed
    end

    -- выключили: восстанавливаем все части что трогали, пока они ещё в мире
    if next(self.changed) == nil then
        return false
    end
    for part in self.changed do
        if part.Parent ~= nil then
            part.CanCollide = true
        end
    end
    table.clear(self.changed)
    return true
end

return noclip
end

__modules["nospread"] = function(require)
-- the hook on Blox Strike's shot ray, which decides where every bullet goes. Two features ride on it:
--
--   NoSpread (settings.nospread.enabled)
--     the second arg of the game's _performRaycast is the spread in degrees; the function then rotates the ray
--     from the center of the screen by Phi = Random:NextNumber(0, rad(spread * 0.5)). Passing 0 collapses Phi to 0,
--     so the ray goes exactly down the crosshair and the hit list the client sends to the server is the clean one.
--     The game's spread spring keeps running so the crosshair still visually grows
--
--   Silent Aim (settings.silentaim.enabled)
--     when the user shoots, the hook builds its own ray from the camera to the chosen target and runs the game's
--     own castThroughDistance to produce a hit list in the exact shape _performRaycast returns. The game's shot
--     code uses that result as if it had cast the ray itself, and the server sees a bullet in the target. The mouse
--     is not moved and the camera does not turn
--
-- Silent Aim takes priority: if there is a target, the ray goes to it, spread is ignored. Without a target the
-- NoSpread check still runs. With neither feature active the hook is a straight passthrough
--
-- the hook is on a public method of the game module, so a flag on the module itself keeps it from being restacked
-- on a reload
local nospread = {}

-- deps:
--   task                scheduler (env.task)
--   gameRequire         the executor's real require (env.gameRequire)
--   replicatedStorage   the service
--   workspace           the service, for the camera when Silent Aim builds the ray
--   isNoSpreadEnabled() -> boolean      polled on every shot
--   isSilentEnabled() -> boolean        polled on every shot
--   pickSilentTarget() -> { x, y, z } or nil
--                       returns the world point for Silent Aim to send the bullet at; may be nil
function nospread.start(deps)
    -- Potassium hides the global `task` from glued modules; the host passes it through deps. Test harness has
    -- neither this nor a real module to hook, so a missing scheduler is the signal to no-op
    local scheduler = deps.task
    if type(scheduler) ~= "table" or type(scheduler.spawn) ~= "function" then
        return
    end

    local gameRequire = deps.gameRequire
    if type(gameRequire) ~= "function" then
        return
    end

    scheduler.spawn(function()
        local ok, Bullet, Raycast, GetRayIgnore = pcall(function()
            local components = deps.replicatedStorage:WaitForChild("Components", 20)
            local weapon = components and components:WaitForChild("Weapon", 10)
            local classes = weapon and weapon:WaitForChild("Classes", 10)
            local bulletModule = classes and classes:WaitForChild("Bullet", 10)
            local shared = deps.replicatedStorage:WaitForChild("Shared", 10)
            local raycastModule = shared and shared:WaitForChild("Raycast", 10)
            local commonFolder = components and components:WaitForChild("Common", 10)
            local ignoreModule = commonFolder and commonFolder:WaitForChild("GetRayIgnore", 10)

            if bulletModule == nil or raycastModule == nil or ignoreModule == nil then
                return nil, nil, nil
            end

            return gameRequire(bulletModule), gameRequire(raycastModule), gameRequire(ignoreModule)
        end)

        if not ok or type(Bullet) ~= "table" or type(Bullet._performRaycast) ~= "function" then
            return
        end

        local castThroughDistance = type(Raycast) == "table" and Raycast.castThroughDistance or nil
        if type(castThroughDistance) ~= "function" then
            return
        end

        if type(GetRayIgnore) ~= "function" then
            return
        end

        if Bullet.__calciteNoSpread == true then
            return
        end
        Bullet.__calciteNoSpread = true

        local original = Bullet._performRaycast
        local camera = deps.workspace.CurrentCamera

        -- builds a result in the exact shape the game's _performRaycast returns: {Distance, Origin, Direction, Hits}
        -- with Hits[i] = {Position, Instance, Material, Normal, Exit}. The game's shot code takes it from there
        local function castToTarget(self, origin, direction)
            local range = self.Properties.Range or 500
            local penetration = self.Properties.Penetration or 0
            local ignored = GetRayIgnore()

            local result = {
                Distance = 0,
                Origin = origin,
                Direction = direction,
                Hits = {},
            }

            local hits = castThroughDistance(origin, direction * range, penetration, ignored)
            local first = hits and hits[1]
            if first == nil then
                result.Distance = range
                return result
            end

            result.Distance = (first.position - origin).Magnitude
            for i, hit in hits do
                if hit.instance and hit.material then
                    table.insert(result.Hits, {
                        Position = hit.position,
                        Instance = hit.instance,
                        Material = hit.material.Name,
                        Normal = hit.normal or Vector3.new(0, 0, 0),
                        Exit = i % 2 == 0,
                    })
                end
            end

            return result
        end

        Bullet._performRaycast = function(self, spread)
            local silentOn = deps.isSilentEnabled and deps.isSilentEnabled() == true
            if silentOn and deps.pickSilentTarget then
                local target = deps.pickSilentTarget()
                if type(target) == "table" and target.x and target.y and target.z then
                    local cam = camera or deps.workspace.CurrentCamera
                    camera = cam
                    local okCam, origin = pcall(function()
                        return cam.CFrame.Position
                    end)
                    if okCam then
                        local toward = Vector3.new(target.x - origin.X, target.y - origin.Y, target.z - origin.Z)
                        if toward.Magnitude > 0 then
                            local direction = toward.Unit
                            local okResult, result = pcall(castToTarget, self, origin, direction)
                            if okResult then
                                return result
                            end
                        end
                    end
                end
            end

            if deps.isNoSpreadEnabled and deps.isNoSpreadEnabled() == true then
                return original(self, 0)
            end

            return original(self, spread)
        end
    end)
end

return nospread
end

__modules["num"] = function(require)
-- what a number read from the game has to be before it is used; checked by tests/num_test.lua
local num = {}

local max_coordinate = 1e6      -- no map is this big; memory of a part that is being destroyed can hold anything

function num.finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- whether three numbers can be a place in the world
function num.plausible(x, y, z)
    return num.finite(x) and num.finite(y) and num.finite(z)
        and math.abs(x) < max_coordinate and math.abs(y) < max_coordinate and math.abs(z) < max_coordinate
end

return num
end

__modules["penetration"] = function(require)
-- whether a bullet of Blox Strike gets through what is in front of the user: the same steps as castThroughDistance of
-- the game (ReplicatedStorage.Shared.Raycast, read by tools/strike_probe9.lua), which a shot of the user is worked out
-- with on the client:
--   a ray goes from the camera along the shot; every part it meets is gone into, and its way out is found by a ray
--   from far beyond back to the same part alone;
--   how deep the bullet has been in each kind of stuff is added up over the whole way; when that goes beyond what the
--   stuff allows (its number in the table of the game, plus the Penetration of the weapon), the bullet stops inside;
--   accessories, root parts and capsules are passed by as if they were not there
-- the module of the game itself is not called: it breaks itself when it is called from an executor
-- pure logic: the world comes in as functions; checked by tests/penetration_test.lua
local penetration = {}

local max_casts = 100       -- things met on one way, as the game counts them

-- how many studs of a kind of stuff a bullet goes through beyond the Penetration of the weapon
penetration.materials = {
    Asphalt = 0, Basalt = 0, Brick = 0, Cobblestone = 0, Concrete = 0, CrackedLava = 0, DiamondPlate = 0, Foil = 0,
    Glacier = 0, Granite = 0, Grass = 0, Ground = 0, Ice = 0, LeafyGrass = 0, Limestone = 0, Marble = 0, Metal = 0,
    Mud = 0, Pavement = 0, Rock = 0, Salt = 0, Sand = 0, Sandstone = 0, Slate = 0, Snow = 0, ForceField = 0, Neon = 0,
    CorrodedMetal = 0, Pebble = 0, CeramicTiles = 0, Plaster = 0,
    Plastic = 10, SmoothPlastic = 10, Wood = 10, WoodPlanks = 10, Cardboard = 10,
    Glass = 25, Fabric = 25,
}

-- variants of a material that count by themselves, apart from their material
penetration.variants = { ["Sandy Brick"] = 0, IndoorWall = 0 }

-- maps on which a kind of stuff that allows nothing beyond the weapon allows this instead
penetration.map_minimum = { Reactor = -1 }

-- what a part counts as: the key its depth is added up under, how much it allows, and whether that is a variant
-- (the depths of variants are added up apart from the depths of materials)
--   isDoor: the part is in a model the game tags BreakableDoor: a door counts as metal
function penetration.allowance(materialName, variant, isDoor, mapName)
    local key, value, isVariant

    if variant ~= nil and variant ~= "" and penetration.variants[variant] ~= nil then
        key = variant
        value = penetration.variants[variant]
        isVariant = true
    else
        key = if isDoor then "Metal" else materialName
        value = penetration.materials[key]
        isVariant = false
    end

    value = value or 0
    if value == 0 and mapName ~= nil and penetration.map_minimum[mapName] ~= nil then
        value = penetration.map_minimum[mapName]
    end

    return key, value, isVariant
end

-- the way of a bullet: from (ox, oy, oz) along the unit (ux, uy, uz), as far as range, with the power of the weapon
-- deps:
--   cast(x, y, z, dx, dy, dz) -> { instance, x, y, z, nx, ny, nz } or nil: the first part on that way, leaving out what
--     was given to ignore()
--   ignore(instance)
--   filtered(instance) -> boolean: passed by without counting (accessories, root parts, capsules)
--   exitOf(instance, x, y, z, ux, uy, uz) -> x, y, z, nx, ny, nz or nil: where the way out of that part is
--   allowance(instance) -> key, limit, isVariant: see penetration.allowance
-- gives back { hits, stopped }: hits are { instance, x, y, z, nx, ny, nz, exit } in the order the bullet met them, a way
-- in and then its way out; stopped is true when the bullet stayed inside something
function penetration.trace(ox, oy, oz, ux, uy, uz, range, power, deps)
    local x, y, z = ox, oy, oz
    local depths, variantDepths = {}, {}
    local hits = {}
    local stopped = false

    for _ = 1, max_casts do
        local gone = math.max((x - ox) * ux + (y - oy) * uy + (z - oz) * uz, 0)
        local left = range - gone
        if left <= 0 then
            break
        end

        local hit = deps.cast(x, y, z, ux * left, uy * left, uz * left)
        if hit == nil then
            break
        end

        deps.ignore(hit.instance)

        if not deps.filtered(hit.instance) then
            table.insert(hits, { instance = hit.instance, x = hit.x, y = hit.y, z = hit.z, nx = hit.nx, ny = hit.ny, nz = hit.nz, exit = false })
            local kept = #hits

            local stop
            local exitX, exitY, exitZ, exitNx, exitNy, exitNz = deps.exitOf(hit.instance, hit.x, hit.y, hit.z, ux, uy, uz)
            if exitX == nil then
                -- no way out found: the bullet stays at the way in
                x, y, z = hit.x, hit.y, hit.z
                stop = true
            else
                local depth = math.sqrt((exitX - hit.x) ^ 2 + (exitY - hit.y) ^ 2 + (exitZ - hit.z) ^ 2)
                local key, limit, isVariant = deps.allowance(hit.instance)
                local sums = if isVariant then variantDepths else depths
                sums[key] = (sums[key] or 0) + depth

                x, y, z = exitX, exitY, exitZ
                if sums[key] > limit + power then
                    stop = true
                else
                    table.insert(hits, { instance = hit.instance, x = exitX, y = exitY, z = exitZ, nx = exitNx, ny = exitNy, nz = exitNz, exit = true })
                    stop = false
                end
            end

            -- what lies beyond the range did not happen
            if range < (x - ox) * ux + (y - oy) * uy + (z - oz) * uz then
                while #hits > kept do
                    table.remove(hits)
                end
                break
            end

            if stop then
                stopped = true
                break
            end
        end
    end

    return { hits = hits, stopped = stopped }
end

-- what a way means for the user: the first one of the others it reaches (ownerOf(instance) -> who, or nil for the
-- world), through how many walls; or, when it reaches nobody, whether the first wall ahead lets the bullet through
-- gives back { target, part, walls, firstWall = "through" | "blocked" | nil }
function penetration.read(result, ownerOf)
    local hits = result.hits
    local walls = 0
    local firstWall = nil

    for index, hit in hits do
        if not hit.exit then
            local who = ownerOf(hit.instance)
            if who ~= nil then
                return { target = who, part = hit.instance, walls = walls, firstWall = firstWall }
            end

            walls += 1
            if firstWall == nil then
                local after = hits[index + 1]
                firstWall = if after ~= nil and after.exit and after.instance == hit.instance then "through" else "blocked"
            end
        end
    end

    return { target = nil, part = nil, walls = walls, firstWall = firstWall }
end

return penetration
end

__modules["players"] = function(require)
-- what is read about the other players: slowly what changes rarely, on every frame what the box needs
-- reads the game through the objects it is given, so tests/players_test.lua runs it on stand-ins
local hitbox = require("./hitbox")
local num = require("./num")
local status = require("./status")

local players = {}

local none = {}     -- the statuses and the parts of every record that has none; shared, never written to

function players.newRecord(player)
    return {
        player = player,
        key = player,           -- what the esp keeps the health track by, so that it lives through a respawn
        name = player.Name,
        character = nil,        -- nil while the player is not to be drawn
        root = nil,
        humanoid = nil,
        shielded = false,
        statuses = none,
        stand = "",
        spec = "",
        leftArm = "",
        rightArm = "",
        leftLeg = "",
        rightLeg = "",
        body = nil,             -- the character, and the parts of it the aim goes for, see hitbox.collect
        parts = none,
        target = {},            -- filled again on every frame, see players.target
    }
end

-- the string of a StringValue of that name, empty when there is none
local function stringIn(folder, name)
    if folder == nil then
        return ""
    end

    local object = folder:FindFirstChild(name)
    if object == nil or object.ClassName ~= "StringValue" then
        return ""
    end

    local value = object.Value
    if type(value) ~= "string" then
        return ""
    end

    return value
end

-- names of the particle emitters that sit right in a part
local function emittersIn(part)
    local names = {}
    if part == nil then
        return names
    end

    for _, child in part:GetChildren() do
        if child.ClassName == "ParticleEmitter" then
            table.insert(names, child.Name)
        end
    end

    return names
end

-- the Time Erase of King Crimson in YBA (tools/yba_probe1.lua): for as long as it lasts, some 8.6 s, the game takes
-- the model of the player out of the world on every other client and gives it the attribute Invincible. Nothing moves
-- it meanwhile: its root stays where the erase began, and the player comes back into the world wherever he went.
-- Out of the world with that attribute is an erase; without it, a model that is not streamed in or is being destroyed
local function erasing(character)
    return character.Parent == nil and character:GetAttribute("Invincible") == true
end

-- the slow pass: which body the player has right now and what is known about it
-- wantYba asks for what only Your Bizarre Adventure has: the effects, the stand, the style and the limbs
function players.refresh(record, wantYba)
    local player = record.player

    record.character = nil
    record.root = nil
    record.humanoid = nil
    record.shielded = false
    record.statuses = none
    record.stand = ""
    record.spec = ""
    record.leftArm = ""
    record.rightArm = ""
    record.leftLeg = ""
    record.rightLeg = ""
    record.body = nil
    record.parts = none

    -- a character without a parent is far away and not streamed in, unless it is erasing time
    local character = player.Character
    if character == nil or (character.Parent == nil and not erasing(character)) then
        return
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    if root == nil or not root:IsA("BasePart") then
        return
    end

    record.character = character
    record.root = root
    record.humanoid = character:FindFirstChildOfClass("Humanoid")

    -- what the aim goes for
    record.body = character
    record.parts = hitbox.collect(character)

    -- the stock protection of Roblox: while a ForceField is in the character, nothing hurts it;
    -- games put it there on spawn and take it away after a few seconds
    record.shielded = character:FindFirstChildOfClass("ForceField") ~= nil

    if not wantYba then
        return
    end

    local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
    record.statuses = status.collect(emittersIn(torso), emittersIn(root))

    -- Player.PlayerStats holds the stand, the fighting style and the limbs as string values, see kit.lua
    local stats = player:FindFirstChild("PlayerStats")
    record.stand = stringIn(stats, "Stand")
    record.spec = stringIn(stats, "Spec")
    record.leftArm = stringIn(stats, "LeftArm")
    record.rightArm = stringIn(stats, "RightArm")
    record.leftLeg = stringIn(stats, "LeftLeg")
    record.rightLeg = stringIn(stats, "RightLeg")
end

-- every frame: where the player is and how much health is left; nil when the player is not to be drawn
-- the table that comes back belongs to the record and is filled again by the next call
-- an erasing one (see erasing) comes back with erased, and erasedFor seconds since the erase began by the clock now;
-- its place is where the erase began, and it counts as hidden: nobody is there to be aimed at
function players.target(record, localTeam, haveLocal, localX, localY, localZ, now)
    -- respawned or gone since the pass: the old body is not drawn
    local character = record.character
    if character == nil or record.player.Character ~= character then
        return nil
    end

    local erased = false
    if character.Parent == nil then
        if not erasing(character) then
            record.erasedSince = nil
            return nil
        end

        erased = true
        if record.erasedSince == nil then
            record.erasedSince = now or 0
        end
    else
        record.erasedSince = nil
    end

    local root = record.root
    if root.Parent ~= character then
        return nil
    end

    local position = root.Position
    local x, y, z = position.X, position.Y, position.Z
    if not num.plausible(x, y, z) then
        return nil
    end

    local haveHealth = false
    local fraction = 0
    local humanoid = record.humanoid
    if humanoid ~= nil and humanoid.Parent == character then
        local health = humanoid.Health
        local maxHealth = humanoid.MaxHealth

        if num.finite(health) and num.finite(maxHealth) and maxHealth > 0 then
            if health <= 0 then
                return nil
            end

            haveHealth = true
            fraction = math.clamp(health / maxHealth, 0, 1)
        end
    end

    local target = record.target
    target.record = record
    target.x = x
    target.y = y
    target.z = z
    target.haveHealth = haveHealth
    target.healthFraction = fraction
    -- games without teams leave both empty, nobody is a teammate there
    target.sameTeam = localTeam ~= nil and record.player.Team == localTeam
    -- the distance is unknown while the user has no character
    target.haveDistance = haveLocal
    target.distance = 0
    target.erased = erased
    target.erasedFor = if erased then (now or 0) - record.erasedSince else 0
    target.hidden = erased

    if haveLocal then
        local dx, dy, dz = x - localX, y - localY, z - localZ
        target.distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    return target
end

return players
end

__modules["prompt_place"] = function(require)
-- where a ProximityPrompt is in the world, what the thing it belongs to is called, and which prompts are not items
-- the same rules as rbx/world.cpp of the external; reads the game through the objects it is given,
-- so tests/prompt_place_test.lua runs it on stand-ins
local prompt_place = {}

prompt_place.max_climb = 4      -- levels above a prompt searched for the part it sits on

local partClasses = {
    Part = true, MeshPart = true, UnionOperation = true, PartOperation = true, IntersectOperation = true,
    WedgePart = true, CornerWedgePart = true, TrussPart = true, SpawnLocation = true, Seat = true, VehicleSeat = true,
}

local function isPart(instance)
    return partClasses[instance.ClassName] == true
end

-- the part a prompt sits on, and the object the item is named after when the prompt has no text of its own:
-- the part the prompt is a child of; for a prompt put straight into a model (a tool is a model too), the primary part
-- of the model or failing that any part of it; else the nearest part above (a prompt on an attachment)
-- a folder is not a place: a prompt lying loose in one has no position, and nil comes back
function prompt_place.locate(prompt)
    local holder = prompt.Parent
    if holder == nil then
        return nil, nil
    end

    if isPart(holder) then
        return holder, holder
    end

    local part = nil
    local named = holder

    if holder.ClassName == "Model" or holder.ClassName == "Tool" then
        local primary = holder.PrimaryPart
        if primary ~= nil and isPart(primary) then
            part = primary
        end

        if part == nil then
            for _, sibling in holder:GetChildren() do
                if isPart(sibling) then
                    part = sibling
                    break
                end
            end
        end
    end

    local above = holder
    local level = 0
    while part == nil and level < prompt_place.max_climb do
        above = above.Parent
        if above == nil then
            break
        end

        if isPart(above) then
            part = above
            named = above
        end

        level += 1
    end

    if part == nil then
        return nil, nil
    end

    return part, named
end

-- the name of the item and the text of the action
function prompt_place.describe(prompt, named)
    local name = prompt.ObjectText
    if name == nil or name == "" then
        name = named.Name
    end

    return name, prompt.ActionText or ""
end

-- true for a prompt that is not an item of the world: inside something with a humanoid or an animation controller
-- (a character, its parts move with it), inside the camera (first person view models) or the terrain,
-- or not under the root at all
function prompt_place.excluded(prompt, root)
    -- asked of the engine and not found out by comparing the parents with the root: the root may be another
    -- reference to the workspace than the one the parents lead to (cloneref of an executor),
    -- and two references to one object are not equal
    if not prompt:IsDescendantOf(root) then
        return true
    end

    -- every ancestor is looked at, the ones above the root too: there are two of them at most
    local node = prompt.Parent

    while node ~= nil do
        local className = node.ClassName
        if className == "Camera" or className == "Terrain" then
            return true
        end

        if node:FindFirstChildOfClass("Humanoid") ~= nil or node:FindFirstChildOfClass("AnimationController") ~= nil then
            return true
        end

        node = node.Parent
    end

    return false
end

return prompt_place
end

__modules["settings"] = function(require)
-- everything the menu sets, and the same as it is in effect in a mode
-- pure logic, checked by tests/settings_test.lua
local item_kinds = require("./item_kinds")
local modes = require("./modes")
local status = require("./status")

local settings = {}

-- colors are { r, g, b } with 0..255 each
-- mode is the one the script starts in: a mode may start with something set its own way, see modes.overrides
function settings.defaults(mode)
    local s = {
        modeChoice = "Auto",                -- one of modes.choices
        interface = { language = "ru", accent = "Lilac", scale = 100, hideOverlay = true },
        enabled = true,
        box = true,
        name = true,
        distance = true,
        healthBar = true,
        healthBarFullColor = { 0, 255, 0 },   -- цвет полоски при полном HP
        healthBarEmptyColor = { 255, 0, 0 },  -- цвет полоски при HP=0; между ними lerp по fraction
        hideInvincible = false,             -- не рисовать ESP на игроках с ForceField/Invincible (shielded)
        protection = true,                  -- tells that a player cannot be hurt right now (spawn protection)
        statusKinds = status.allKinds(),    -- which states of a player are shown (ids of status.kinds), in YBA
        stand = true,
        spec = true,
        teamCheck = false,
        ping = true,                        -- the ping of a player, in the game that tells it
        weapon = true,                      -- what a player has in the hands, in the game that tells it
        lastSeen = true,                    -- a dim mark where a character was last, once the game stops telling where it is
        sounds = true,                      -- a mark where a step was heard and nobody is seen, in the game that tells about sounds
        grenades = true,                    -- the way of every grenade in the air and where it ends, in the game that tells about throws
        grenadePreview = true,              -- the way the grenade in the hand would take if it were thrown now
        clouds = true,                      -- how far every smoke and fire on the ground reaches, and its time left
        spectators = true,                  -- who is watching the user, in the game that tells how many watch each one
        wallbang = true,                    -- whether the wall under the crosshair can be shot through, and who is behind it
        maxDistance = 1000,                 -- studs
        boxColor = { 255, 255, 255 },
        textColor = { 255, 255, 255 },
        -- the aim: while its key is held, the mouse is moved towards the one nearest to the crosshair
        aim = {
            enabled = false,
            -- which point of the body it goes for, see hitbox.lua
            zones = { true, true, true, false, false },     -- head, chest, stomach, arms, legs: the ones it may pick
            nearestPoint = false,           -- false = the zones in that order, true = the point closest to the crosshair
            multipoint = true,              -- besides the centre of a part, try points towards its edges
            pointInset = 0.7,               -- how far from the centre those points are, 1 = the very edge
            showPoint = true,               -- mark the point the aim would go for
            radius = 150,                   -- pixels around the crosshair
            fullScreen = false,             -- любой враг на экране — валидная цель (круг не рисуется)
            showFov = true,                 -- draw that circle
            speed = 12,                     -- 1/s: the share of the error removed in a frame is 1 - exp(-speed * dt)
            visibleOnly = true,             -- leave alone who is behind a wall
            skipProtected = true,           -- leave alone who cannot be hurt right now
            maxDistance = 500,              -- studs
            weakestFirst = false,           -- among the targets in the circle take the one with the least health, not the nearest
            -- the auto fire: clicks while the crosshair is on a part of a body the aim may pick, see trigger.lua
            autoFire = false,
            autoFireNeedsKey = true,        -- only while the key of the aim is held
            autoFireThroughWalls = false,   -- also at somebody behind a wall a bullet gets through, where that is known
            autoStop = "Off",               -- "Off", "OnTarget" or "Early": stop the user before a shot, see autostop.lua
            fireInterval = 120,             -- milliseconds between clicks, where the weapon is not known
            hitChance = 60,                 -- percent of the cone of the spread that must hit, where it is known; 0: any
        },
        -- the bhop: while the jump key is held, the jump is made again the moment the ground is touched, see bhop.lua
        bhop = {
            enabled = false,
        },
        -- the fly for YBA: WASD / Space / Shift drives the character through CFrame steps, same technique as the
        -- auto-farm glider (fly.lua). Hotkey is managed by a KeyPicker in the menu (see FlyKey)
        fly = {
            enabled = false,
            speed = 60,
        },
        -- Fullbright for Town: убирает ночь/туман/тени через Lighting (fullbright.lua)
        fullbright = {
            enabled = false,
        },
        -- NoClip for Town: CanCollide=false на всех BaseParts персонажа каждый кадр (noclip.lua)
        noclip = {
            enabled = false,
        },
        -- Chams: Highlight-подсветка моделей чужих игроков. Доступно в любом режиме с Players ESP
        chams = {
            enabled = false,
            fillColor = { 255, 50, 50 },
            fillTransparency = 50,          -- проценты 0..100 (slider целочисленный, в chams.lua делится на 100)
            outlineColor = { 255, 255, 255 },
            outlineTransparency = 0,
            throughWalls = true,
        },
        -- Force Crosshair: всегда рисовать прицел по центру viewport. Пригодится там, где родной курсор
        -- скрыт/заменён (Town с mouse-lock) или нужен один стабильный центр
        crosshair = {
            enabled = false,
            size = 10,                      -- длина плеча крестика в пикселях
            gap = 3,                        -- отступ от центра до начала плеча
            thickness = 1,                  -- draw.line рисует толщиной 1, оставлено для совместимости
            dot = true,
            color = { 255, 255, 255 },
        },
        -- Town Silent Aim: подмена shotTable в FireEvent (town.lua)
        -- ignoreLimits=false (по умолчанию): autoFire молчит пока родной GunScript тоже не стрелял бы
        -- (спринт, inspect, Humanoid.Health<=0). Выглядит реалистично.
        -- ignoreLimits=true: шлём пакет всегда — сервер не проверяет state, можно убивать в прыжке
        -- через reload в спринте и прочих нереальных ситуациях. Палево, но смешно
        townSilent = {
            enabled = false,
            ignoreLimits = false,
        },
        -- Town Weapon ESP: показывать имя оружия и ammo над игроком (esp_players.lua + town.lua)
        townWeapon = {
            enabled = true,
        },
        -- Item Asylum Weapon ESP: имя тулзы + патроны (ToolIconText) + абилки E/R (item_asylum.lua)
        iaWeapon = {
            enabled = true,
            showAbilities = false,  -- показывать EABILITY/RABILITY (длинно, но полезно)
        },
        -- MVS Silent Aim: клик ЛКМ зовёт Net:RemoteEvent("GunKill") на цель Аима (mvs.lua).
        -- Rage mode собирается из Aim + Silent + AutoFire на вкладке — отдельного тумблера нет
        mvsSilent = {
            enabled = false,
            cooldownMs = 500,     -- интервал между GunKill-выстрелами в автофайре (мс). Реальный револьвер 2500мс
        },
        -- HUD: watermark (всегда) и reload bar (MVS)
        watermark = {
            enabled = true,
        },
        reloadBar = {
            enabled = true,
        },
        hotkeys = {
            enabled = true,
        },
        -- Hit logs: уведомления «Hit <name> in <part> for <X> hp» в правом верхнем углу
        -- после каждого выстрела autoFire (Town). Урон считается из Settings оружия (Damage × multiplier
        -- по зоне). Приблизительно: сервер может иметь свой falloff/броню, но для rage хватает
        hitLogs = {
            enabled = true,
        },
        -- NoSpread for Blox Strike: zeroes the angular deviation the game's _performRaycast adds to the shot
        -- direction, so every bullet goes straight down the center of the screen. See nospread.lua
        nospread = {
            enabled = false,
        },
        -- Silent Aim for Blox Strike: on a shot, the client's own raycast is replaced with one that goes from the
        -- camera to the target the aim's picker would choose. The mouse never moves. Uses settings.aim.* for which
        -- zones, FOV radius, max distance, visibility and team-check to apply. See nospread.lua
        silentaim = {
            enabled = false,
        },
        -- Steal an Egg: auto-steal loop + which zones to hunt + which plot to deliver to. See steal_farm.lua
        steal = {
            enabled = false,
            zones = {},             -- { ["Forest"] = true, ... } — какие зоны фармим
            myPlot = 1,             -- номер Plot'а, куда носим яйцо (1..7)
            autoPlot = true,        -- авто-детект своего plot по имени на PlotSign (перебивает myPlot)
            moveMode = "TP",        -- "TP" (3-фазный tp up→horiz→down, как Pulse Hub), "Walk", "Glide"
            -- TP mode: разбивка на 3 телепорта с паузами обманывает античит
            tpUpHeight = 30,        -- студов: насколько прыгаем вверх на фазе 1
            tpUpDelay = 150,        -- мс: пауза после прыжка вверх
            tpDelay = 180,          -- мс: пауза после горизонтального тп
            tpDownDelay = 250,      -- мс: пауза после опускания вниз
            dropDelay = 50,         -- мс: пауза перед следующим действием
            -- Walk mode
            walkSpeed = 60,         -- студ/с: Humanoid.WalkSpeed в режиме Walk
            -- Glide mode
            speed = 500,            -- студ/с: скорость глайдера в режиме Glide
            -- Z-detour: все 13 guard-зон лежат в полосе Z=[-440..-290]. Путь через центры будит
            -- стражей всех промежуточных зон → они догоняют и килляют. Обход — выходим из полосы
            -- по Z, едем по X вне стража, заходим в целевую зону одним прыжком. Пересекает только
            -- 1 guard-зону (целевую) вместо всех 13.
            detour = true,
            safeZ = -200,           -- Z-координата коридора обхода (вне полосы)
        },
        -- the auto farm of YBA: the items of these kinds (ids of item_kinds) are taken one after another, see autofarm.lua
        farm = {
            enabled = false,
            kinds = item_kinds.defaults(),
            -- when the farm has nothing in sight, the glider ambles to a random point near the character so new
            -- spawns (and whatever a nearby player drops) come in. On this game the server has no streaming radius
            -- (yba_items_probe says StreamingEnabled=false), but spawn density is low on quiet servers, so the only
            -- way to see more items is to be more places
            roam = true,
            roamRadius = 350,       -- studs around the current spot the roam picks the next waypoint in
            speed = 1800,           -- studs/sec the glider moves at (same as Slowc2960's observed pace by default)
        },
        -- labels on the things the player can interact with (anything that shows a "press E" prompt)
        items = {
            enabled = false,
            kinds = item_kinds.defaults(),                      -- the kinds shown (ids of item_kinds)
            maxDistance = 300,                                  -- studs
            color = { 255, 209, 64 },
        },
    }

    for key, value in modes.overrides(mode) do
        s[key] = value
    end

    return s
end

-- the settings as they are in effect in a mode: what the mode does not have is off, whatever its switch says,
-- since a feature whose controls are hidden must not keep working out of sight
function settings.inEffect(s, mode)
    local e = table.clone(s)
    e.items = table.clone(s.items)
    e.aim = table.clone(s.aim)
    e.bhop = table.clone(s.bhop)

    if not modes.has(mode, "Players") then
        e.enabled = false
    end

    if not modes.has(mode, "Items") then
        e.items.enabled = false
    end

    e.farm = table.clone(s.farm)
    if not modes.has(mode, "AutoFarm") then
        e.farm.enabled = false
    end

    e.steal = table.clone(s.steal)
    if not modes.has(mode, "Steal") then
        e.steal.enabled = false
    end

    -- the effects and the limbs where the mode knows them, Time Erase where the mode has it
    if not modes.has(mode, "Statuses") or not modes.has(mode, "TimeErase") then
        local kinds = table.clone(s.statusKinds)
        for id in kinds do
            if (id == "timeErase" and not modes.has(mode, "TimeErase")) or (id ~= "timeErase" and not modes.has(mode, "Statuses")) then
                kinds[id] = false
            end
        end
        e.statusKinds = kinds
    end

    if not modes.has(mode, "Kit") then
        e.stand = false
        e.spec = false
    end

    if not modes.has(mode, "TeamCheck") then
        e.teamCheck = false
    end

    if not modes.has(mode, "Health") then
        e.healthBar = false
    end

    if not modes.has(mode, "Ping") then
        e.ping = false
    end

    if not modes.has(mode, "Weapon") then
        e.weapon = false
    end

    if not modes.has(mode, "LastSeen") then
        e.lastSeen = false
    end

    if not modes.has(mode, "Sounds") then
        e.sounds = false
    end

    if not modes.has(mode, "AutoStop") then
        e.aim.autoStop = "Off"
    end

    if not modes.has(mode, "Wallbang") then
        e.wallbang = false
        e.aim.autoFireThroughWalls = false
    end

    if not modes.has(mode, "Spectators") then
        e.spectators = false
    end

    if not modes.has(mode, "Clouds") then
        e.clouds = false
    end

    if not modes.has(mode, "Grenades") then
        e.grenades = false
        e.grenadePreview = false
    end

    if not modes.has(mode, "Aim") then
        e.aim.enabled = false
        e.aim.autoFire = false
    end

    if not modes.has(mode, "Bhop") then
        e.bhop.enabled = false
    end

    e.fullbright = table.clone(s.fullbright)
    if not modes.has(mode, "Fullbright") then
        e.fullbright.enabled = false
    end

    e.fly = table.clone(s.fly)
    if not modes.has(mode, "Fly") then
        e.fly.enabled = false
    end

    e.noclip = table.clone(s.noclip)
    if not modes.has(mode, "NoClip") then
        e.noclip.enabled = false
    end

    e.chams = table.clone(s.chams)
    if not modes.has(mode, "Players") then
        e.chams.enabled = false
    end

    e.crosshair = table.clone(s.crosshair)
    if not modes.has(mode, "Crosshair") then
        e.crosshair.enabled = false
    end

    e.nospread = table.clone(s.nospread)
    e.silentaim = table.clone(s.silentaim)
    if not modes.has(mode, "ShotHook") then
        e.nospread.enabled = false
        e.silentaim.enabled = false
    end

    e.townSilent = table.clone(s.townSilent)
    e.townWeapon = table.clone(s.townWeapon)
    if not modes.has(mode, "TownGun") then
        e.townSilent.enabled = false
        e.townWeapon.enabled = false
    end
    -- если включён townWeapon ESP — поднимаем общий флаг чтобы esp_players отрисовал weapon-строку
    if e.townWeapon.enabled then
        e.weapon = true
    end

    e.mvsSilent = table.clone(s.mvsSilent)
    if not modes.has(mode, "MvsGun") then
        e.mvsSilent.enabled = false
    end

    e.iaWeapon = table.clone(s.iaWeapon)
    if not modes.has(mode, "IaWeapon") then
        e.iaWeapon.enabled = false
    end
    if e.iaWeapon.enabled then
        e.weapon = true
    end

    -- whether any Silent Aim (Town/MVS/Strike) is on
    e.aim.silent = e.townSilent.enabled or e.mvsSilent.enabled or e.silentaim.enabled

    -- MVS: всегда проверять видимость (не стрелять через стены). Скорость наводки неактуальна — силент
    -- стреляет мгновенно, обычная наводка (если юзер её включит) должна тоже лочиться без лерпа.
    -- fullScreen тоже всегда — иначе цель за radius'ом круга не ловится и autofire молчит
    if mode == "Mvs" then
        e.aim.visibleOnly = true
        e.aim.speed = 1e6
        e.aim.fullScreen = true
    end

    -- Town при включённом Silent Aim: fullScreen, чтобы pickWorld ловил любую видимую цель на экране
    -- (как rage в CS), не только в кругу aim. visibleOnly оставляем пользовательский:
    -- ON — только видимые, OFF — wallbang через стены (сервер не проверяет видимость)
    if mode == "Town" and e.townSilent.enabled then
        e.aim.fullScreen = true
    end

    -- the aim by the mouse: the zones and the point the user picked, and it moves the mouse whether a silent aim is
    -- on or not (switching the aim off is how the user leaves the mouse alone). It is the table of the aim itself
    -- while no silent aim is on; with one, what follows changes the aim for the silent aims and the auto fire only
    e.mouseAim = e.aim
    if e.aim.silent then
        e.mouseAim = table.clone(e.aim)
        e.mouseAim.silent = false
        -- Silent/rage уважает пользовательский выбор hitbox-зон. Если юзер выключил голову и грудь,
        -- rage бьёт только в живот/руки/ноги. nearestPoint тоже оставляем как юзер выбрал
    end

    e.watermark = table.clone(s.watermark)
    e.reloadBar = table.clone(s.reloadBar)
    e.hotkeys = table.clone(s.hotkeys)
    if not modes.has(mode, "MvsGun") then
        e.reloadBar.enabled = false
    end

    return e
end

return settings
end

__modules["sounds"] = function(require)
-- the sounds the server told about, kept for a moment and marked where they were heard
-- in Blox Strike the server stops telling where a character is once the user cannot see it, but goes on telling
-- about the sounds in earshot: a step with its place gives away somebody who is walking out of sight
-- draws through the layer and the projection it is given; checked by tests/sounds_test.lua
local num = require("./num")

local sounds = {}

sounds.lifetime = 2.5       -- seconds a mark stays
sounds.max_count = 48       -- marks kept at once; a firefight makes sounds faster than they fade

local Sounds = {}
Sounds.__index = Sounds

function sounds.new()
    return setmetatable({ list = {} }, Sounds)
end

-- how visible a mark is at that age: whole for the first half of its life, then fading to nothing
function sounds.opacity(age)
    local half = sounds.lifetime * 0.5
    if age <= half then
        return 1
    end

    if age >= sounds.lifetime then
        return 0
    end

    return 1 - (age - half) / half
end

-- how a sound is written: a step is the one worth a word of its own, the rest go by the name the game gives their kind
local function label(class)
    if class == "FloorSounds" then
        return "step"
    end

    if type(class) == "string" and class ~= "" then
        return class
    end

    return "sound"
end

-- a sound heard at that place at that time; the newest is the last in the list
function Sounds:push(x, y, z, class, name, now)
    if not num.plausible(x, y, z) then
        return
    end

    local list = self.list
    if #list >= sounds.max_count then
        table.remove(list, 1)
    end

    table.insert(list, { x = x, y = y, z = z, label = label(class), name = name, at = now })
end

function Sounds:clear()
    table.clear(self.list)
end

-- forgets the marks whose time is over and draws the rest; the distance is written while the user has a character
function Sounds:draw(haveLocal, localX, localY, localZ, screenW, screenH, project, d, now)
    local list = self.list

    -- the oldest are first
    while #list > 0 and now - list[1].at >= sounds.lifetime do
        table.remove(list, 1)
    end

    for _, sound in list do
        local opacity = sounds.opacity(now - sound.at)
        if opacity <= 0 then
            continue
        end

        local pixelX, pixelY, visible = project(sound.x, sound.y, sound.z)
        if not visible or not num.finite(pixelX) or not num.finite(pixelY) then
            continue
        end

        if pixelX < -100 or pixelY < -100 or pixelX > screenW + 100 or pixelY > screenH + 100 then
            continue
        end

        pixelX = math.floor(pixelX)
        pixelY = math.floor(pixelY)

        local text = sound.label
        if haveLocal then
            local dx, dy, dz = sound.x - localX, sound.y - localY, sound.z - localZ
            text = string.format("%s %.0f st", text, math.sqrt(dx * dx + dy * dy + dz * dz))
        end

        d.dot(pixelX, pixelY, 4, 0, 0, 0, opacity)
        d.dot(pixelX, pixelY, 3, 255, 170, 60, opacity)
        d.textCentered(pixelX, pixelY + 6, 255, 170, 60, text, opacity)
    end
end

return sounds
end

__modules["spectators"] = function(require)
-- who watches the user: Blox Strike tells for every player how many are watching him (the attribute Spectators) and
-- whether he is watching somebody himself (IsSpectating), but not whom. Who watches whom is worked out from how
-- these change: one who has just started watching, at the moment one count went up, watches that one; one count going
-- down while another goes up is somebody who went over. When that cannot be told apart (two watched one player and
-- one of them moved), both are named as ones that may be. The count itself is always the game's
-- pure logic, checked by tests/spectators_test.lua
local spectators = {}

local margin = 16           -- pixels from the right edge of the screen
local top = 120             -- pixels from the top: below the buttons of Roblox

local Watch = {}
Watch.__index = Watch

function spectators.new()
    return setmetatable({
        target = {},        -- one watching -> the one he is surely watching
        maybe = {},         -- one watching whose target is not known -> set of the ones he may be watching
        names = {},
        counts = {},
    }, Watch)
end

local function sorted(set, names)
    local list = {}
    for key in set do
        table.insert(list, names[key])
    end
    table.sort(list)
    return list
end

-- players: a list of { key, name, watching (boolean), watchers (number or nil) }, read on every frame
function Watch:update(players)
    local watching = {}
    local counts = {}
    for _, player in players do
        self.names[player.key] = player.name
        if player.watching == true then
            watching[player.key] = true
        end
        if type(player.watchers) == "number" and player.watchers >= 0 then
            counts[player.key] = player.watchers
        end
    end
    self.counts = counts

    -- whoever stopped watching or left watches nobody; whoever was watched and is gone has nobody watching him
    for one, watched in self.target do
        if not watching[one] or counts[watched] == nil or one == watched then
            self.target[one] = nil
        end
    end
    for one in self.maybe do
        if not watching[one] then
            self.maybe[one] = nil
        end
    end

    -- a player with fewer watching than the script holds him for: one of those left, and nobody can tell which;
    -- all of them are let loose and settled again below
    local held = {}
    for one, watched in self.target do
        held[watched] = held[watched] or {}
        table.insert(held[watched], one)
    end
    for watched, ones in held do
        if #ones > counts[watched] then
            for _, one in ones do
                self.target[one] = nil
                self.maybe[one] = nil
            end
            held[watched] = nil
        end
    end

    -- how many each one has that the script does not know of yet, and who could be them
    local short = {}
    local shortTotal = 0
    for watched, count in counts do
        local missing = count - (if held[watched] then #held[watched] else 0)
        if missing > 0 then
            short[watched] = missing
            shortTotal += missing
        end
    end

    local loose = {}
    for one in watching do
        if self.target[one] == nil then
            -- what was possible before stays possible, as far as it still is
            local possible = {}
            local before = self.maybe[one]
            for watched in short do
                if watched ~= one and (before == nil or before[watched]) then
                    possible[watched] = true
                end
            end

            -- nothing left of before: the one moved, anywhere that gained
            if next(possible) == nil then
                for watched in short do
                    if watched ~= one then
                        possible[watched] = true
                    end
                end
            end

            self.maybe[one] = possible
            table.insert(loose, one)
        end
    end

    -- settled for sure only when the count of the ones not known adds up to the ones without a target: with somebody
    -- watching what the game does not count (a bot), any guess could be wrong
    if #loose ~= shortTotal then
        return
    end

    local changed = true
    while changed do
        changed = false

        for watched, missing in short do
            if missing <= 0 then
                continue
            end

            -- exactly as many could be on that one as it misses: it is them
            local could = {}
            for _, one in loose do
                if self.target[one] == nil and self.maybe[one][watched] then
                    table.insert(could, one)
                end
            end

            if #could == missing then
                for _, one in could do
                    self.target[one] = watched
                    self.maybe[one] = nil
                end
                short[watched] = 0
                changed = true
            end
        end

        -- one who can only be on one place is there
        for _, one in loose do
            local possible = self.maybe[one]
            if self.target[one] == nil and possible ~= nil then
                local only, count = nil, 0
                for watched in possible do
                    if short[watched] > 0 then
                        only = watched
                        count += 1
                    end
                end

                if count == 1 then
                    self.target[one] = only
                    self.maybe[one] = nil
                    short[only] -= 1
                    changed = true
                end
            end
        end
    end
end

-- the ones surely watching that player, and the ones that may be; both lists of names, sorted
function Watch:of(key)
    local sure, maybe = {}, {}
    for one, watched in self.target do
        if watched == key then
            sure[one] = true
        end
    end

    if (self.counts[key] or 0) > 0 then
        for one, possible in self.maybe do
            if possible[key] then
                maybe[one] = true
            end
        end
    end

    return sorted(sure, self.names), sorted(maybe, self.names)
end

-- how many the game says are watching that player
function Watch:count(key)
    return self.counts[key] or 0
end

-- the list at the right edge of the screen: how many, then the names; a name that may be is marked
function spectators.draw(d, screenW, screenH, count, sure, maybe)
    if count <= 0 then
        return
    end

    local y = math.min(top, screenH)
    local function line(text, r, g, b)
        d.text(screenW - margin - d.textWidth(text), y, r, g, b, text)
        y += d.line_height
    end

    line("Spectators: " .. count, 255, 255, 255)
    for _, name in sure do
        line(name, 255, 190, 90)
    end
    for _, name in maybe do
        line(name .. "?", 170, 170, 180)
    end
end

return spectators
end

__modules["status"] = function(require)
-- status effects of a character, as Your Bizarre Adventure marks them: while an effect lasts,
-- particle emitters named "<Effect> FX" sit right in the UpperTorso (seen in a dump: "Bleed FX" on a bleeding player);
-- a pose is told by an emitter in the HumanoidRootPart
-- how long an effect still has to go is not kept anywhere it could be read
-- pure logic, checked by tests/status_test.lua; a port of rbx/status.h of the external
local status = {}

status.max_name = 32    -- longer than any sane effect name
status.max_count = 4    -- per character

local suffix = " FX"

-- the effect an emitter of that name stands for, empty when the emitter is something else
function status.fromEmitter(name)
    -- burning does not follow the naming of the other effects: "OnFire" with "OnFireWisps" and "OnFireSparks",
    -- seen on two burning players and gone from one of them forty seconds later
    if name == "OnFire" then
        return "Burn"
    end

    if #name <= #suffix or #name > status.max_name + #suffix then
        return ""
    end

    if string.sub(name, -#suffix) ~= suffix then
        return ""
    end

    return string.sub(name, 1, #name - #suffix)
end

-- the same for an emitter that sits right in the HumanoidRootPart
-- that part always holds the auras of the stand, so there is no rule by the shape of the name here, only names seen:
-- "Menacing" is on a player who is posing, and a posing player heals faster
function status.fromRootEmitter(name)
    if name == "Menacing" then
        return "Pose"
    end

    return ""
end

-- the effects behind the emitters of the torso and of the root part, each once, in the order met
function status.collect(torsoEmitters, rootEmitters)
    local effects = {}

    local function add(effect)
        if effect == "" or #effects >= status.max_count or table.find(effects, effect) ~= nil then
            return
        end

        table.insert(effects, effect)
    end

    for _, name in torsoEmitters do
        add(status.fromEmitter(name))
    end

    if rootEmitters ~= nil then
        for _, name in rootEmitters do
            add(status.fromRootEmitter(name))
        end
    end

    return effects
end

-- "Bleed", "Burn" and "Pose" were seen in the game; "Poison" is a guess at the name and costs nothing when wrong,
-- since an effect that is not listed is shown under the name the game gives it
local looks = {
    Bleed = { text = "Bleeding", r = 255, g = 70, b = 70 },
    Poison = { text = "Poisoned", r = 170, g = 100, b = 240 },
    Burn = { text = "Burning", r = 255, g = 150, b = 40 },
    Pose = { text = "Healing", r = 90, g = 230, b = 110 },
    Shield = { text = "Invulnerable", r = 120, g = 205, b = 255 },
}

-- how an effect is written on the screen
function status.look(effect)
    return looks[effect] or { text = effect, r = 255, g = 215, b = 90 }
end

-- what the menu shows or hides, several at once, in its order: Time Erase (see players.lua), the effects the game
-- names, the limbs, and every other effect under the name the game gives it
status.kinds = {
    { id = "timeErase", label = "Time Erase" },
    { id = "bleed", label = "Кровотечение" },
    { id = "poison", label = "Яд" },
    { id = "burn", label = "Горение" },
    { id = "pose", label = "Лечение (поза)" },
    { id = "limbs", label = "Конечности" },
    { id = "other", label = "Прочие эффекты" },
}

local kindOfEffect = { Bleed = "bleed", Poison = "poison", Burn = "burn", Pose = "pose" }

-- the kind an effect is shown under
function status.kindOf(effect)
    return kindOfEffect[effect] or "other"
end

-- every kind switched on: what the settings start with
function status.allKinds()
    local kinds = {}
    for _, kind in status.kinds do
        kinds[kind.id] = true
    end

    return kinds
end

-- whether anything read in the slow pass is wanted: the effects and the limbs (Time Erase is read on every frame)
function status.wantsEffects(kinds)
    if kinds == nil then
        return false
    end

    for _, kind in status.kinds do
        if kind.id ~= "timeErase" and kinds[kind.id] == true then
            return true
        end
    end

    return false
end

return status
end

__modules["steal_egg_data"] = function(require)
-- Steal an Egg: карта областей и баз. Собрано из tools/steal_egg_probe.lua (один прогон, может нуждаться
-- в обновлении если игра перенесёт зоны). Координаты — EggPoint каждой области (место где спавнятся яйца)
-- и SpawnPoint каждого Plot (сюда прилетаем, чтобы сдать яйцо на базу)
return {
    areas = {
        { name = "Forest",              x = 596.6,  y = 70.5, z = -318.9 },
        { name = "Lake",                x = 743.3,  y = 69.1, z = -420.0 },
        { name = "Desert",              x = 949.8,  y = 67.9, z = -314.6 },
        { name = "Jungle",              x = 1177.2, y = 68.2, z = -429.4 },
        { name = "Snow",                x = 1489.2, y = 76.8, z = -303.8 },
        { name = "Volcano",             x = 1864.7, y = 68.6, z = -415.4 },
        { name = "Abyss Ocean",         x = 2268.4, y = 71.7, z = -311.5 },
        { name = "Prehistoric",         x = 2782.1, y = 67.7, z = -416.2 },
        { name = "Cosmic",              x = 3393.0, y = 75.3, z = -314.9 },
        { name = "Cherry Blossom",      x = 4020.7, y = 64.9, z = -410.3 },
        { name = "Titan Temple",        x = 4791.5, y = 80.5, z = -311.1 },
        { name = "Light Dark",          x = 5655.4, y = 77.9, z = -312.8 },
        { name = "Enchanted Forest",    x = 6686.9, y = 74.1, z = -332.2 },
    },
    plots = {
        { name = "Plot 1", x = 471.7, y = 73.9, z = -364.4 },
        { name = "Plot 2", x = 471.7, y = 73.9, z = -283.4 },
        { name = "Plot 3", x = 471.7, y = 73.9, z = -202.4 },
        { name = "Plot 4", x = 471.7, y = 73.9, z = -444.0 },
        { name = "Plot 5", x = 472.7, y = 73.9, z = -523.5 },
        { name = "Plot 6", x = 522.3, y = 73.9, z = -230.4 },
        { name = "Plot 7", x = 522.3, y = 73.9, z = -497.6 },
    },
}
end

__modules["steal_farm"] = function(require)
-- Auto-steal для Steal an Egg: ищет ближайший Enabled Steal-prompt в выбранных зонах, глайдер летит туда,
-- fireproximityprompt для кражи. Когда клиент получает EggWorld/FieldEggCarry — несёт яйцо на выбранный Plot.
-- После FieldEggRedeemVerdict — заново на steal.
--
-- Prompt'ы разбросаны по Workspace.SmartPromptPart (93 штуки, тэги obj='Egg' act='Steal'). Чтобы различать
-- какая зона — координаты сравниваются с переданными в areas (ближайшая зона в радиусе area_radius).
-- Если prompt сейчас Disabled (нет яйца) — пропускаем. Фильтр по выбранным зонам: name ∈ settings.steal.zones
--
-- state машина:
--   idle          — ждём включения чего-нибудь, что бы делать
--   seeking       — глайдер летит к выбранному prompt
--   stealing      — fireproximityprompt отправлен, ждём hold и смотрим carry
--   carrying      — яйцо в руках, глайдер летит на Plot
--   delivering    — доехали до plot, ждём redeem
--
-- pure logic: все stop-условия выражены через deps-колбэки
local steal_farm = {}

local Farm = {}
Farm.__index = Farm

-- deps:
--   moveTo(x, y, z)                запустить глайдер к точке
--   arrived() -> boolean           глайдер дошёл
--   stopMoving()                    отменить глайдер
--   firePrompt(prompt)              fireproximityprompt(prompt)
--   isCarrying() -> boolean        мы сейчас несём яйцо (следим за EggWorld/FieldEggCarry)
--   areas                          массив { name, x, y, z } — зоны фарма
--   enabledPrompts() -> list       актуальные Enabled Steal prompt'ы в мире, каждый { prompt, x, y, z }
--
-- settings:
--   zones                          { [name] = true }, какие зоны разрешены
--   myPlot                         { x, y, z } или nil — куда нести яйца
function steal_farm.new(deps)
    return setmetatable({
        deps = deps,
        state = "idle",
        target = nil,           -- { prompt, x, y, z, area }
        since = 0,
        settleUntil = 0,        -- для state="settling": до какого времени ждём
        pauseUntil = 0,         -- глобальный cooldown между циклами (анти-античит)
        taken = 0,
        tried = {},             -- prompt -> last-tried time, чтобы не долбить ту же точку сразу
    }, Farm)
end

local arrive_radius = 10            -- студов: прибытие на точку prompt'а
local plot_radius = 15              -- студов: приход на базу считается delivery
local max_steal_wait = 4            -- секунд ожидания carry после fire — иначе пробуем снова
local max_deliver_wait = 10         -- секунд в состоянии delivering — иначе возвращаемся на steal
local retry_cooldown = 3            -- секунд не трогать один и тот же prompt после неудачи
local hover_height = 10             -- студов над prompt'ом: анти-граунд (античит палит касание пола при краже)
local settle_base = 0.8             -- секунд ждём после прибытия перед нажатием E (анти-бот ритм)
local settle_jitter = 0.6           -- + случайно 0..0.6 с
local between_base = 2.5            -- секунд обязательной паузы между завершением цикла и новым seek
local between_jitter = 2.5          -- + 0..2.5 с
-- итого между кражами в среднем ~4-6 сек: похоже на реального игрока, не на спам-бота

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function distToArea(x, z, area)
    local dx, dz = x - area.x, z - area.z
    return math.sqrt(dx * dx + dz * dz)
end

local function nearestAreaName(x, z, areas, area_radius)
    local best, bestD = nil, area_radius
    for _, a in areas do
        local d = distToArea(x, z, a)
        if d < bestD then
            bestD = d
            best = a.name
        end
    end
    return best
end

function Farm:stop()
    if self.deps.stopMoving ~= nil then self.deps.stopMoving() end
    self.state = "idle"
    self.target = nil
end

-- одна итерация, вызывается каждый кадр из main.lua. meX/Z — где игрок сейчас
function Farm:update(now, zonesSelected, myPlot, meX, meY, meZ)
    if not finite(meX) then
        self:stop()
        return
    end

    -- 1. если несём яйцо — летим на Plot и ждём redeem
    if self.deps.isCarrying() then
        if myPlot == nil then
            -- куда нести? Ждём пока юзер выставит
            self:stop()
            return
        end
        if self.state ~= "carrying" and self.state ~= "delivering" then
            self.state = "carrying"
            self.since = now
            self.deps.moveTo(myPlot.x, myPlot.y, myPlot.z)
        elseif self.state == "carrying" then
            local dx, dz = myPlot.x - meX, myPlot.z - meZ
            if dx * dx + dz * dz <= plot_radius * plot_radius then
                self.state = "delivering"
                self.since = now
                self.deps.stopMoving()
            end
        elseif self.state == "delivering" then
            -- таймаут — вдруг линия чуть в стороне, ещё раз направим на plot
            if now - self.since >= max_deliver_wait then
                self:stop()
            end
        end
        return
    end

    -- 2. не несём — если недавно был carry, значит redeem прошёл; взводим паузу перед следующим циклом
    if self.state == "carrying" or self.state == "delivering" then
        self.taken += 1
        self.state = "idle"
        self.target = nil
        self.pauseUntil = now + between_base + math.random() * between_jitter
    end

    -- 3. если в стадии steal — ждём carry (прожим E на prompt был); таймаут — пробуем другой
    if self.state == "stealing" then
        if now - self.since >= max_steal_wait then
            if self.target ~= nil then
                self.tried[self.target.prompt] = now
            end
            self.state = "idle"
            self.target = nil
        else
            return
        end
    end

    -- 4. если глайдер летит к prompt'у — ждём прибытия, после arrive переходим в settle
    if self.state == "seeking" and self.target ~= nil then
        local t = self.target
        if t.prompt == nil or t.prompt.Enabled == false or t.prompt.Parent == nil then
            -- prompt сдох по пути — ищем новый
            self.tried[t.prompt] = now
            self:stop()
        else
            local dx, dz = t.x - meX, t.z - meZ
            if dx * dx + dz * dz <= arrive_radius * arrive_radius then
                -- settle: прибыли, ждём settle_base..+jitter секунд перед нажатием E (анти-ритм)
                self.state = "settling"
                self.since = now
                self.settleUntil = now + settle_base + math.random() * settle_jitter
            end
        end
        return
    end

    -- 4a. settling — долетел, висим паузу, потом жмём E
    if self.state == "settling" and self.target ~= nil then
        local t = self.target
        if t.prompt == nil or t.prompt.Enabled == false or t.prompt.Parent == nil then
            self.tried[t.prompt] = now
            self:stop()
            return
        end
        if now >= self.settleUntil then
            self.deps.firePrompt(t.prompt)
            self.state = "stealing"
            self.since = now
        end
        return
    end

    -- 5. idle — глобальный cooldown? ждём; иначе ищем ближайший Enabled Steal prompt в выбранных зонах
    if now < self.pauseUntil then
        return
    end
    local prompts = self.deps.enabledPrompts()
    if type(prompts) ~= "table" or #prompts == 0 then
        return
    end

    local best, bestD, bestArea = nil, math.huge, nil
    for _, p in prompts do
        if self.tried[p.prompt] == nil or (now - self.tried[p.prompt]) >= retry_cooldown then
            local area = nearestAreaName(p.x, p.z, self.deps.areas, 60)
            if area ~= nil and (zonesSelected == nil or zonesSelected[area] == true) then
                local dx, dz = p.x - meX, p.z - meZ
                local d2 = dx * dx + dz * dz
                if d2 < bestD then
                    bestD = d2
                    best = p
                    bestArea = area
                end
            end
        end
    end

    if best == nil then
        return
    end

    -- target.y сразу приподнят на hover_height — чтобы персонаж не касался пола когда долетит
    self.target = { prompt = best.prompt, x = best.x, y = best.y + hover_height, z = best.z, area = bestArea }
    self.state = "seeking"
    self.since = now
    self.deps.moveTo(self.target.x, self.target.y, self.target.z)
end

-- доступно снаружи: пока settle или stealing висят на точке, main.lua зовёт hold() каждый кадр чтобы persona не упал
function Farm:hoverTarget()
    if (self.state == "stealing" or self.state == "settling") and self.target ~= nil then
        return self.target.x, self.target.y, self.target.z
    end
    return nil
end

return steal_farm
end

__modules["steal_mover"] = function(require)
-- Движок перемещения для Steal an Egg: один `moveTo(x,y,z)` строит безопасный путь (Z-detour)
-- через коридор `safeZ` вне guard-полосы Z∈[-440..-290], последовательно ведёт по waypoint'ам.
-- Режимы: TP (3 фазы: up→horiz→down, async), Walk (Humanoid.WalkSpeed + MoveTo), Glide (глайдер).
--
-- Deps:
--   stealSettings()         → table с полями moveMode/walkSpeed/speed/tp*/dropDelay/detour/safeZ
--   humanoid()              → Humanoid или nil
--   rootPart()              → HumanoidRootPart или nil
--   env                     → { CFrame, Vector3 }
--   task                    → { spawn, wait }
--   walker                  → glider с :goTo(x,y,z) / :stop() / :phase() → "arrived"
--   onWalkSpeedChange(new)  → колбэк когда в Walk меняем WalkSpeed (чтобы main.lua знал что savedWalkSpeed сдвинулся)

local STRIP_MIN_Z = -440
local STRIP_MAX_Z = -290

local Mover = {}
Mover.__index = Mover

function Mover.new(deps)
    return setmetatable({
        deps = deps,
        queue = {},
        arrivedFinal = true,
        target = nil,           -- активная цель { x, y, z }
        tpToken = 0,
        tpArrived = false,
        savedWalkSpeed = nil,
    }, Mover)
end

local function inStrip(z)
    return z >= STRIP_MIN_Z and z <= STRIP_MAX_Z
end

function Mover:_buildPath(fromX, fromY, fromZ, toX, toY, toZ)
    local s = self.deps.stealSettings()
    if not s.detour then
        return { { x = toX, y = toY, z = toZ } }
    end
    local safeZ = s.safeZ or -200
    local path = {}
    if inStrip(fromZ) then
        table.insert(path, { x = fromX, y = fromY, z = safeZ })
    end
    if inStrip(toZ) then
        table.insert(path, { x = toX, y = fromY, z = safeZ })
    end
    table.insert(path, { x = toX, y = toY, z = toZ })
    return path
end

function Mover:_setRootCFrame(x, y, z)
    local root = self.deps.rootPart()
    if root == nil then return end
    root.CFrame = self.deps.env.CFrame.new(x, y, z)
    root.AssemblyLinearVelocity = self.deps.env.Vector3.new(0, 0, 0)
end

function Mover:_startTeleport(x, y, z)
    self.tpToken += 1
    local myToken = self.tpToken
    self.tpArrived = false
    local task_ = self.deps.task
    task_.spawn(function()
        local s = self.deps.stealSettings()
        local upH = s.tpUpHeight or 30
        local upD = (s.tpUpDelay or 150) / 1000
        local midD = (s.tpDelay or 180) / 1000
        local downD = (s.tpDownDelay or 250) / 1000
        local dropD = (s.dropDelay or 50) / 1000
        local root = self.deps.rootPart()
        if root == nil then return end
        local p = root.Position
        self:_setRootCFrame(p.X, p.Y + upH, p.Z)
        task_.wait(upD)
        if myToken ~= self.tpToken then return end
        root = self.deps.rootPart()
        if root == nil then return end
        local upY = root.Position.Y
        self:_setRootCFrame(x, upY, z)
        task_.wait(midD)
        if myToken ~= self.tpToken then return end
        self:_setRootCFrame(x, y, z)
        task_.wait(downD)
        if myToken ~= self.tpToken then return end
        task_.wait(dropD)
        if myToken ~= self.tpToken then return end
        self.tpArrived = true
    end)
end

function Mover:_singleMoveTo(x, y, z)
    self.target = { x = x, y = y, z = z }
    local s = self.deps.stealSettings()
    local mode = s.moveMode or "TP"
    if mode == "Walk" then
        local h = self.deps.humanoid()
        if h ~= nil then
            if self.savedWalkSpeed == nil then
                self.savedWalkSpeed = h.WalkSpeed
            end
            local wanted = s.walkSpeed or 60
            if h.WalkSpeed ~= wanted then
                h.WalkSpeed = wanted
            end
            pcall(function() h:MoveTo(self.deps.env.Vector3.new(x, y, z)) end)
        end
    elseif mode == "Glide" then
        self.deps.walker:goTo(x, y, z)
    else
        self:_startTeleport(x, y, z)
    end
end

function Mover:_singleArrived()
    local s = self.deps.stealSettings()
    local mode = s.moveMode or "TP"
    if mode == "Walk" then
        if self.target == nil then return true end
        local root = self.deps.rootPart()
        if root == nil then return false end
        local p = root.Position
        local dx, dz = p.X - self.target.x, p.Z - self.target.z
        return dx * dx + dz * dz < 25
    elseif mode == "Glide" then
        return self.deps.walker:phase() == "arrived"
    else
        return self.tpArrived
    end
end

function Mover:moveTo(x, y, z)
    local root = self.deps.rootPart()
    if root == nil then return end
    local p = root.Position
    self.queue = self:_buildPath(p.X, p.Y, p.Z, x, y, z)
    self.arrivedFinal = false
    local first = self.queue[1]
    self:_singleMoveTo(first.x, first.y, first.z)
end

function Mover:arrived()
    if self.arrivedFinal then return true end
    if not self:_singleArrived() then return false end
    table.remove(self.queue, 1)
    if #self.queue == 0 then
        self.arrivedFinal = true
        return true
    end
    local nx = self.queue[1]
    self:_singleMoveTo(nx.x, nx.y, nx.z)
    return false
end

function Mover:stop()
    self.queue = {}
    self.arrivedFinal = true
    local s = self.deps.stealSettings()
    local mode = s.moveMode or "TP"
    if mode == "Walk" then
        local h = self.deps.humanoid()
        local root = self.deps.rootPart()
        if h ~= nil and root ~= nil then
            pcall(function() h:MoveTo(root.Position) end)
        end
        if h ~= nil and self.savedWalkSpeed ~= nil then
            h.WalkSpeed = self.savedWalkSpeed
        end
        self.savedWalkSpeed = nil
    elseif mode == "Glide" then
        self.deps.walker:stop()
    else
        self.tpToken += 1
        self.tpArrived = false
    end
    self.target = nil
end

return Mover
end

__modules["strike_move"] = function(require)
-- finds what the bhop needs of Blox Strike among the tables of the game; known from the code of the game itself
-- (tools/strike_probe4.lua):
--   the runtime of its movement (MovementV2.Client.Runtime), one for the whole session; its _state is the state of
--   the user after the last tick: OnGround, MovementMode, PreviousButtons (the buttons of the last command);
--   the table of Controllers.CharacterController.LocalCharacter, whose jump(pressed) is what the handler of the jump
--   key calls when the key goes down and up;
--   the bits of a movement command (MovementV2.Buttons), for checking that the game follows the switch;
--   the table of Controllers.InventoryController (tools/strike_probe10.lua), for the weapon in the hands: its
--   getCurrentEquipped breaks the module when an executor calls it, so it is never called; the loadout is what
--   peekCurrentEquippedForMovement holds on to, and the weapon its CurrentEquipped, read raw
-- nothing of the game is replaced: the state is read, and the switch is called the way the game calls it
-- takes the functions of the executor as a table, so tests/strike_move_test.lua runs it without one
local strike_move = {}

local yield_every = 20000       -- tables looked at between two pauses: a game has two hundred thousand of them

local function isFunction(value)
    return type(value) == "function"
end

-- looks for all of it in a thread of its own: the frame does not wait
-- onFound({ state = function, setJump = function or nil, setMove = function or nil, jumpDown = function or nil,
-- weapon = function or nil }) or onMissing() is called once; weapon() gives the object of the weapon in the hands as the
-- game keeps it (see weapon.lua), nil when nothing is; setMove(x, z) tells the character of the user to walk that way,
-- a direction in the world,
-- and gives back whether there was a character to tell:
-- the same method the controls of Roblox tell it the keys with (Classes.Character:MoveFunction), reached through what
-- the jump of the controller holds on to
-- the state alone is worth having: the way of a grenade starts from it. Without the switch of the jump there is no
-- bhop, and setJump is nil
function strike_move.find(env, onFound, onMissing)
    env.task.spawn(function()
        local ok, objects = pcall(function()
            return env.getgc(true)
        end)

        if not ok or type(objects) ~= "table" then
            onMissing()
            return
        end

        local runtime = nil
        local controller = nil
        local buttons = nil
        local inventory = nil
        local checked = 0

        local function look(object)
            if type(rawget(object, "_remotePresentations")) == "table" and type(rawget(object, "_remotePresentationPool")) == "table" then
                -- a runtime that was stopped may still lie around; the one that runs wins
                if runtime == nil or rawget(object, "_started") == true then
                    runtime = object
                end
            elseif isFunction(rawget(object, "jump")) and isFunction(rawget(object, "crouch"))
                and isFunction(rawget(object, "PlantBomb")) and isFunction(rawget(object, "CancelBombPlant")) then
                controller = object
            elseif isFunction(rawget(object, "has")) and isFunction(rawget(object, "with")) and rawget(object, "Scoped") ~= nil
                and rawget(object, "Jump") ~= nil then
                buttons = object
            elseif isFunction(rawget(object, "peekCurrentEquippedForMovement")) and isFunction(rawget(object, "getCurrentEquipped")) then
                inventory = object
            end
        end

        for _, object in objects do
            if type(object) == "table" then
                checked += 1

                -- a table may refuse to be read; that is not the one looked for
                pcall(look, object)

                if checked % yield_every == 0 then
                    env.task.wait()
                end
            end
        end

        if runtime == nil then
            onMissing()
            return
        end

        local jump = if controller ~= nil then rawget(controller, "jump") else nil

        -- whether the jump is down in the buttons of a command: asked of the game, which alone knows how it packs them
        local jumpDown = nil
        if buttons ~= nil then
            local has = rawget(buttons, "has")
            local bit = rawget(buttons, "Jump")
            jumpDown = function(mask)
                local okHas, down = pcall(has, mask, bit)
                return okHas and down == true
            end
        end

        -- the character of the user right now: a life is a new one, the jump of the controller holds on to the current
        local function character()
            local ok, values = pcall(env.getupvalues, jump)
            if not ok or type(values) ~= "table" then
                return nil
            end

            for _, value in values do
                if type(value) == "table" then
                    local okMove, move = pcall(function()
                        return value.MoveFunction
                    end)

                    if okMove and type(move) == "function" then
                        return value
                    end
                end
            end

            return nil
        end

        -- the weapon in the hands: the loadout is a new one every round, so it is read anew every time
        local peek = if inventory ~= nil then rawget(inventory, "peekCurrentEquippedForMovement") else nil
        local function weapon()
            local okUp, values = pcall(env.getupvalues, peek)
            if not okUp or type(values) ~= "table" then
                return nil
            end

            for _, value in values do
                if type(value) == "table" then
                    return rawget(value, "CurrentEquipped")
                end
            end

            return nil
        end

        onFound({
            state = function()
                return rawget(runtime, "_state")
            end,
            weapon = if peek ~= nil then weapon else nil,
            setMove = if jump ~= nil then function(x, z)
                local walker = character()
                if walker == nil then
                    return false
                end

                -- false: a direction in the world, which the game turns by the camera itself
                walker:MoveFunction(env.Vector3.new(x, 0, z), false)
                return true
            end else nil,
            setJump = if jump ~= nil then function(pressed)
                jump(pressed)
            end else nil,
            jumpDown = jumpDown,
        })
    end)
end

return strike_move
end

__modules["strike_net"] = function(require)
-- finds a packet of Blox Strike among the tables of the game
-- the game talks to its server through packet objects of its own (ReplicatedStorage.Database.Security.Network);
-- every one has Listen(callback), which hands the decoded content of what the server sent to whoever asks, and gives
-- back a function that takes the listener away. A packet is told by the remote its functions hold on to
-- only listening is done through it: nothing is sent and nothing of the game is replaced
-- takes the functions of the executor as a table, so tests/strike_net_test.lua runs it without one
local strike_net = {}

local yield_every = 20000       -- tables looked at between two pauses: a game has a hundred thousand of them

local function isFunction(value)
    return type(value) == "function"
end

-- the full name of the remote a packet goes through, nil for what is not a packet
local function remoteName(env, object)
    local name = nil

    pcall(function()
        for _, value in env.getupvalues(object.Listen) do
            local kind = type(value)
            if kind == "userdata" or kind == "table" then
                local found = nil
                pcall(function()
                    if value:IsA("BaseRemoteEvent") then
                        found = value:GetFullName()
                    end
                end)

                if found ~= nil then
                    name = found
                    break
                end
            end
        end
    end)

    return name
end

-- looks for the packets whose remotes have those full names, all in one pass over the tables of the game, in a
-- thread of its own: the frame does not wait for it
-- onDone({ [name] = packet }) is called once; a packet that is not there is not in the table
function strike_net.findMany(env, wantedNames, onDone)
    env.task.spawn(function()
        local found = {}

        local ok, objects = pcall(function()
            return env.getgc(true)
        end)

        if not ok or type(objects) ~= "table" then
            onDone(found)
            return
        end

        local wanted = {}
        local left = 0
        for _, name in wantedNames do
            if not wanted[name] then
                wanted[name] = true
                left += 1
            end
        end

        local checked = 0
        for _, object in objects do
            if left == 0 then
                break
            end

            if type(object) == "table" then
                checked += 1

                local okGet, listen = pcall(rawget, object, "Listen")
                if okGet and isFunction(listen) and isFunction(rawget(object, "Connect")) and isFunction(rawget(object, "SendToProximity")) then
                    local name = remoteName(env, object)
                    if name ~= nil and wanted[name] and found[name] == nil then
                        found[name] = object
                        left -= 1
                    end
                end

                if checked % yield_every == 0 then
                    env.task.wait()
                end
            end
        end

        onDone(found)
    end)
end

-- the same for one packet: onFound(packet) or onMissing() is called once
function strike_net.find(env, wantedName, onFound, onMissing)
    strike_net.findMany(env, { wantedName }, function(found)
        local packet = found[wantedName]
        if packet ~= nil then
            onFound(packet)
        else
            onMissing()
        end
    end)
end

return strike_net
end

__modules["strike"] = function(require)
-- what Blox Strike tells about its characters; found out from the code of the game itself (tools/strike_probe.lua)
-- the game builds every character on the client: a model in Workspace.Characters, named after the player, without
-- a Humanoid, moved on every frame to the pose the server sent for it. The server leaves out the characters the user
-- cannot see: the game moves the models of those to ReplicatedStorage._PVS_CulledCharacters and stops moving them,
-- so all that is known of such a character is where it was last
-- the rest is in attributes: of the player (Team, Ping, Invincible, CurrentEquipped as JSON) and of the model
-- (Health, MaxHealth, Dead; for a character run by the game also Bot, Team, CombatantId)
-- reads the game through the objects it is given, so tests/strike_test.lua runs it on stand-ins
local hitbox = require("./hitbox")
local num = require("./num")

local strike = {}

local none = {}     -- the statuses of every record: this game has none; shared, never written to; so are the parts before a pass

local Source = {}
Source.__index = Source

-- deps: workspace, replicatedStorage, players (the service), localPlayer, decode(text) -> table or nil (JSON)
function strike.new(deps)
    return setmetatable({
        deps = deps,
        records = {},       -- model -> record
        list = {},          -- the same records in a row, for the frame
        own = {},           -- the models of the user himself: nobody to draw, and not a wall for a look from the camera
        fences = {},        -- what of the map stops a ray and cannot be seen: not a wall for a look either
        culledFolder = nil,
    }, Source)
end

-- a record has what the esp reads from a record of players.lua, and what only this game tells
local function newRecord(model)
    return {
        model = model,
        key = model,            -- a respawn is a new model, and a new health track with it
        name = model.Name,
        root = nil,
        bot = false,
        team = nil,
        ping = nil,
        weapon = "",
        equipped = nil,         -- the text the weapon was decoded from, so that it is decoded once
        shielded = false,
        hiddenSince = nil,      -- when the model was first seen put away, nil while it is in the world
        statuses = none,
        stand = "",
        spec = "",
        leftArm = "",
        rightArm = "",
        leftLeg = "",
        rightLeg = "",
        body = model,           -- the character, and the parts of it the aim goes for, see hitbox.collect
        parts = none,
        target = {},            -- filled again on every frame, see Source:targets
    }
end

-- the slow pass: which characters there are and what the attributes say about them
function Source:refresh()
    local deps = self.deps
    local localPlayer = deps.localPlayer
    local worldFolder = deps.workspace:FindFirstChild("Characters")
    local culledFolder = deps.replicatedStorage:FindFirstChild("_PVS_CulledCharacters")
    self.culledFolder = culledFolder

    -- what a bot holds is told by its combatant, not by its model
    local botWeapons = {}
    local combatants = deps.replicatedStorage:FindFirstChild("Combatants")
    if combatants ~= nil then
        for _, combatant in combatants:GetChildren() do
            local id = combatant:GetAttribute("CombatantId")
            local weapon = combatant:GetAttribute("WeaponName")
            if id ~= nil and type(weapon) == "string" then
                botWeapons[id] = weapon
            end
        end
    end

    local own = localPlayer.Character
    local ownId = localPlayer.UserId
    local seen = {}

    table.clear(self.own)

    -- the maps of the game keep their collision apart from what is drawn: Workspace.Map.Barriers holds parts nobody
    -- can see, laid over the walls, the crates and the floors, often several of them one behind another
    table.clear(self.fences)
    local map = deps.workspace:FindFirstChild("Map")
    local barriers = map and map:FindFirstChild("Barriers")
    if barriers ~= nil then
        table.insert(self.fences, barriers)
    else
        -- a map may stand in the workspace under its own name: it is told by what it is made of
        for _, child in deps.workspace:GetChildren() do
            local inside = child:FindFirstChild("Barriers")
            if inside ~= nil and child:FindFirstChild("Geometry") ~= nil then
                table.insert(self.fences, inside)
            end
        end
    end

    local function take(model)
        if model.ClassName ~= "Model" then
            return
        end

        if model == own then
            table.insert(self.own, model)
            return
        end

        -- the folder holds other things too; a character is marked by the game
        if model:GetAttribute("CharacterType") ~= "PlayerCustomCharacter" then
            return
        end

        local owner = model:GetAttribute("PresentationOwnerUserId")
        if owner ~= nil and owner == ownId then
            table.insert(self.own, model)
            return
        end

        local root = model:FindFirstChild("HumanoidRootPart")
        if root == nil or not root:IsA("BasePart") then
            return
        end

        local record = self.records[model]
        if record == nil then
            record = newRecord(model)
            self.records[model] = record
        end

        seen[model] = true
        record.root = root

        record.parts = hitbox.collect(model)
        record.name = model.Name
        record.bot = model:GetAttribute("Bot") == true

        local player = nil
        if owner ~= nil then
            player = deps.players:GetPlayerByUserId(owner)
        end

        local team = nil
        local ping = nil
        local equipped = nil
        local shielded = false

        if player ~= nil then
            team = player:GetAttribute("Team")
            ping = player:GetAttribute("Ping")
            equipped = player:GetAttribute("CurrentEquipped")
            shielded = player:GetAttribute("Invincible") == true
        else
            team = model:GetAttribute("Team")
        end

        record.team = if type(team) == "string" then team else nil
        record.ping = if num.finite(ping) then ping else nil
        record.shielded = shielded

        if record.bot then
            record.weapon = botWeapons[model:GetAttribute("CombatantId")] or ""
        elseif equipped ~= record.equipped then
            -- the player's weapon is a JSON text; decoded only when the text changes
            record.equipped = equipped
            record.weapon = ""

            if type(equipped) == "string" and equipped ~= "" then
                local decoded = deps.decode(equipped)
                if type(decoded) == "table" and type(decoded.Name) == "string" then
                    record.weapon = decoded.Name
                end
            end
        end
    end

    local function scan(folder)
        if folder == nil then
            return
        end

        for _, child in folder:GetChildren() do
            take(child)
        end
    end

    scan(worldFolder)
    scan(culledFolder)

    table.clear(self.list)
    for model, record in self.records do
        if seen[model] then
            table.insert(self.list, record)
        else
            self.records[model] = nil
        end
    end
end

-- whether somebody the user can see anyway, or the user himself, is within that many studs of a place:
-- a sound that comes from there tells nothing new. A character the game has put away does not count:
-- where its model lies is where it was, not where it is
function Source:nearVisible(x, y, z, radius)
    local culledFolder = self.culledFolder

    local function near(root)
        local position = root.Position
        local dx, dy, dz = position.X - x, position.Y - y, position.Z - z
        return dx * dx + dy * dy + dz * dz <= radius * radius
    end

    local own = self.deps.localPlayer.Character
    if own ~= nil then
        local root = own:FindFirstChild("HumanoidRootPart")
        if root ~= nil and root:IsA("BasePart") and near(root) then
            return true
        end
    end

    for _, record in self.list do
        local model = record.model
        local parent = model.Parent
        local root = record.root

        if parent ~= nil and parent ~= culledFolder and root.Parent == model and model:GetAttribute("Dead") ~= true and near(root) then
            return true
        end
    end

    return false
end

-- every frame: adds to out what is to be drawn, in the shape players.target gives it, with two fields more:
-- hidden (the game has put the model away, the place is the last known one) and hiddenFor (for how many seconds)
function Source:targets(out, haveLocal, localX, localY, localZ, now)
    local culledFolder = self.culledFolder

    -- games without sides leave it empty, nobody is a teammate then; nor in a deathmatch, where the sides are written
    -- but everybody shoots everybody (Controllers.MobileAutoShootController tells an enemy so)
    local localTeam = self.deps.localPlayer:GetAttribute("Team")
    if type(localTeam) ~= "string" or self.deps.workspace:GetAttribute("Gamemode") == "Deathmatch" then
        localTeam = nil
    end

    for _, record in self.list do
        local model = record.model
        local parent = model.Parent
        local root = record.root

        -- destroyed since the pass (a respawn builds a new model), or dead
        if parent == nil or root.Parent ~= model or model:GetAttribute("Dead") == true then
            continue
        end

        local position = root.Position
        local x, y, z = position.X, position.Y, position.Z
        if not num.plausible(x, y, z) then
            continue
        end

        local haveHealth = false
        local fraction = 0
        local health = model:GetAttribute("Health")
        local maxHealth = model:GetAttribute("MaxHealth")
        if num.finite(health) and num.finite(maxHealth) and maxHealth > 0 then
            if health <= 0 then
                continue
            end

            haveHealth = true
            fraction = math.clamp(health / maxHealth, 0, 1)
        end

        local hidden = culledFolder ~= nil and parent == culledFolder
        if not hidden then
            record.hiddenSince = nil
        elseif record.hiddenSince == nil then
            record.hiddenSince = now
        end

        local target = record.target
        target.record = record
        target.x = x
        target.y = y
        target.z = z
        target.haveHealth = haveHealth
        target.healthFraction = fraction
        target.sameTeam = localTeam ~= nil and record.team == localTeam
        target.haveDistance = haveLocal
        target.distance = 0
        target.hidden = hidden
        target.hiddenFor = if hidden then now - record.hiddenSince else 0

        if haveLocal then
            local dx, dy, dz = x - localX, y - localY, z - localZ
            target.distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        end

        table.insert(out, target)
    end
end

return strike
end

__modules["throw"] = function(require)
-- how a grenade leaves the hand in Blox Strike: where and how fast, for a state of the movement and a kind of throw
-- the same arithmetic as calculateThrowParameters and createInitialState of the game (Shared.GrenadeSimulator, read
-- by tools/strike_probe7.lua); the server makes every throw with it, out of the state of its own movement
-- two numbers are not in that code and were read off recorded throws: the scale the server passes (the near throws
-- of the user give 1.4498 and 1.4500) and how far above the place of the state a throw has its origin
-- pure arithmetic, checked by tests/throw_test.lua against throws the game made
local num = require("./num")

local throw = {}

throw.range_scale = 1.45        -- what the server passes for the scale of the range
throw.origin_lift = 0.30        -- studs from the place of the state up to the origin of a throw

local base_speed = 57.29166666666667 * 0.58     -- of a far throw at scale 1, before the part that goes with it
local forward_offset = 1.35
local height_offset = 2.4

-- the look of the state as a direction: the yaw as the camera of the engine has it, the pitch in radians
-- (the state keeps the pitch in steps of 1/127 of a radian, which is why a throw is not where the camera points)
function throw.look(yaw, pitch)
    local flat = math.cos(pitch)
    return -math.sin(yaw) * flat, math.sin(pitch), -math.cos(yaw) * flat
end

-- the state a grenade starts in: x, y, z, vx, vy, vz and jump (thrown while going up: such a one bounces less)
--   x, y, z      the place of the movement state of the user
--   lx, ly, lz   where the state looks, a unit vector
--   kind         "Near" (the right button) or "Far"
--   vx, vy, vz   how fast the user moves
-- nil when the numbers are garbage
function throw.start(x, y, z, lx, ly, lz, kind, vx, vy, vz)
    if not num.plausible(x, y, z) or not num.plausible(lx, ly, lz) or not num.plausible(vx, vy, vz) then
        return nil
    end

    if lx * lx + ly * ly + lz * lz < 1e-6 then
        return nil
    end

    local scale = throw.range_scale
    local near = kind == "Near"

    -- the direction is the look tilted up a little, more for a near throw
    local bias = (if near then 0.04 else 0.06) * math.clamp(scale, 0.8, 1.2)
    local forward = forward_offset
    local height = height_offset + 0.1
    if near then
        forward *= 0.55
        height = height_offset * 0.8
        bias += 0.08
    end

    local dx, dy, dz = lx, ly + bias, lz
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    dx, dy, dz = dx / length, dy / length, dz / length

    -- the place: ahead along the ground, and up
    local flatX, flatZ = lx, lz
    local flatLength = math.sqrt(flatX * flatX + flatZ * flatZ)
    if flatLength < 0.01 then
        flatX, flatZ = 0, -1
    else
        flatX, flatZ = flatX / flatLength, flatZ / flatLength
    end

    local startX = x + flatX * forward
    local startY = y + throw.origin_lift + height
    local startZ = z + flatZ * forward

    -- the speed: along the direction, a fixed lift, and what the jump of the user adds
    local speed = (if near then 0.3 else 1) * base_speed * scale
    local jump = vy > 5
    local lift = if jump then 20 else vy * 2 * 0.58

    local sx = dx * speed * 1.15
    local sy = dy * speed * 1.15 + lift + scale * 6.5 * 0.58
    local sz = dz * speed * 1.15

    local cap = if jump then (dy - 0.4) * 20 + 62 else 50
    local magnitude = math.sqrt(sx * sx + sy * sy + sz * sz)
    if cap < magnitude then
        local keep = cap / magnitude
        sx, sy, sz = sx * keep, sy * keep, sz * keep
    end

    -- the speed of the user along the ground comes on top of the cap
    return {
        x = startX, y = startY, z = startZ,
        vx = sx + vx * 1.5, vy = sy, vz = sz + vz * 1.5,
        jump = jump,
    }
end

return throw
end

__modules["town"] = function(require)
-- Town-режим: Silent Aim + AutoFire + Weapon ESP data. См. town_probe.txt за фактами игры:
--   • каждый ствол — Tool в Character; внутри RemoteEvent FireEvent/ReloadEvent/LoadEvent
--   • FireEvent:FireServer(shotTable, Aiming, IsLeaning, v195, u194, serverTime)
--     shotTable[shotIdx] = [ { hitInstance, endPos, normal, material, startPos, flashPart }, ... ]
--     клиент сам считает raycast → сервер верит. Это и Silent Aim и AutoFire.
--   • Settings модуль (ModuleScript в Tool) даёт maxammo/waittime/Damage/HeadMultiplier
--   • GunScript.ClientAmmo = NumberValue, Tool.ClientChambered = BoolValue, Tool.AmmoFolder — патроны
--
-- Silent Aim: GunScript LocalScript считает выстрел через локальную RayCast2 → workspace:Raycast,
-- потом из полученного hitInstance/hitPosition/normal/material + Flash строит shotTable и шлёт
-- FireEvent:FireServer. Хукаем workspace.Raycast через hookfunction + newcclosure (НЕ hookmetamethod
-- на __namecall — Town кикает за namecallInstance detector, проверено 15.10.2026). Фильтр по caller:
-- debug.info(2,'f') → getfenv(f).script — хук срабатывает ТОЛЬКО если raycast из LocalScript,
-- лежащего в Tool в руках локального игрока. Остальной мир и даже наши aim-рейкасты не задеты.
-- При hit возвращаем Lua-таблицу вместо RaycastResult: GunScript читает .Instance/.Position/.Normal/
-- .Material, таблица подойдёт. RayIgnoreCheck2 часть тела игрока не фильтрует (parent имеет Humanoid)

local town = {}

local scheduler = nil   -- env.task
local players = nil     -- Players service
local workspace_ = nil  -- Workspace
local vim_ = nil        -- VirtualInputManager — настоящий виртуальный клик для GunScript
local onHit_ = nil      -- колбэк deps.onHit(playerName, zoneName, damage) для hit-log
local gameRequire_ = nil -- настоящий Roblox require (env.gameRequire), а не склеенный модулями сборки
local lastShotAt = 0    -- для rate-limit AutoFire
local lastDiagAt = 0

-- deps:
--   task, players, workspace, virtualInputManager, gameRequire, onHit(name, zone, damage)
function town.setup(deps)
    scheduler = deps.task
    players = deps.players
    workspace_ = deps.workspace
    vim_ = deps.virtualInputManager
    onHit_ = deps.onHit
    gameRequire_ = deps.gameRequire
end

-- диагностика: раз в секунду печатаем причину почему autoFire не выстрелил
local function diag(reason)
    local now = os.clock()
    if now - lastDiagAt < 1 then return end
    lastDiagAt = now
    pcall(function() print("[Town autofire] " .. reason) end)
end

------------------------------------------------------------
-- API: кто сейчас в руках, что он может сказать

local function equippedTool(char)
    return char and char:FindFirstChildOfClass("Tool") or nil
end

local function readSettings(tool)
    local mod = tool and tool:FindFirstChild("Settings")
    if mod == nil or not mod:IsA("ModuleScript") then return nil end
    -- gameRequire = настоящий Roblox require (env.gameRequire), не склеенный require сборки
    local req = gameRequire_ or require
    local ok, settings = pcall(req, mod)
    return ok and type(settings) == "table" and settings or nil
end

-- для ESP чужого игрока: { name, ammo, maxAmmo, reloading }, или nil если ничего в руках
function town.weaponInfo(char)
    local tool = equippedTool(char)
    if tool == nil then return nil end
    local info = { name = tool.Name, ammo = nil, maxAmmo = nil, reloading = false }
    local gs = tool:FindFirstChild("GunScript")
    local ammoVal = gs and gs:FindFirstChild("ClientAmmo")
    if ammoVal then
        local okV, v = pcall(function() return ammoVal.Value end)
        if okV and type(v) == "number" then info.ammo = v end
    end
    local sMod = tool:FindFirstChild("Settings")
    if sMod and sMod:IsA("ModuleScript") then
        local req = gameRequire_ or require
        local ok, s = pcall(req, sMod)
        if ok and type(s) == "table" and type(s.maxammo) == "number" then
            info.maxAmmo = s.maxammo
        end
    end
    -- reload: GunScript во время перезарядки ставит атрибут "Reloading" на Tool (если игра его шлёт)
    -- + Chambered BoolValue с патроном в патроннике: Chambered.Value=false после последнего выстрела
    -- значит скоро авто-reload. Для autoFire считаем "reload"=идёт если ammo < maxammo и Chambered false
    local chambered = tool:FindFirstChild("Chambered")
    local chamberedFalse = chambered and pcall(function() return chambered.Value end)
        and chambered.Value == false
    if info.ammo ~= nil and info.ammo <= 0 and chamberedFalse then
        info.reloading = true
    end
    return info
end

------------------------------------------------------------
-- Picker: как выбрать цель для silent/autofire. Хост передаёт колбэк, который возвращает
-- Instance (head/torso part), или nil если никого

-- currentTarget — BasePart выбранный aim-picker'ом
-- currentPoint — точка попадания {x, y, z} (из hitbox+multipoint в aim.lua), nil → часть.Position
-- currentZone — hitbox-зона 1..5 (Head/Chest/Stomach/Arms/Legs) — для расчёта урона и для hit-log
local currentTarget = nil
local currentPoint = nil
local currentZone = nil
function town.setTarget(part, point, zone)
    currentTarget = part
    currentPoint = point
    currentZone = zone
end
function town.target()
    return currentTarget
end

-- человеко-читаемое имя hitbox-зоны для hit-log
local function zoneToName(zone)
    if zone == 1 then return "head" end
    if zone == 2 then return "chest" end
    if zone == 3 then return "stomach" end
    if zone == 4 then return "arm" end
    if zone == 5 then return "leg" end
    return "body"
end

-- приблизительный урон по Settings оружия × multiplier (без учёта дистанции-falloff и брони)
local function estimateDamage(toolSettings, zone)
    if type(toolSettings) ~= "table" then return 0 end
    local base = type(toolSettings.Damage) == "number" and toolSettings.Damage or 0
    local mult = 1
    if zone == 1 and type(toolSettings.HeadMultiplier) == "number" then
        mult = toolSettings.HeadMultiplier
    elseif (zone == 2 or zone == 3) and type(toolSettings.TorsoMultiplier) == "number" then
        mult = toolSettings.TorsoMultiplier
    elseif zone == 5 and type(toolSettings.LegMultiplier) == "number" then
        mult = toolSettings.LegMultiplier
    end
    return base * mult
end

------------------------------------------------------------
-- AutoFire (rage): сами строим shotTable (как GunScript его строит) и шлём FireEvent:FireServer
-- напрямую. Сервер получает выстрел с нашей целью, игрок умирает. Никаких ЛКМ, никакого GunScript —
-- клиент (экран, камера, прицел) не трогается. Так работает rage/HvH silent в любом Roblox-читe:
-- на сервер → пакет с наводкой, на клиент → ничего не меняется.
-- Hook workspace.Raycast остаётся для случая, когда пользователь сам кликает ЛКМ (тогда родной
-- GunScript вызовет его cast и хук подменит результат)

local function serverNow()
    if workspace_ and workspace_.GetServerTimeNow then
        return workspace_:GetServerTimeNow()
    end
    return tick()
end

-- shotTable формат из декомпила GunScript (town_probe.txt строка 3058, 3082, 3112):
--   shots[1][1] = { hitInstance, hitPos, normal, material, startPos, flashPart }
local function buildShot(flash, hitPart, hitPos)
    local startPos = flash.Position
    local toward = startPos - hitPos
    local mag = toward.Magnitude
    local normal = (mag > 0) and (toward / mag) or Vector3.new(0, 1, 0)
    return { { hitPart, hitPos, normal, Enum.Material.Plastic, startPos, flash } }
end

function town.autoFire(settings, now)
    if settings == nil or settings.aim == nil or not settings.aim.autoFire then
        diag("aim.autoFire off"); return false
    end
    local s_townSilent = settings.townSilent
    if s_townSilent == nil or not s_townSilent.enabled then
        diag("townSilent off"); return false
    end
    local target = currentTarget
    if target == nil then diag("нет цели"); return false end
    local lp = players and players.LocalPlayer
    local char = lp and lp.Character
    if char == nil then diag("нет character"); return false end
    local tool = equippedTool(char)
    if tool == nil then diag("нет Tool в руках"); return false end
    local fireEvent = tool:FindFirstChild("FireEvent")
    if fireEvent == nil then diag("tool '" .. tool.Name .. "' без FireEvent"); return false end
    local flash = tool:FindFirstChild("Flash") or tool:FindFirstChild("Handle")
    if flash == nil then diag("tool '" .. tool.Name .. "' без Flash/Handle"); return false end

    local toolSettings = readSettings(tool)
    local interval = (toolSettings and type(toolSettings.waittime) == "number") and toolSettings.waittime or 0.12
    if now - lastShotAt < interval then return false end

    local info = town.weaponInfo(char)
    if info ~= nil then
        if info.ammo ~= nil and info.ammo <= 0 then diag("ammo=0, ждём reload"); return false end
        if info.reloading then diag("reloading"); return false end
    end

    -- клиентские блокировки (копия условия из GunScript декомпил строка 3526): пока ignoreLimits
    -- выключен — молчим когда родной клиент не выстрелил бы. С ignoreLimits=true шлём всегда
    if not s_townSilent.ignoreLimits then
        if char:FindFirstChild("Sprinting") then diag("спринт"); return false end
        if char:FindFirstChild("InspectingTool") then diag("осмотр оружия"); return false end
        if char:FindFirstChild("HasShot") then
            -- cooldown между выстрелами родного GunScript ещё не прошёл
            return false
        end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum ~= nil then
            local okH, h = pcall(function() return hum.Health end)
            if okH and type(h) == "number" and h <= 0 then diag("мёртв"); return false end
        end
    end

    -- 1. VIM-клик → родной GunScript сработает (анимация, звук, ClientAmmo--). Его shotTable
    --    уйдёт в прицел (= мимо цели), сервер это проигнорит
    -- 2. ПАРАЛЛЕЛЬНО сами шлём FireEvent с подменённой целью → сервер убивает цель
    -- Два пакета FireEvent за выстрел — рейд-читы в Town так и работают, сервер не рейтлимитит жёстко
    if vim_ ~= nil then
        pcall(function()
            vim_:SendMouseButtonEvent(0, 0, 0, true, workspace_.CurrentCamera, 0)
        end)
        if scheduler and scheduler.delay then
            scheduler.delay(0.03, function()
                pcall(function()
                    vim_:SendMouseButtonEvent(0, 0, 0, false, workspace_.CurrentCamera, 0)
                end)
            end)
        else
            pcall(function()
                vim_:SendMouseButtonEvent(0, 0, 0, false, workspace_.CurrentCamera, 0)
            end)
        end
    end

    -- наш FireEvent с shotTable в цель
    local hitPos
    if currentPoint ~= nil then
        hitPos = Vector3.new(currentPoint.x, currentPoint.y, currentPoint.z)
    else
        hitPos = target.Position
    end
    local shotTable = { buildShot(flash, target, hitPos) }
    local isLeaning = (char:FindFirstChild("IsLeaning") and char.IsLeaning.Value) or nil
    -- hit log: читаем HP цели ДО выстрела, через 0.3с сверяем — показываем лог только если
    -- сервер реально нанёс урон (иначе пакет мог быть отфильтрован: цель мертва/за стеной/
    -- не та команда, и т.п.)
    local victim = target.Parent and target.Parent.Name or "?"
    local humanoid = target.Parent and target.Parent:FindFirstChildOfClass("Humanoid")
    local hpBefore = nil
    if humanoid ~= nil then
        local okHp, v = pcall(function() return humanoid.Health end)
        if okHp and type(v) == "number" then hpBefore = v end
    end
    local shotZone = currentZone

    local ok, err = pcall(function()
        fireEvent:FireServer(shotTable, false, isLeaning, Vector3.new(0, 0, 0), nil, serverNow())
    end)
    if ok then
        diag("FIRED → " .. victim .. (vim_ and " +VIM" or ""))
        -- отложенная проверка через 0.3с: сервер успевает ответить, Humanoid.Health обновляется
        if type(onHit_) == "function" and humanoid ~= nil and hpBefore ~= nil
                and scheduler and scheduler.delay then
            scheduler.delay(0.3, function()
                if humanoid.Parent == nil then return end
                local okAfter, hpAfter = pcall(function() return humanoid.Health end)
                if not okAfter or type(hpAfter) ~= "number" then return end
                local delta = hpBefore - hpAfter
                if delta < 1 then return end       -- попадания нет (сервер отфильтровал)
                pcall(onHit_, victim, zoneToName(shotZone), delta)
            end)
        end
    else
        diag("FireServer ошибка: " .. tostring(err))
    end
    lastShotAt = now
    return ok
end

-- одиночный выстрел по клику ЛКМ — больше не нужен. Silent Aim стоит хуком на workspace.Raycast
-- (см. town.start): родной GunScript вызывает рейкаст, мы перехватываем результат и возвращаем
-- fake-hit в выбранную часть тела. Один клик = один родной FireEvent с подменённой целью, никаких
-- дублей. shootOnce оставлен no-op на случай старых точек вызова
function town.shootOnce()
    return false
end

------------------------------------------------------------
-- Silent Aim через hook workspace.Raycast. Фильтр по caller: сработает ТОЛЬКО когда raycast из
-- LocalScript, лежащего в Tool в руках локального игрока.
--
-- Fake-RaycastResult = Lua-таблица {Instance, Position, Normal, Material, Distance} — GunScript
-- читает через точку, таблица подходит
-- deps:
--   env         env.fromGlobals() (нужны hookfunction, newcclosure, workspace)
--   isEnabled() -> boolean       колбэк, читает settings.townSilent.enabled в режиме Town
--   localPlayer                   Players.LocalPlayer
function town.start(deps)
    local env = deps and deps.env or nil
    if type(env) ~= "table" then return end
    local hookfunction = env.hookfunction
    local newcclosure = env.newcclosure
    local workspace_ = env.workspace
    if type(hookfunction) ~= "function" or type(workspace_) ~= "userdata" and type(workspace_) ~= "table" then
        return
    end

    -- shared state через getgenv, чтобы повторная инъекция обновляла isEnabled/target getter,
    -- а старый хук продолжал работать с актуальными значениями. Hook ставим один раз
    local shared
    if env.getgenv then
        local g = env.getgenv()
        shared = g.__calciteTownRaycast
        if shared == nil then
            shared = { isEnabled = function() return false end, target = function() return nil end }
            g.__calciteTownRaycast = shared
        end
    else
        shared = { isEnabled = function() return false end, target = function() return nil end }
    end

    shared.isEnabled = deps.isEnabled or function() return false end
    shared.target = function() return currentTarget end
    shared.point = function() return currentPoint end
    shared.localPlayer = deps.localPlayer

    if shared.installed then return end
    shared.installed = true

    local realRaycast = workspace_.Raycast
    if type(realRaycast) ~= "function" then return end

    -- проверка caller: raycast должен прийти из LocalScript, который лежит в Tool в руках локального
    -- игрока. Иначе — любой другой скрипт (игры, наш, другого плагина) идёт через оригинал
    local function callerIsEquippedTool()
        local lp = shared.localPlayer
        local char = lp and lp.Character
        if char == nil then return false end
        -- stack: 1=этот handler, 2=caller (GunScript fire-функция)
        local callerFn = debug.info(2, "f")
        if callerFn == nil then return false end
        local okEnv, scriptEnv = pcall(getfenv, callerFn)
        if not okEnv or type(scriptEnv) ~= "table" then return false end
        local script = scriptEnv.script
        if script == nil then return false end
        local okIsA, isLocal = pcall(function() return script:IsA("LocalScript") end)
        if not okIsA or not isLocal then return false end
        local tool = script.Parent
        if tool == nil then return false end
        local okTool, isTool = pcall(function() return tool:IsA("Tool") end)
        if not okTool or not isTool then return false end
        return tool.Parent == char
    end

    local Vector3 = env.Vector3
    local Enum = env.Enum

    local function fakeHit(origin, direction, part, point)
        -- точка из aim.lua pickWorld (hitbox+multipoint); fallback = центр части
        local pos
        if point ~= nil then
            pos = Vector3.new(point.x, point.y, point.z)
        else
            pos = part.Position
        end
        -- normal: приблизительно против направления пули; GunScript его только пишет в shotTable[3],
        -- сервер не проверяет
        local back = Vector3.new(-direction.X, -direction.Y, -direction.Z)
        local mag = math.sqrt(back.X ^ 2 + back.Y ^ 2 + back.Z ^ 2)
        local normal = mag > 0 and Vector3.new(back.X / mag, back.Y / mag, back.Z / mag) or Vector3.new(0, 1, 0)
        local dx, dy, dz = pos.X - origin.X, pos.Y - origin.Y, pos.Z - origin.Z
        return {
            Instance = part,
            Position = pos,
            Normal = normal,
            Material = Enum.Material.Plastic,
            Distance = math.sqrt(dx * dx + dy * dy + dz * dz),
        }
    end

    local hooked
    local lastHookDiag = 0
    local function hookDiag(msg)
        local now = os.clock()
        if now - lastHookDiag < 1 then return end
        lastHookDiag = now
        pcall(function() print("[Town hook] " .. msg) end)
    end
    local function handler(self, origin, direction, params)
        if not shared.isEnabled() then
            return hooked(self, origin, direction, params)
        end
        local target = shared.target()
        if target == nil then
            hookDiag("raycast без цели (shared.target()=nil)")
            return hooked(self, origin, direction, params)
        end
        if typeof(target) ~= "Instance" or not target:IsA("BasePart") then
            hookDiag("target не BasePart: " .. tostring(typeof(target)))
            return hooked(self, origin, direction, params)
        end
        if not callerIsEquippedTool() then
            -- диагностика: кто вызвал Raycast
            local callerFn = debug.info(2, "f")
            local srcName = "?"
            if callerFn then
                local okEnv, scriptEnv = pcall(getfenv, callerFn)
                if okEnv and type(scriptEnv) == "table" and scriptEnv.script then
                    local okName, name = pcall(function() return scriptEnv.script:GetFullName() end)
                    srcName = okName and name or "?"
                end
            end
            hookDiag("filter-skip: caller=" .. srcName)
            return hooked(self, origin, direction, params)
        end
        hookDiag("HIT PATCHED → " .. tostring(target.Parent and target.Parent.Name or "?"))
        return fakeHit(origin, direction, target, shared.point())
    end

    hooked = hookfunction(realRaycast, newcclosure and newcclosure(handler) or handler)
end

return town
end

__modules["trigger"] = function(require)
-- the auto fire: clicks the left mouse button while the crosshair is on a target
-- the button is pressed the way a finger would press it; nothing of the game is changed or sent
-- the same rules as features/trigger.cpp of the external; checked by tests/trigger_test.lua
local hitbox = require("./hitbox")

local trigger = {}

local hold_time = 0.03      -- seconds the button stays down
-- with the weapon known (updateWeapon), as Components.Weapon and the action Fire of Blox Strike take a press:
local press_ahead = 0.12    -- seconds before the next shot is due that a press of a semi-automatic weapon is kept for it
                            -- (the game keeps one made within 0.15 s)
trigger.press_ahead = press_ahead
local press_lost = 0.35     -- seconds after which a press that brought no shot is made again
local hold_idle = 0.08      -- seconds a held button may fire nothing before it is let go of and pressed anew (a weapon
                            -- still coming out fires nothing, and holding on does not make it fire later)
local long_ago = 3600
local see_through = 4       -- things a look passes through before it gives up

local Trigger = {}
Trigger.__index = Trigger

-- deps:
--   press(), release()     the left mouse button
--   userHolds() -> boolean the button is down; asked only while this module does not hold it itself, and then
--                          a button that is down is the user's: the system cannot tell a generated press from a real one
function trigger.new(deps)
    return setmetatable({
        deps = deps,
        down = false,           -- this module is holding the button
        heldFor = 0,
        sinceClick = long_ago,  -- seconds since our last press
        holdMode = false,       -- the button is held for as long as the shots are wanted (updateWeapon)
        pressedAt = -long_ago,
        pressedDue = nil,       -- when the shot after the last press was due, as the weapon told it then
    }, Trigger)
end

-- call every frame while the game has the focus and the menu is closed, also with onTarget false:
-- the button this module pressed is let go from here. a is settings.aim in effect
function Trigger:update(onTarget, keyHeld, a, dt)
    if self.sinceClick < long_ago then
        self.sinceClick += dt
    end

    if self.down then
        self.heldFor += dt
        if self.heldFor >= hold_time then
            self.down = false
            self.deps.release()
        end

        return
    end

    if not a.autoFire or not onTarget or (a.autoFireNeedsKey and not keyHeld) then
        return
    end

    if self.deps.userHolds() then
        return
    end

    if self.sinceClick * 1000 < a.fireInterval then
        return
    end

    self.down = true
    self.heldFor = 0
    self.sinceClick = 0
    self.deps.press()
end

-- the same with the weapon in the hands known (weapon.read gives w; nil when there is nothing to shoot with in them),
-- the rate of fire is the one of the weapon: an automatic weapon is held down while want stays true, and the game
-- fires it at its own rate; a semi-automatic one is clicked once a shot, as soon as the game keeps a click for the next.
-- want: the crosshair is on a target and the shot would hit. now is os.clock, the clock NextShotDue is on
-- burst: how many shots a hold may fire (weapon.burst; nil or math.huge: no end), counted by the rounds it took
function Trigger:updateWeapon(want, keyHeld, a, w, now, burst)
    local allowed = a.autoFire and want and w ~= nil and w.usable and not (a.autoFireNeedsKey and not keyHeld)

    if self.down then
        if self.holdMode then
            -- held: let go as soon as the shots are not wanted, when the burst is fired, or when holding on fires
            -- nothing
            local fired = if w ~= nil and self.burstRounds ~= nil then self.burstRounds - w.rounds else 0
            if not allowed or (not w.shooting and now - self.pressedAt >= hold_idle) or (burst ~= nil and fired >= burst) then
                self.down = false
                self.deps.release()
            end
        elseif now - self.pressedAt >= hold_time then
            self.down = false
            self.deps.release()
        end

        return
    end

    if not allowed or self.deps.userHolds() then
        return
    end

    if not w.automatic then
        -- the last press has not brought its shot yet: the time of the next one has not moved
        if w.due == self.pressedDue and now - self.pressedAt < press_lost then
            return
        end

        -- too early for the game to keep the press
        if w.shooting and w.due ~= nil and w.due - now > press_ahead then
            return
        end
    end

    -- an automatic weapon may be pressed while it is between two shots: held, it fires when it is ready
    self.down = true
    self.holdMode = w.automatic
    self.heldFor = 0
    self.sinceClick = 0
    self.pressedAt = now
    self.pressedDue = w.due
    self.burstRounds = w.rounds
    self.deps.press()
end

-- lets go of the button if this module holds it; call before the game can lose the focus
function Trigger:release()
    if not self.down then
        return
    end

    self.down = false
    self.deps.release()
end

-- true while the button is held for as long as the shots are wanted (an automatic weapon, see updateWeapon): the look
-- goes on meanwhile, it is what lets go of it
function Trigger:spraying()
    return self.down and self.holdMode
end

-- true while the left button is down because this module pressed it, not the user
function Trigger:holding()
    return self.down
end

-- whether that part of that target may be shot at: a picked part of somebody not protected, not too far
-- (the side and the hiding of the game are checked by whoever found the target)
function trigger.allowed(target, partName, a)
    if target.hidden or (a.skipProtected and target.record.shielded) then
        return false
    end

    if target.haveDistance and target.distance > a.maxDistance then
        return false
    end

    local zone = hitbox.zoneOf(partName)
    return zone ~= nil and a.zones[zone] == true
end

-- the target of the frame that thing belongs to, nil when it is of the world
local function ownerOf(object, targets)
    for _, target in targets do
        local body = target.record.body
        -- asked of the engine: two references to one object need not be equal
        if body ~= nil and object:IsDescendantOf(body) then
            return target
        end
    end

    return nil
end

-- whether what the crosshair rests on is to be shot at: a part of the body the user picked, of somebody the aim
-- would go for, with nothing in front of it; with true, that somebody (the target of the frame)
--   targets are the tables of players.target; a is settings.aim in effect
--   cast(ignored) -> the first thing a ray from the camera through the crosshair meets, leaving out the ignored;
--   ignored is a list this function adds to
--   trace, when given, is a list the function adds what the look met to, in words: for the diagnostics
function trigger.onTarget(targets, a, teamCheck, cast, ignored, trace)
    local function note(text)
        if trace ~= nil then
            table.insert(trace, text)
        end
    end

    -- the name of a thing of the world, for the trace only
    local function nameOf(object)
        local ok, name = pcall(function()
            return object:GetFullName()
        end)

        return if ok and type(name) == "string" then name else tostring(object.Name)
    end

    for _ = 0, see_through do
        local hit = cast(ignored)
        if hit == nil then
            note("nothing")
            return false
        end

        local target = ownerOf(hit, targets)
        if target == nil then
            -- the world: what a map is fenced and zoned with stops a ray and nobody sees it, the rest is a wall
            local transparency = hit.Transparency
            if type(transparency) ~= "number" or transparency < 1 then
                if trace ~= nil then
                    note("wall " .. nameOf(hit))
                end

                return false
            end

            if trace ~= nil then
                note("through " .. nameOf(hit) .. " (cannot be seen)")
            end
        else
            local who = tostring(hit.Name) .. " of " .. tostring(target.record.name)

            -- a body the aim leaves alone is in the way like a wall
            if teamCheck and target.sameTeam then
                note(who .. ": teammate")
                return false
            elseif target.hidden then
                note(who .. ": put away by the game")
                return false
            elseif a.skipProtected and target.record.shielded then
                note(who .. ": protected")
                return false
            end

            if target.haveDistance and target.distance > a.maxDistance then
                note(who .. ": too far")
                return false
            end

            local zone = hitbox.zoneOf(hit.Name)
            if zone ~= nil then
                if a.zones[zone] == true then
                    note(who .. ": fire")
                    return true, target
                end

                note(who .. ": this part is not picked")
                return false
            end

            -- its root, what it wears, what it holds: the shot is for the part under those
            note("through " .. who .. " (not a part of the body)")
        end

        table.insert(ignored, hit)
    end

    note("gave up")
    return false
end

return trigger
end

__modules["ui_controls"] = function(require)
-- Readable control metrics for the pinned Obsidian GUI. Keep its behavior and
-- input handling, but replace its compact Code-font dimensions consistently.
local controls = {}

function controls.mount(Library, env, Window)
    local UDim2, UDim, Enum, Vector2 = env.UDim2, env.UDim, env.Enum, env.Vector2
    local function typography(object, size, medium)
        if object.Name == "__IconFont" then return end
        object.TextScaled = false
        object.TextSize = size
        object.Font = if medium then Enum.Font.GothamMedium else Enum.Font.Gotham
        if medium and Library.Registry[object] then Library.Registry[object].FontFace = nil end
    end
    local function height(object, value)
        if object.Size.Y.Offset ~= value or object.Size.Y.Scale ~= 0 then
            object.Size = UDim2.new(object.Size.X.Scale, object.Size.X.Offset, 0, value)
        end
    end
    local function caption(holder)
        local label = holder:FindFirstChildOfClass("TextLabel")
        if label then typography(label,16) end
        return label
    end
    local function keepLayout(holder, layout)
        local busy = false
        local function update()
            if busy then return end
            busy = true
            layout()
            busy = false
        end
        update()
        Library:GiveSignal(holder:GetPropertyChangedSignal("Size"):Connect(update))
    end

    for _, toggle in Library.Toggles do
        local holder = toggle.Holder
        if not holder then continue end
        local label = caption(holder)
        height(holder,32)
        if label then label.TextWrapped = true end
        local switch = holder:FindFirstChildOfClass("Frame")
        if switch then
            switch.Size = UDim2.fromOffset(38,22)
            switch.AnchorPoint = Vector2.new(1,0.5)
            switch.Position = UDim2.fromScale(1,0.5)
            if label then label.Size = UDim2.new(1,-46,1,0) end
        end
        if label and Library.GetTextBounds then
            local function fitCaption()
                local width = label.AbsoluteSize.X / (Library.DPIScale or 1)
                if width <= 0 then return end
                local _, lines = Library:GetTextBounds(label.Text,label.FontFace,16,width)
                height(holder,math.max(32,lines + 6))
            end
            Library:GiveSignal(label:GetPropertyChangedSignal("Text"):Connect(fitCaption))
            Library:GiveSignal(label:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitCaption))
            fitCaption()
        end
    end

    for _, option in Library.Options do
        local holder = option.Holder
        if not holder then continue end
        if option.Type == "Dropdown" then
            local label = caption(holder)
            if label then height(label,20) end
            local display = holder:FindFirstChildOfClass("TextButton")
            if display then
                height(display,32)
                for _, child in display:GetChildren() do
                    if child:IsA("TextButton") then
                        typography(child,16)
                        keepLayout(child,function() height(child,32) end)
                    end
                end
            end
            keepLayout(holder,function() height(holder,if option.Text then 58 else 32) end)
            if option.Menu then
                for _, child in option.Menu.Menu:GetDescendants() do
                    if child:IsA("TextButton") and child.Name ~= "__IconFont" then typography(child,16) end
                end
            end
        elseif option.Type == "Input" then
            local label = caption(holder)
            if label then height(label,20) end
            height(holder,58)
            local input = holder:FindFirstChildOfClass("TextBox")
            if input then typography(input,16) height(input,32) end
        elseif option.Type == "Slider" then
            local label = caption(holder)
            if label then height(label,20) end
        end
    end

    for _, button in Library.Buttons or {} do
        if button.Holder then height(button.Holder,34) end
        if button.Label then typography(button.Label,16) height(button.Label,22) end
    end
    for _, tab in Library.Tabs do
        for _, group in tab.Groupboxes or {} do
            local padding = group.Container:FindFirstChildOfClass("UIPadding")
            if padding then
                padding.PaddingLeft, padding.PaddingRight = UDim.new(0,12), UDim.new(0,12)
                -- Native Resize reserves 14px around this container's content.
                padding.PaddingTop, padding.PaddingBottom = UDim.new(0,7), UDim.new(0,7)
            end
            local list = group.Container:FindFirstChildOfClass("UIListLayout")
            if list then list.Padding = UDim.new(0,12) end
            for _, element in group.Elements do
                if element.Type == "Label" and element.TextLabel then
                    typography(element.TextLabel,14)
                    if element.DoesWrap then element:Display() else height(element.TextLabel,22) end
                end
            end
            -- Obsidian's header has a text frame containing the title, then the optional description.
            -- Use that structure so a translation or a matching control caption cannot change the styling.
            local header = group.Holder:FindFirstChildOfClass("Frame")
            local texts = header and header:FindFirstChildOfClass("Frame")
            local title = texts and texts:FindFirstChildOfClass("TextLabel")
            if title then
                typography(title,18,true)
                title.AutomaticSize = Enum.AutomaticSize.None
                title.TextWrapped = false
                title.TextTruncate = Enum.TextTruncate.AtEnd
                height(title,22)
            end
            group:Resize()
        end
    end

    for _, object in Window.MainFrame:GetDescendants() do
        if not object:IsA("TextBox") or (object.PlaceholderText ~= "Search" and object.PlaceholderText ~= "Поиск настроек"
            and object.PlaceholderText ~= "Search settings") then continue end
        typography(object,16)
        object.TextXAlignment = Enum.TextXAlignment.Left
        object.Size = UDim2.new(0,280,0,34)
        local padding = object:FindFirstChildOfClass("UIPadding")
        if padding then
            padding.PaddingLeft, padding.PaddingRight = UDim.new(0,34), UDim.new(0,10)
            padding.PaddingTop, padding.PaddingBottom = UDim.new(0,0), UDim.new(0,0)
        end
        local icon = object:FindFirstChildOfClass("ImageLabel")
        if icon then
            icon.Size = UDim2.fromOffset(18,18)
            icon.SizeConstraint = Enum.SizeConstraint.RelativeXY
            icon.AnchorPoint = Vector2.new(0,0.5)
            icon.Position = UDim2.new(0,-24,0.5,0)
        end
    end
end

return controls
end

__modules["ui_localize"] = function(require)
-- Adapt Obsidian's exposed API, preserving canonical IDs and dropdown values.
local localized = {}

function localized.attach(Library, t)
    local seen = {}
    local function textElement(element, source)
        if not element or type(source) ~= "string" or type(element.SetText) ~= "function" then return end
        local set = element.SetText
        local binding = t:bind(source, function(text) set(element, text) end)
        element.SetText = function(_, text)
            binding.source = text
            set(element, t:text(text))
        end
    end

    local wrap
    wrap = function(scope)
        if not scope or seen[scope] then return scope end
        seen[scope] = true
        for _, method in { "AddLeftGroupbox", "AddRightGroupbox", "AddGroupbox" } do
            local add = scope[method]
            if type(add) == "function" then
                scope[method] = function(self, name, ...)
                    local group = add(self, name, ...)
                    local source = if type(name) == "table" then name.Name else name
                    if source then t:bind(source, function(text) group.Name = text end) end
                    return wrap(group)
                end
            end
        end
        for _, method in { "AddToggle", "AddSlider", "AddDropdown", "AddInput" } do
            local add = scope[method]
            if type(add) == "function" then
                scope[method] = function(self, id, info)
                    local copy = table.clone(info)
                    local literalValues = type(id) == "string" and id:sub(1, 12) == "SaveManager_"
                    if method == "AddDropdown" then
                        local function format(original, value)
                            local rendered = tostring(if original then original(value) else value)
                            if literalValues then
                                return if t.language == "ru" then (rendered:gsub(" %(autoload%)$", " (автозагрузка)")) else rendered
                            end
                            return t:text(rendered)
                        end
                        copy.FormatDisplayValue = function(value) return format(info.FormatDisplayValue, value) end
                        copy.FormatListValue = function(value) return format(info.FormatListValue, value) end
                    end
                    if method == "AddSlider" then
                        copy.HideMax = true
                        copy.AllowRightClickInput = false
                    end
                    local element = add(self, id, copy)
                    if method == "AddDropdown" and literalValues and element.Holder then
                        element.Holder:SetAttribute("CalciteValuesLiteral", true)
                        if element.Menu then element.Menu.Menu:SetAttribute("CalciteValuesLiteral", true) end
                        element:Display()
                        element:BuildDropdownList()
                    end
                    textElement(element, info.Text)
                    if method == "AddDropdown" then
                        t:onChanged(function()
                            if element.BuildDropdownList then element:BuildDropdownList() end
                            if element.Display then element:Display() end
                        end)
                    elseif method == "AddSlider" and element.SetSuffix and info.Suffix then
                        t:bind(info.Suffix, function(suffix) element:SetSuffix(suffix) end)
                    end
                    return wrap(element)
                end
            end
        end
        if type(scope.AddLabel) == "function" then
            local add = scope.AddLabel
            scope.AddLabel = function(self, text, ...)
                local element = add(self, text, ...)
                textElement(element, text)
                return wrap(element)
            end
        end
        if type(scope.AddButton) == "function" then
            local add = scope.AddButton
            scope.AddButton = function(self, info, ...)
                local element = add(self, info, ...)
                textElement(element, if type(info) == "table" then info.Text else info)
                return wrap(element)
            end
        end
        return scope
    end

    local create = Library.CreateWindow
    Library.CreateWindow = function(self, info)
        local window = create(self, info)
        local add = window.AddTab
        window.AddTab = function(owner, name, ...)
            local tab = add(owner, name, ...)
            local source = if type(name) == "table" then name.Name else name
            t:bind(source, function(text) tab.Name = text end)
            return wrap(tab)
        end
        return window
    end

    local notify = Library.Notify
    Library.Notify = function(self, info, ...)
        if type(info) == "table" then
            info = table.clone(info)
            info.Title = t:text(info.Title)
            info.Description = t:text(info.Description)
        else
            info = t:text(info)
        end
        return notify(self, info, ...)
    end

    -- The library creates key menus, dialogs and dropdown rows lazily. Watch their
    -- labels too, but never translate editable text or user-supplied config names.
    local root = Library.ScreenGui
    if root and root.GetDescendants then
        local watched = {}
        local function watch(object)
            if watched[object] then return end
            local props = {}
            if object:IsA("TextLabel") or object:IsA("TextButton") then table.insert(props, "Text") end
            if object:IsA("TextBox") then table.insert(props, "PlaceholderText") end
            if #props == 0 then return end
            local records = {}
            watched[object] = records
            for _, property in props do
                local busy = false
                local source = object[property]
                local rendered = nil
                local function update()
                    if busy then return end
                    if object:GetAttribute("CalciteLiteral") then return end
                    if property == "Text" and object:IsA("TextButton") then
                        local parent = object
                        while parent and parent ~= root do
                            if parent:GetAttribute("CalciteValuesLiteral") then return end
                            parent = parent.Parent
                        end
                    end
                    local value = object[property]
                    if value ~= rendered then source = value end
                    rendered = t:text(source)
                    busy = true
                    object[property] = rendered
                    busy = false
                end
                table.insert(records, { update = update, connection = object:GetPropertyChangedSignal(property):Connect(update) })
                update()
            end
        end
        local function unwatch(object)
            local records = watched[object]
            if not records then return end
            for _, record in records do record.connection:Disconnect() end
            watched[object] = nil
        end
        for _, object in root:GetDescendants() do watch(object) end
        Library:GiveSignal(root.DescendantAdded:Connect(watch))
        Library:GiveSignal(root.DescendantRemoving:Connect(unwatch))
        if Library.OnUnload then
            Library:OnUnload(function()
                for object in watched do unwatch(object) end
            end)
        end
        t:onChanged(function()
            for object, records in watched do
                if object.Parent then
                    for _, record in records do record.update() end
                end
            end
            if Library.UpdateSearch then Library:UpdateSearch(Library.SearchText or "") end
        end)
    end
end

return localized
end

__modules["ui_preferences"] = function(require)
-- Global interface preferences, deliberately separate from per-game feature configs.
local preferences = {}
local accents = { Lilac = true, Blue = true, Sage = true, Rose = true }
local scales = { [80] = true, [90] = true, [100] = true, [110] = true, [120] = true }

function preferences.normalize(value)
    local s = if type(value) == "table" then value else {}
    return {
        language = if s.language == "en" then "en" else "ru",
        accent = if accents[s.accent] then s.accent else "Lilac",
        scale = if scales[s.scale] then s.scale else 100,
        hideOverlay = if type(s.hideOverlay) == "boolean" then s.hideOverlay else true,
    }
end

function preferences.load(io)
    local ok, value = pcall(function() return io.decode(io.read()) end)
    return preferences.normalize(if ok then value else nil)
end

function preferences.save(io, value)
    local ok, problem = pcall(function() io.write(io.encode(preferences.normalize(value))) end)
    return ok, if ok then nil else tostring(problem)
end

-- Construct on demand so main.start does not retain another local register.
-- That function is close to the executor compiler's unoptimized register limit.
function preferences.executorIO(env, http)
    return {
        read = function() return env.readfile("Calcite/ui.json") end,
        write = function(value)
            if not env.isfolder("Calcite") then env.makefolder("Calcite") end
            env.writefile("Calcite/ui.json", value)
        end,
        encode = function(value) return http:JSONEncode(value) end,
        decode = function(value) return http:JSONDecode(value) end,
    }
end

return preferences
end

__modules["ui_style"] = function(require)
-- Calcite's presentation layer over the pinned Obsidian controls.
local style = {}
local controls = require("./ui_controls")
style.accents = { Lilac = { 173, 156, 245 }, Blue = { 123, 169, 208 }, Sage = { 133, 181, 146 }, Rose = { 210, 150, 170 } }

function style.configure(deps)
    local Library, env = deps.Library, deps.env
    local info = {
        Title = "Calcite", Footer = "", NotifySide = "Right", ShowCustomCursor = false,
        CornerRadius = 10, EnableCompacting = false, EnableSidebarResize = false,
        GlobalSearch = true, TabButtonsStyle = { Gap = 5, Padding = 10, CornerRadius = 6, Indicator = false },
    }
    if env and env.UDim2 and env.Enum and env.Enum.Font then
        info.Size = env.UDim2.fromOffset(1040, 740)
        info.Font = env.Enum.Font.Gotham
        info.SearchbarSize = env.UDim2.new(0, 280, 0, 34)
    end
    if Library.Scheme then
        for key, rgb in {
            BackgroundColor = { 24, 27, 35 }, MainColor = { 34, 38, 49 },
            OutlineColor = { 52, 57, 70 }, FontColor = { 236, 238, 245 }, DarkColor = { 17, 19, 25 },
        } do Library.Scheme[key] = deps.Color3.fromRGB(table.unpack(rgb)) end
        Library.Scheme.AccentColor = deps.Color3.fromRGB(table.unpack(style.accents[deps.settings.interface.accent]))
    end
    return info
end

function style.mount(deps, Window)
    local Library, env = deps.Library, deps.env
    local preferences = deps.settings.interface
    local requestedScale = preferences.scale
    local self = { profile = { username = deps.username or "Player", subscription = "Free" } }
    function self:setAccent(name)
        if not style.accents[name] then return end
        if Library.Scheme then
            Library.Scheme.AccentColor = deps.Color3.fromRGB(table.unpack(style.accents[name]))
            Library:UpdateColorsUsingRegistry()
        end
    end
    function self:setScale(percent)
        requestedScale = percent
        local actual = percent
        local frame = Window.MainFrame
        local camera = env and env.workspace and env.workspace.CurrentCamera
        if frame and camera then
            local viewport = camera.ViewportSize
            actual = math.min(percent, (viewport.X - 48) / frame.Size.X.Offset * 100,
                (viewport.Y - 48) / frame.Size.Y.Offset * 100)
            actual = math.max(25, actual)
            frame.Position = env.UDim2.new(0.5, -frame.Size.X.Offset * actual / 200,
                0.5, -frame.Size.Y.Offset * actual / 200)
        end
        if Library.SetDPIScale then Library:SetDPIScale(actual) end
    end
    if not env or not env.Instance or not Window.MainFrame then return self end

    local UDim2, UDim, Enum = env.UDim2, env.UDim, env.Enum
    local Vector2, Color3 = env.Vector2, deps.Color3
    local function new(class, props, parent, colors)
        local object = env.Instance.new(class)
        for key, value in props do object[key] = value end
        object.Parent = parent
        if colors then
            Library:AddToRegistry(object, colors)
            for property, key in colors do object[property] = Library.Scheme[key] end
        end
        return object
    end
    local function round(parent, radius)
        return new("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
    end
    local function text(parent, value, x, y, width, size, muted)
        return new("TextLabel", {
            BackgroundTransparency = 1, Position = UDim2.fromOffset(x, y), Size = UDim2.new(1, -width, 0, size + 6),
            Font = Enum.Font.Gotham, Text = value, TextSize = size, TextTransparency = muted and 0.35 or 0,
            TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 6,
        }, parent, { TextColor3 = "FontColor" })
    end

    local main = Window.MainFrame
    Window:SetSidebarWidth(196)
    local topbar
    for _, child in main:GetChildren() do
        if child:IsA("Frame") and child.Size and child.Size.Y.Offset == 48 then
            topbar = child
            break
        end
    end
    local container = main:FindFirstChild("Container")
    if container then
        local padding = container:FindFirstChildOfClass("UIPadding")
        if padding then
            padding.PaddingLeft = UDim.new(0, 14)
            padding.PaddingRight = UDim.new(0, 14)
            padding.PaddingTop = UDim.new(0, 10)
        end
    end

    local sidebar
    for _, child in main:GetChildren() do
        if child:IsA("ScrollingFrame") then sidebar = child break end
    end
    if sidebar then
        local function reserveProfile()
            sidebar.Size = UDim2.new(0, 196, 1, -122)
        end
        reserveProfile()
        Library:GiveSignal(main:GetPropertyChangedSignal("Size"):Connect(reserveProfile))
    end

    local profile = new("Frame", {
        Name = "CalciteProfile", BackgroundTransparency = 0, AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 1, 1, -21), Size = UDim2.fromOffset(194, 52), ZIndex = 5,
    }, main, { BackgroundColor3 = "BackgroundColor" })
    new("Frame", { BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), ZIndex = 6 }, profile,
        { BackgroundColor3 = "OutlineColor" })
    local avatar = new("ImageLabel", {
        BackgroundTransparency = 0, Position = UDim2.fromOffset(12, 9), Size = UDim2.fromOffset(34, 34),
        Image = if deps.userId then "rbxthumb://type=AvatarHeadShot&id=" .. tostring(deps.userId) .. "&w=150&h=150" else "",
        ZIndex = 6,
    }, profile, { BackgroundColor3 = "MainColor" })
    round(avatar, 17)
    local username = text(profile, "", 56, 6, 64, 16, false)
    username:SetAttribute("CalciteLiteral", true)
    username.Text = self.profile.username
    text(profile, "Free", 56, 27, 64, 14, true)

    for _, entry in Library.TabButtons do
        if entry.Label then entry.Label.TextSize = 18 end
    end
    for _, tab in Library.Tabs do
        if tab.Sides then
            for _, side in tab.Sides do
                local layout = side:FindFirstChildOfClass("UIListLayout")
                if layout then layout.Padding = UDim.new(0, 8) end
            end
        end
    end
    if topbar then
        for _, label in topbar:GetDescendants() do
            if not label:IsA("TextLabel") then continue end
            if label.Text == "Calcite" then
                label.TextSize = 22
            elseif label.Parent and label.Parent.Parent and label.Parent.Parent.Parent == topbar then
                if label.TextTransparency == 0.5 then
                    label.Visible = false
                else
                    label.TextSize = 20
                end
            end
        end
        Window:RefreshTitleSize()
    end
    local hideToggle = Library.Toggles.InterfaceHideOverlay
    if hideToggle and hideToggle.Holder then
        hideToggle.Holder.Size = UDim2.new(1, 0, 0, 36)
        local label = hideToggle.Holder:FindFirstChildOfClass("TextLabel")
        if label then label.TextWrapped = true end
        local switch = hideToggle.Holder:FindFirstChildOfClass("Frame")
        if switch then
            switch.AnchorPoint = Vector2.new(1, 0.5)
            switch.Position = UDim2.fromScale(1, 0.5)
        end
    end
    -- Reuse the native slider's drag behavior, but move its value into an editable
    -- field and give its fill a thin track and a handle.
    for _, option in Library.Options do
        if option.Type ~= "Slider" or not option.Holder then continue end
        local holder = option.Holder
        local bar = holder:FindFirstChildOfClass("TextButton")
        if not bar then continue end
        holder.Size = UDim2.new(1, 0, 0, 56)
        bar.Size = UDim2.new(1, -92, 0, 30)
        bar.Position = UDim2.fromScale(0, 1)
        local fill = bar:FindFirstChildOfClass("Frame")
        if not fill then continue end
        bar.BackgroundTransparency = 1
        local stroke = bar:FindFirstChildOfClass("UIStroke")
        if stroke then stroke.Enabled = false end
        local track = new("Frame", {
            AnchorPoint = Vector2.new(0,0.5), Position = UDim2.fromScale(0,0.5),
            Size = UDim2.new(1,0,0,6), BorderSizePixel = 0, ZIndex = bar.ZIndex,
        },bar,{BackgroundColor3="OutlineColor"})
        round(track,3)
        fill.Parent = track
        local handle = new("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(1, 0.5),
            Size = UDim2.fromOffset(14, 14), BorderSizePixel = 0, ZIndex = bar.ZIndex + 3,
        }, fill, { BackgroundColor3 = "AccentColor" })
        round(handle, 7)
        for _, child in bar:GetChildren() do
            if child:IsA("TextLabel") then child.Visible = false end
        end
        local input = new("TextBox", {
            AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(80, 30),
            ClearTextOnFocus = false, Font = Enum.Font.Gotham, TextSize = 16, Text = "", ZIndex = bar.ZIndex + 3,
        }, holder, { BackgroundColor3 = "MainColor", TextColor3 = "FontColor" })
        round(input, 5)
        new("UIStroke", { Thickness = 1 }, input, { Color = "OutlineColor" })
        local function display()
            if not input:IsFocused() then input.Text = tostring(option.Value) .. (option.Suffix or "") end
        end
        local nativeDisplay = option.Display
        option.Display = function(slider) nativeDisplay(slider) display() end
        Library:GiveSignal(input.Focused:Connect(function() input.Text = tostring(option.Value) end))
        Library:GiveSignal(input.FocusLost:Connect(function()
            local value = tonumber(input.Text)
            if not option.Disabled and value and value == value and math.abs(value) < math.huge then
                value = math.clamp(value, option.Min, option.Max)
                local factor = 10 ^ option.Rounding
                option:SetValue(math.round(value * factor) / factor)
            end
            display()
        end))
        display()
    end
    controls.mount(Library,env,Window)
    self:setAccent(preferences.accent)
    self:setScale(preferences.scale)
    local camera = env.workspace and env.workspace.CurrentCamera
    if camera and camera.GetPropertyChangedSignal then
        Library:GiveSignal(camera:GetPropertyChangedSignal("ViewportSize"):Connect(function() self:setScale(requestedScale) end))
    end
    return self
end

return style
end

__modules["waypoints"] = function(require)
-- the user's hand-picked roam waypoints for the YBA auto-farm: a cyclic list of (x, y, z) the roam visits in the
-- order the user added them. Saved to disk whenever the list changes, loaded on startup, so the route survives
-- script restarts. The glider gets a point when the farm has nothing in sight; see main.lua
-- pure logic, checked by tests/waypoints_test.lua
local waypoints = {}

local Waypoints = {}
Waypoints.__index = Waypoints

-- deps:
--   isfile(path), readfile(path), writefile(path, text)   as the executor gives them
--   decode(text) -> table or nil                          HttpService:JSONDecode wrapped in pcall
--   encode(table) -> text or nil                          HttpService:JSONEncode wrapped in pcall
--   file                                                   path to persist to, e.g. "Calcite/farm_waypoints.json"
function waypoints.new(deps)
    local self = setmetatable({
        deps = deps,
        list = {},              -- { { x, y, z }, ... }
        lastIdx = 0,            -- the index pickNext was last at, for the cycle
    }, Waypoints)
    self:load()
    return self
end

function Waypoints:load()
    pcall(function()
        if not self.deps.isfile or not self.deps.isfile(self.deps.file) then
            return
        end
        local text = self.deps.readfile(self.deps.file)
        if type(text) ~= "string" or text == "" then
            return
        end
        local t = self.deps.decode(text)
        if type(t) ~= "table" then
            return
        end
        -- validate: only entries with three numeric coords
        local clean = {}
        for _, entry in t do
            if type(entry) == "table" and type(entry.x) == "number" and type(entry.y) == "number" and type(entry.z) == "number" then
                table.insert(clean, { x = entry.x, y = entry.y, z = entry.z })
            end
        end
        self.list = clean
    end)
end

function Waypoints:save()
    pcall(function()
        local text = self.deps.encode(self.list)
        if type(text) == "string" and self.deps.writefile then
            self.deps.writefile(self.deps.file, text)
        end
    end)
end

function Waypoints:add(x, y, z)
    table.insert(self.list, { x = x, y = y, z = z })
    self:save()
    return #self.list
end

-- removes the waypoint closest to (x, z) within maxDist studs; nil if none
function Waypoints:removeNearest(x, z, maxDist)
    local best, bestD = nil, maxDist * maxDist
    for i, p in self.list do
        local dx, dz = p.x - x, p.z - z
        local d = dx * dx + dz * dz
        if d <= bestD then
            bestD = d
            best = i
        end
    end
    if best == nil then
        return nil
    end
    local removed = self.list[best]
    table.remove(self.list, best)
    if self.lastIdx >= best then
        self.lastIdx = math.max(0, self.lastIdx - 1)
    end
    self:save()
    return removed
end

function Waypoints:clear()
    table.clear(self.list)
    self.lastIdx = 0
    self:save()
end

function Waypoints:count()
    return #self.list
end

-- the whole list; the caller does not change it
function Waypoints:all()
    return self.list
end

-- the next waypoint in the cycle, nil if the list is empty. The cycle rolls over at the end
-- if the character is already at this waypoint (within arrivedRadius studs), the next one is picked instead,
-- so the glider does not sit idle on a point it just reached
function Waypoints:pickNext(cx, cz, arrivedRadius)
    local n = #self.list
    if n == 0 then
        return nil, nil
    end

    for _ = 1, n do
        self.lastIdx = (self.lastIdx % n) + 1
        local p = self.list[self.lastIdx]
        local dx, dz = p.x - cx, p.z - cz
        if dx * dx + dz * dz > arrivedRadius * arrivedRadius then
            return self.lastIdx, p
        end
    end
    -- all points are within arrivedRadius: return the current one anyway, the roam cooldown will do the rest
    local p = self.list[self.lastIdx]
    return self.lastIdx, p
end

return waypoints
end

__modules["weapon"] = function(require)
-- the weapon in the hands of the user in Blox Strike, read the way the game keeps it (tools/strike_probe10.lua): an
-- object of Components.Weapon with IsShooting, NextShotDue (os.clock), Rounds, IsReloading, IsAiming, its Properties
-- (the module of Database.Custom.Weapons) and a Bullet whose Spread is a spring (Shared.Spring, position in p)
-- nothing of the game is called: every field is read raw, so no code of the game runs and nothing in it changes
-- pure logic, checked by tests/weapon_test.lua
local weapon = {}

local still_speed = 6.4     -- studs a second: slower than this, the speed of the user adds nothing to the spread
local widest = 69           -- degrees: the cone of the game is never wider
local scope_settle = 0.2    -- seconds an AWP is not counted as scoped after the scope went on
-- when a weapon has come back from a shot, as the auto fire of the game itself waits for it
-- (Controllers.MobileAutoShootController isWeaponRecovered)
local recovered_after = 0.9 -- seconds after a shot, whatever else
local recoil_share = 0.25   -- the kick of the recoil (Recoil.Time) no more than this share of the rate of fire
local spread_share = 0.3    -- the spring of the spread within this lowest share of its range

-- how long a burst of an automatic weapon is, by how far the target is: the auto fire of the game itself sprays
-- within 30 studs, fires 4 within 80 and 2 beyond; a hand on a mouse sprays only nearer (15 studs is some 4 metres)
weapon.spray_range = 15     -- studs: nearer than this, a spray with no end, and no wait between two
local bursts = {
    { reach = 40, shots = 4 },
    { reach = math.huge, shots = 2 },
}

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- the least spread of a sniper rifle out of its scope, by its MovementMultiplier (Bullet getNoScopeMinSpread)
local function noScopeMin(multiplier)
    if multiplier == 2 then
        return 6
    elseif multiplier == 3 then
        return 12
    end

    return 15
end

-- the bounds of a NumberRange (or of a table with Min and Max)
local function bounds(range)
    local ok, low, high = pcall(function()
        return range.Min, range.Max
    end)

    if ok and finite(low) and finite(high) then
        return low, high
    end

    return nil, nil
end

-- the whole angle of the cone the next shot is drawn from, in degrees, as Bullet.create works it out: the spring of the
-- spread kept within the range of the weapon, and the speed of the user times MovementMultiplier once it is 6.4 or more
-- (in the air the game counts the speed of the jump and JumpShotMinimum on top); a sniper rifle out of its scope never
-- spreads less than its no-scope least, nor an AWP in the first 0.2 s of its scope. tickNow is tick(): the scope is
-- timed by it. With worst the spring is taken at the top of its range: the widest a shot of it gets while standing
-- where the user stands. nil when the weapon cannot be read
function weapon.spread(item, tickNow, worst)
    local properties = rawget(item, "Properties")
    local bullet = rawget(item, "Bullet")
    if type(properties) ~= "table" or type(bullet) ~= "table" then
        return nil
    end

    local config = rawget(bullet, "ActiveSpreadConfig") or rawget(properties, "Spread")
    if type(config) ~= "table" then
        return nil
    end

    local low, high = bounds(rawget(config, "Range"))
    if low == nil then
        return nil
    end

    local spring = rawget(bullet, "Spread")
    local position = if type(spring) == "table" then rawget(spring, "p") else nil
    if not finite(position) then
        position = 0
    end

    if worst then
        position = high
    end

    local multiplier = rawget(config, "MovementMultiplier")
    if not finite(multiplier) then
        multiplier = 1
    end

    local speed = rawget(bullet, "CharacterSpeed")
    if not finite(speed) then
        speed = 0
    end

    local sniper = rawget(properties, "AimingOptions") == "SniperScope"
    local aiming = rawget(item, "IsAiming") == true
    local least = noScopeMin(multiplier)

    -- out of the scope the game raises the spring itself before the shot
    if sniper and not aiming then
        position = math.max(position, least)
    end

    local spread = math.clamp(position, low, high) + (if speed < still_speed then 0 else speed) * multiplier

    if sniper and aiming and rawget(item, "Name") == "AWP" then
        local started = rawget(item, "ScopeStartTick")
        if not finite(started) then
            started = 0
        end

        if tickNow - started < scope_settle then
            spread = math.max(spread, least)
        end
    end

    return math.min(spread, widest)
end

-- whether the weapon has come back from its last shot, by the rule the auto fire of the game itself waits for between
-- the shots of a semi-automatic weapon: 0.9 s since it, or the kick of the recoil nearly gone (Recoil.Time no more than
-- a quarter of the rate of fire) and the spring of the spread within the lowest 30% of its range. True before the
-- first shot, and for what cannot be read
function weapon.recovered(item, tickNow)
    local bullet = rawget(item, "Bullet")
    local last = if type(bullet) == "table" then rawget(bullet, "LastShotTick") else nil
    if not finite(last) or last <= 0 or tickNow - last >= recovered_after then
        return true
    end

    local recoil = rawget(item, "Recoil")
    if type(recoil) == "table" then
        local kick, rate = rawget(recoil, "Time"), rawget(recoil, "ActiveFireRate")
        if finite(kick) and finite(rate) and kick > rate * recoil_share then
            return false
        end
    end

    local properties = rawget(item, "Properties")
    local config = if type(properties) == "table" then rawget(properties, "Spread") else nil
    local low, high = bounds(if type(config) == "table" then rawget(config, "Range") else nil)
    local spring = rawget(bullet, "Spread")
    local position = if type(spring) == "table" then rawget(spring, "p") else nil
    if low == nil or not finite(position) then
        return true
    end

    return position <= low + (high - low) * spread_share
end

-- how many shots a burst of an automatic weapon at somebody that far away has (math.huge: as many as it takes);
-- distance nil (unknown) is counted as the middle of the ones that are not near
function weapon.burst(distance)
    if distance ~= nil and distance <= weapon.spray_range then
        return math.huge
    end

    for _, step in bursts do
        if distance == nil or distance <= step.reach then
            return step.shots
        end
    end

    return bursts[#bursts].shots
end

-- what the auto fire needs of the weapon in the hands, written into out; nil when there is nothing to shoot with in
-- them (a knife, a grenade, the bomb, nothing at all)
--   automatic  the game fires for as long as the button is held (a revolver charges while it is)
--   shooting   the weapon is busy with a shot: between two of them, charging (a revolver) or in a burst; due is the
--              os.clock of the next one, nil before the first
--   usable     out, loaded, not being reloaded nor having its suppressor changed: a press would shoot
--   spread     degrees, see weapon.spread; worst is the widest it gets (weapon.spread with worst); range is how far
--              its bullet goes
--   recovered  back from its last shot, see weapon.recovered
function weapon.read(item, tickNow, out)
    if type(item) ~= "table" then
        return nil
    end

    local properties = rawget(item, "Properties")
    if type(properties) ~= "table" or rawget(properties, "Class") ~= "Weapon" then
        return nil
    end

    local rounds = rawget(item, "Rounds")
    local due = rawget(item, "NextShotDue")
    local range = rawget(properties, "Range")
    -- a shotgun is loaded shell by shell and shoots in the middle of it
    local reloading = rawget(item, "IsReloading") == true and rawget(properties, "MuzzleType") ~= "ShotGun"

    out = out or {}
    out.name = rawget(item, "Name")
    out.automatic = rawget(properties, "Automatic") == true or rawget(properties, "ShootingOptions") == "Revolver"
    out.shooting = rawget(item, "IsShooting") == true or rawget(item, "IsChargeFiring") == true or rawget(item, "IsBurstShooting") == true
    out.due = if finite(due) then due else nil
    out.rounds = if finite(rounds) then rounds else 0
    out.usable = rawget(item, "IsEquipped") == true and not reloading and rawget(item, "IsAdjustingSuppressor") ~= true
        and out.rounds > 0
    out.spread = weapon.spread(item, tickNow)
    out.worst = weapon.spread(item, tickNow, true)
    out.recovered = weapon.recovered(item, tickNow)
    out.range = if finite(range) and range > 0 then range else nil
    return out
end

return weapon
end

__modules["yba_npcs"] = function(require)
-- NPC диалоги YBA: список для меню (tools/yba_npc_list_probe.lua + Workspace.Dialogues).
-- Каждая кнопка меню зовёт callNpc(dialogue) в main.lua: тот ищет модель с нужным Dialogue в
-- Workspace.Dialogues и дёргает fireproximityprompt(prompt). Телепорт не нужен — fireproximityprompt
-- срабатывает с любого расстояния.
-- modelName заполнен только для одноимённых диалогов (FastTravel, Item Machine) — там каждый NPC
-- различается именно именем модели, не Dialogue
return {
    { title = "Сюжет", items = {
        { label = "#1 Giorno",      dialogue = "Storyline #1" },
        { label = "#2 Koichi",      dialogue = "Storyline #2" },
        { label = "#3 Giorno",      dialogue = "Storyline #3" },
        { label = "#4 Bucciarati",  dialogue = "Storyline #4" },
        { label = "#5 Giorno",      dialogue = "Storyline #5" },
        { label = "#6 Fugo",        dialogue = "Storyline #6" },
        { label = "#7 Mista",       dialogue = "Storyline #7" },
        { label = "#8 Narancia",    dialogue = "Storyline #8" },
        { label = "#9 Abbacchio",   dialogue = "Storyline #9" },
        { label = "#10 Bucciarati", dialogue = "Storyline #10" },
        { label = "#11 Trish",      dialogue = "Storyline #11" },
        { label = "#12 Mista",      dialogue = "Storyline #12" },
        { label = "#13 Bucciarati", dialogue = "Storyline #13" },
        { label = "#14 Giorno",     dialogue = "Storyline #14" },
    }},
    { title = "Магазины", items = {
        { label = "Arrowsmith (Suno)",      dialogue = "Arrowsmith" },
        { label = "Bat Shop (Brad)",        dialogue = "Bat Shop" },
        { label = "Blood Bottle (Alex)",    dialogue = "Blood Bottle Shop" },
        { label = "Boxing Gloves",          dialogue = "Boxing Gloves Shop" },
        { label = "Pizzeria (Atmere)",      dialogue = "Pizzeria" },
        { label = "Pluck Shop",             dialogue = "Pluck Shop" },
        { label = "Umbrella (Jongic)",      dialogue = "Umbrella Shop" },
        { label = "Merchant (ShiftPlox)",   dialogue = "Merchant" },
        { label = "Item Machine",           dialogue = "Item Machine" },
    }},
    { title = "Тренеры", items = {
        { label = "Hamon (Lisa Lisa)",          dialogue = "Hamon Trainer" },
        { label = "Spin (Gyro)",                dialogue = "Spin Trainer" },
        { label = "Sword Style (Uzurashi)",     dialogue = "Sword Style Trainer" },
        { label = "Boxing (Quinton)",           dialogue = "Boxing Trainer" },
        { label = "Vampirism (Elder Roomy)",    dialogue = "Vampirism Trainer" },
    }},
    { title = "Fast Travel", items = {
        { label = "SayonaraShigetora",  dialogue = "FastTravel", modelName = "SayonaraShigetora" },
        { label = "KhongJa",            dialogue = "FastTravel", modelName = "KhongJa" },
        { label = "StucksDucks",        dialogue = "FastTravel", modelName = "StucksDucks" },
        { label = "Sheikal",            dialogue = "FastTravel", modelName = "Sheikal" },
        { label = "Snaliel",            dialogue = "FastTravel", modelName = "Snaliel" },
        { label = "Ancient_Fruits",     dialogue = "FastTravel", modelName = "Ancient_Fruits" },
    }},
    { title = "Боссы", items = {
        { label = "Officer Sam (1+)",       dialogue = "Officer Sam" },
        { label = "Deputy Bertrude (10+)",  dialogue = "Deputy Bertrude" },
        { label = "Abbacchio's Partner (15+)", dialogue = "Abbacchio's Partner" },
        { label = "Homeless Man Jill (15+)",   dialogue = "Homeless Man Jill" },
        { label = "Dracula (20+)",          dialogue = "Dracula" },
        { label = "Darius (20+)",           dialogue = "Darius, The Executioner" },
        { label = "William Zeppeli (25+)",  dialogue = "William Zeppeli" },
        { label = "Kars (30+)",             dialogue = "Kars" },
        { label = "Doppio (30+)",           dialogue = "Doppio" },
        { label = "DIO (35+)",              dialogue = "DIO" },
        { label = "Pucci (40+)",            dialogue = "Pucci" },
        { label = "Enya The Hag",           dialogue = "Enya The Hag" },
        { label = "Pyreiz",                 dialogue = "Pyreiz" },
        { label = "Jotaro (Tallest Peak)",  dialogue = "Path to Heaven" },
        { label = "Jotaro (Heaven)",        dialogue = "Heaven Ascension DIO Quest" },
    }},
    { title = "Другие", items = {
        { label = "Anasui",             dialogue = "Anasui" },
        { label = "Matt",               dialogue = "Matt" },
        { label = "Paragon",            dialogue = "Paragon" },
        { label = "Prestige Master",    dialogue = "Prestige Master" },
        { label = "Cosmetic Roller",            dialogue = "Cosmetic Roller" },
        { label = "Cosmetic Roller (ROBUX)",    dialogue = "Cosmetic Roller (ROBUX)" },
        { label = "Jesus (ивент)",      dialogue = "Jesus" },
    }},
}
end

__modules["yba_waypoints"] = function(require)
-- user-collected roam waypoints for the YBA auto-farm (tools/yba_waypoints_collector.lua)
-- the roam visits these in order when the farm has nothing in sight; see main.lua
-- to update: run the collector in-game (K add, L undo, R replace nearest, U finish), copy the array from
-- workspace/Calcite/yba_waypoints.txt here
return {
    { x = 1156.53, y = -42.48, z = -61.92 },
    { x = 365.20,  y = -25.79, z = 471.08 },
    { x = -351.63, y = 0.08,   z = -252.98 },
    { x = 21.77,   y = 0.21,   z = -545.34 },
    { x = 468.56,  y = 0.21,   z = 76.26 },
}
end

return __require("./main").start()
