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

    local fill = c.fillColor or { 255, 50, 50 }
    local outline = c.outlineColor or { 0, 0, 0 }
    local fillT = (c.fillTransparency or 50) / 100
    local outlineT = (c.outlineTransparency or 0) / 100
    local depthMode = pickDepth(self.deps.Enum, c.throughWalls ~= false)
    local styleKey = string.format("%d,%d,%d|%d,%d,%d|%.3f|%.3f|%s",
        fill[1], fill[2], fill[3], outline[1], outline[2], outline[3], fillT, outlineT, tostring(depthMode))
    local styleChanged = self._styleKey ~= styleKey
    local fillColor, outlineColor = self._fillColor, self._outlineColor
    if styleChanged or fillColor == nil then
        local Color3 = self.deps.Color3
        fillColor = Color3.fromRGB(fill[1], fill[2], fill[3])
        outlineColor = Color3.fromRGB(outline[1], outline[2], outline[3])
        self._styleKey = styleKey
        self._fillColor = fillColor
        self._outlineColor = outlineColor
    end

    local wanted = {}
    for _, target in targets do
        local record = target.record
        local char = record and record.character
        if char == nil then continue end
        if target.hidden then continue end
        if s.hideInvincible and record.shielded then continue end
        if s.teamCheck and target.sameTeam then continue end

        local h = self.cache[char]
        local created = false
        -- character мог освободиться (респавн) — старый Highlight уже умер вместе с ним
        if h == nil or h.Parent ~= char then
            h = self.deps.Instance.new("Highlight")
            h.Adornee = char
            h.Parent = char
            self.cache[char] = h
            created = true
        end
        if created or styleChanged then
            h.FillColor = fillColor
            h.OutlineColor = outlineColor
            h.FillTransparency = fillT
            h.OutlineTransparency = outlineT
            if depthMode then
                h.DepthMode = depthMode
            end
            h.Enabled = true
        end
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
    local colors = {}
    local colorCount = 0

    local function rgb(r, g, b)
        local key = r * 65536 + g * 256 + b
        local c = colors[key]
        if c == nil then
            if colorCount >= 512 then
                table.clear(colors)
                colorCount = 0
            end
            c = Color3.fromRGB(r, g, b)
            colors[key] = c
            colorCount += 1
        end
        return c
    end

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
        if not visible then return end
        immediate.Rectangle(Vector2.new(left, top), Vector2.new(right - left, bottom - top), rgb(r, g, b), 1, 0, 1)
    end

    function self.filledRect(left, top, right, bottom, r, g, b)
        if not visible then return end
        immediate.FilledRectangle(Vector2.new(left, top), Vector2.new(right - left, bottom - top), rgb(r, g, b), 1, 0)
    end

    -- a filled circle, drawn as a square rounded all the way: the documentation gives the arguments of FilledCircle
    -- in another order than those of Circle, and one of the two is a mistake
    function self.dot(x, y, radius, r, g, b, opacity)
        if not visible then return end
        immediate.FilledRectangle(Vector2.new(x - radius, y - radius), Vector2.new(radius * 2, radius * 2),
            rgb(r, g, b), opacity or 1, radius)
    end

    -- the outline of a circle, one pixel thick
    function self.circle(x, y, radius, r, g, b)
        if not visible then return end
        immediate.Circle(Vector2.new(x, y), radius, rgb(r, g, b), 1, 64, 1)
    end

    -- a line one pixel thick
    function self.line(x1, y1, x2, y2, r, g, b, opacity)
        if not visible then return end
        immediate.Line(Vector2.new(x1, y1), Vector2.new(x2, y2), rgb(r, g, b), opacity or 1, 1)
    end

    -- text with a black outline, readable over any background; opacity below 1 fades the outline with the text
    function self.text(x, y, r, g, b, text, opacity)
        if not visible then return end
        opacity = opacity or 1
        immediate.OutlinedText(Vector2.new(x, y), font, font_size, rgb(r, g, b), opacity, black, opacity, text, false)
    end

    -- the same, centred on x
    function self.textCentered(x, y, r, g, b, text, opacity)
        if not visible then return end
        opacity = opacity or 1
        immediate.OutlinedText(Vector2.new(x, y), font, font_size, rgb(r, g, b), opacity, black, opacity, text, true)
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
        Font = Font,
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
        fireclickdetector = fireclickdetector,
        firesignal = firesignal,
        getconnections = getconnections,
        queueOnTeleport = queue_on_teleport or queueonteleport,
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

-- Pre-cached formatted distance ("0 st".."2000 st") and health percent ("0%".."100%") strings: zero string.format per frame
local distLabels = {}
local pctLabels = {}
for p = 0, 100 do
    pctLabels[p] = tostring(p) .. "%"
end
local function formatDist(dist)
    local n = math.floor(dist + 0.5)
    if n >= 0 and n <= 2000 then
        local cached = distLabels[n]
        if cached == nil then
            cached = tostring(n) .. " st"
            distLabels[n] = cached
        end
        return cached
    end
    return string.format("%.0f st", dist)
end

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
                local pct = health_fade.percent(fraction)
                local label = pctLabels[pct] or (pct .. "%")
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
            d.textCentered(centerX, below, labelR, labelG, labelB, formatDist(target.distance))
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
local game, Instance, UDim, UDim2, Color3, Enum, Vector2, Font
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
    accent = Color3.fromRGB(173, 156, 245)
    bg = Color3.fromRGB(24, 27, 35)
    border = Color3.fromRGB(52, 57, 70)
    textCol = Color3.fromRGB(236, 238, 245)
end

local reloadStartAt = 0
local reloadDuration = 2.5    -- MVS револьвер: ~2.5s между выстрелами (из спеки external)

local lastFpsMeasure = 0
local fpsCount = 0
local fpsAvg = 0
local lastWmText = ""
local lastWmVisible = nil
local lastReloadVisible = nil
local lastHkVisible = nil
local lastHkWidth = 0

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

local function hudFont(preferred, fallback)
    local f = Enum and Enum.Font
    if f == nil then return nil end
    local ok, val = pcall(function() return f[preferred] end)
    if ok and val ~= nil then return val end
    local okF, valF = pcall(function() return f[fallback] end)
    return okF and valF or nil
end

local function applySemibold(label)
    if Font ~= nil and Enum ~= nil and Enum.FontWeight ~= nil then
        local ok, face = pcall(function()
            return Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.SemiBold)
        end)
        if ok and face ~= nil then
            local okSet = pcall(function() label.FontFace = face end)
            if okSet then return end
        end
    end
    label.Font = hudFont("BuilderSansBold", "GothamBold")
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
    wmFrame.BackgroundTransparency = 0.08
    wmFrame.BorderSizePixel = 0
    wmFrame.Size = UDim2.fromOffset(0, 30)
    wmFrame.AutomaticSize = Enum.AutomaticSize.X
    wmFrame.Position = UDim2.new(1, -12, 0, 12)
    wmFrame.AnchorPoint = Vector2.new(1, 0)
    wmFrame.Visible = false
    wmFrame.Parent = gui
    local corner = Instance.new("UICorner", wmFrame)
    corner.CornerRadius = UDim.new(0, 4)
    local stroke = Instance.new("UIStroke", wmFrame)
    stroke.Color = border
    stroke.Thickness = 1
    stroke.Transparency = 0.15
    local pad = Instance.new("UIPadding", wmFrame)
    pad.PaddingLeft = UDim.new(0, 12)
    pad.PaddingRight = UDim.new(0, 12)

    wmText = Instance.new("TextLabel")
    wmText.Parent = wmFrame
    wmText.BackgroundTransparency = 1
    wmText.Size = UDim2.fromScale(1, 1)
    wmText.AutomaticSize = Enum.AutomaticSize.X
    applySemibold(wmText)
    wmText.TextSize = 15
    wmText.TextColor3 = textCol
    wmText.TextXAlignment = Enum.TextXAlignment.Left
    wmText.Text = "Calcite"

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
    hkFrame.BackgroundTransparency = 0.08
    hkFrame.BorderSizePixel = 0
    hkFrame.Size = UDim2.fromOffset(116, 0)
    hkFrame.AutomaticSize = Enum.AutomaticSize.Y
    hkFrame.Position = UDim2.new(1, -12, 0, 50)
    hkFrame.AnchorPoint = Vector2.new(1, 0)
    hkFrame.Visible = false
    hkFrame.Parent = gui
    local hkCorner = Instance.new("UICorner", hkFrame)
    hkCorner.CornerRadius = UDim.new(0, 4)
    local hkStroke = Instance.new("UIStroke", hkFrame)
    hkStroke.Color = border
    hkStroke.Thickness = 1
    hkStroke.Transparency = 0.15
    local hkPad = Instance.new("UIPadding", hkFrame)
    hkPad.PaddingTop = UDim.new(0, 6)
    hkPad.PaddingBottom = UDim.new(0, 6)
    hkPad.PaddingLeft = UDim.new(0, 10)
    hkPad.PaddingRight = UDim.new(0, 10)
    hkList = Instance.new("UIListLayout", hkFrame)
    hkList.FillDirection = Enum.FillDirection.Vertical
    hkList.SortOrder = Enum.SortOrder.LayoutOrder
    hkList.Padding = UDim.new(0, 2)
    local hkTitle = Instance.new("TextLabel")
    hkTitle.Parent = hkFrame
    hkTitle.BackgroundTransparency = 1
    hkTitle.Size = UDim2.new(1, 0, 0, 16)
    applySemibold(hkTitle)
    hkTitle.TextSize = 13
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
    local keyStr = keyText or "-"
    local ord = order or 0
    if row == nil then
        local frame = Instance.new("Frame")
        frame.BackgroundTransparency = 1
        frame.Size = UDim2.new(1, 0, 0, 19)
        frame.LayoutOrder = ord
        frame.Parent = hkFrame
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Parent = frame
        nameLabel.BackgroundTransparency = 1
        nameLabel.Size = UDim2.new(1, 0, 1, 0)
        nameLabel.Position = UDim2.fromOffset(0, 0)
        applySemibold(nameLabel)
        nameLabel.TextSize = 14
        nameLabel.TextColor3 = textCol
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.Text = nameText
        local keyLabel = Instance.new("TextLabel")
        keyLabel.Parent = frame
        keyLabel.BackgroundTransparency = 1
        keyLabel.Size = UDim2.new(1, 0, 1, 0)
        keyLabel.Position = UDim2.fromOffset(0, 0)
        applySemibold(keyLabel)
        keyLabel.TextSize = 14
        keyLabel.TextColor3 = mutedCol
        keyLabel.TextXAlignment = Enum.TextXAlignment.Right
        keyLabel.Text = keyStr
        row = {
            frame = frame,
            keyLabel = keyLabel,
            nameLabel = nameLabel,
            name = nameText,
            key = keyStr,
            order = ord,
            visible = true,
            active = nil,
            rowW = nil,
        }
        hkRows[id] = row
        return row, true
    end
    local changed = false
    if row.order ~= ord then
        row.order = ord
        row.frame.LayoutOrder = ord
    end
    if row.name ~= nameText then
        row.name = nameText
        row.nameLabel.Text = nameText
        row.rowW = nil
        changed = true
    end
    if row.key ~= keyStr then
        row.key = keyStr
        row.keyLabel.Text = keyStr
        row.rowW = nil
        changed = true
    end
    if not row.visible then
        row.visible = true
        row.frame.Visible = true
    end
    return row, changed
end

local function hideRow(id)
    local row = hkRows[id]
    if row and row.visible ~= false then
        row.visible = false
        row.frame.Visible = false
    end
end

-- deps: players, workspace, and game, Instance, UDim, UDim2, Color3, Enum, Vector2, Font of env.lua
function hud.setup(deps)
    Players = deps.players
    workspace_ = deps.workspace
    game, Instance, UDim, UDim2 = deps.game, deps.Instance, deps.UDim, deps.UDim2
    Color3, Enum, Vector2, Font = deps.Color3, deps.Enum, deps.Vector2, deps.Font
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
    lastWmText, lastWmVisible, lastReloadVisible, lastHkVisible, lastHkWidth = "", nil, nil, nil, 0
    lastFpsMeasure, fpsCount, fpsAvg = 0, 0, 0
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
            if wmFrame and lastWmVisible ~= false then
                lastWmVisible = false
                wmFrame.Visible = false
            end
            if reloadFrame and lastReloadVisible ~= false then
                lastReloadVisible = false
                reloadFrame.Visible = false
            end
        end
        return
    end
    ensureGui()

    -- FPS: усредняем за 0.5с; текст и пинг обновляем ТОЛЬКО раз в 0.5с, чтобы не дёргать AutomaticSize каждый кадр
    fpsCount += 1
    local sampled = false
    if lastFpsMeasure == 0 then
        lastFpsMeasure = now
        sampled = true
    elseif now - lastFpsMeasure >= 0.5 then
        fpsAvg = fpsCount / (now - lastFpsMeasure)
        fpsCount = 0
        lastFpsMeasure = now
        sampled = true
    end

    if lastWmVisible ~= showWatermark then
        lastWmVisible = showWatermark
        wmFrame.Visible = showWatermark
    end
    if showWatermark and (sampled or lastWmText == "") then
        local ping = 0
        pcall(function() ping = math.floor(Players.LocalPlayer:GetNetworkPing() * 1000) end)
        local txt = string.format("Calcite  |  %d FPS  |  %d ms", math.floor(fpsAvg + 0.5), ping)
        if txt ~= lastWmText then
            lastWmText = txt
            wmText.Text = txt
        end
    end

    local elapsed = now - reloadStartAt
    local show = showReload and reloadStartAt > 0 and elapsed < reloadDuration
    local showBool = show == true
    if lastReloadVisible ~= showBool then
        lastReloadVisible = showBool
        reloadFrame.Visible = showBool
    end
    if showBool then
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
        if hkFrame and lastHkVisible ~= false then
            lastHkVisible = false
            hkFrame.Visible = false
        end
        return
    end
    ensureGui()
    local vis = entries ~= nil and #entries > 0
    if lastHkVisible ~= vis then
        lastHkVisible = vis
        hkFrame.Visible = vis
    end
    if not vis then
        for id in hkRows do hideRow(id) end
        return
    end
    local seen = {}
    local maxRowW = 0
    for i, e in ipairs(entries) do
        seen[e.id] = true
        local row = ensureHkRow(e.id, e.key, e.name, i)
        if row then
            local act = e.active == true
            if row.active ~= act then
                row.active = act
                row.keyLabel.TextColor3 = act and accent or (mutedCol or Color3.fromRGB(150, 150, 160))
            end
            local rowW = row.rowW
            if rowW == nil then
                local okN, tbN = pcall(function() return row.nameLabel.TextBounds.X end)
                local okK, tbK = pcall(function() return row.keyLabel.TextBounds.X end)
                local gotN = okN and type(tbN) == "number" and tbN > 0
                local gotK = okK and type(tbK) == "number" and tbK > 0
                local nW = gotN and tbN or (#tostring(e.name or "") * 7.5)
                local kW = gotK and tbK or (#tostring(e.key or "-") * 7.5)
                rowW = nW + 16 + kW
                if gotN and gotK then
                    row.rowW = rowW
                end
            end
            if rowW > maxRowW then maxRowW = rowW end
        end
    end
    for id in hkRows do
        if not seen[id] then hideRow(id) end
    end
    local targetW = math.ceil(math.max(106, maxRowW + 20))
    if lastHkWidth ~= targetW then
        lastHkWidth = targetW
        hkFrame.Size = UDim2.fromOffset(targetW, 0)
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
    ["Автоподбор"] = "Auto pick up", ["Предметы на карте"] = "World items",
    ["Закопанные припасы"] = "Buried supplies", ["Морской мусор (R)"] = "Sea Trash (R)", ["Возвращаться назад"] = "Return to start",
    ["Смена сервера если пусто"] = "Hop if no items",
    ["Фильтр мобов"] = "Mob filter", ["Все мобы"] = "All mobs",
    ["Без боссов"] = "No bosses", ["Только боссы"] = "Bosses only",
    ["Имя моба"] = "Mob name", ["Скиллы"] = "Skills",
    ["M1 на кулдауне"] = "M1 on cooldown", ["Метод"] = "Method",
    ["Тир"] = "Tier", ["Максимум (авто)"] = "Best unlocked (auto)",
    ["Пропускать мини-игры"] = "Skip minigame incidents",
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
    ["Персонаж"] = "Character", ["Скорость ходьбы"] = "WalkSpeed", ["Сила прыжка"] = "JumpPower",
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
local stand_out = require("./stand_out")
local stand_out_pickup = require("./stand_out_pickup")
local stand_out_mobs = require("./stand_out_mobs")
local stand_out_bounty = require("./stand_out_bounty")
local stand_out_howler = require("./stand_out_howler")
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

local slow_interval = 0.4      -- seconds between two passes over what changes rarely, as the cache of the external
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
    -- pre-allocated so feature state (_soPick / _soMob / _soBounty) stays under Luau's 200-local limit in main.start
    local handle = {
        _soPick = { picker = nil, entries = {}, wasOn = false, lastScan = -99 },
        _soMob = { farmer = nil, noclip = nil, entries = {}, wasOn = false, lastScan = -99 },
        _soBounty = { runner = nil, mobs = {}, prompt = nil, px = nil, py = nil, pz = nil, lastPromptScan = -99, wasOn = false, mod = nil, modTried = false },
        _cam = { fast = false },
        _inEffect = nil,
        _soHowler = { collector = nil, remote = nil, conn = nil, tried = false },
        _charMove = { savedWs = nil, savedJp = nil, savedUseJp = nil, wasWs = false, wasJp = false, lastChar = nil },
    }

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

        if handle._soPick.picker ~= nil then
            pcall(function()
                handle._soPick.picker:stop()
            end)
        end

        if handle._soMob.farmer ~= nil then
            pcall(function()
                handle._soMob.farmer:stop()
            end)
        end
        if handle._soMob.noclip ~= nil then
            pcall(function()
                handle._soMob.noclip:step(false)
            end)
        end
        if handle._soBounty.runner ~= nil then
            pcall(function()
                handle._soBounty.runner:stop()
            end)
        end
        if handle._soBounty.remoteConn ~= nil then
            pcall(function()
                handle._soBounty.remoteConn:Disconnect()
            end)
            handle._soBounty.remoteConn = nil
        end
        if handle._soBounty.ssConn ~= nil then
            pcall(function()
                handle._soBounty.ssConn:Disconnect()
            end)
            handle._soBounty.ssConn = nil
        end
        if handle._soBounty.karaokeConn ~= nil then
            pcall(function()
                handle._soBounty.karaokeConn:Disconnect()
            end)
            handle._soBounty.karaokeConn = nil
        end
        if handle._soBounty.armConn ~= nil then
            pcall(function()
                handle._soBounty.armConn:Disconnect()
            end)
            handle._soBounty.armConn = nil
        end
        if handle._soBounty.tabletopConn ~= nil then
            pcall(function()
                handle._soBounty.tabletopConn:Disconnect()
            end)
            handle._soBounty.tabletopConn = nil
        end
        if handle._soHowler.collector ~= nil then
            pcall(function()
                handle._soHowler.collector:stop(true)
            end)
        end
        if handle._soHowler.conn ~= nil then
            pcall(function()
                handle._soHowler.conn:Disconnect()
            end)
            handle._soHowler.conn = nil
        end
        pcall(function()
            local cm = handle._charMove
            local ch = localPlayer and localPlayer.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if hum ~= nil then
                if cm.wasWs and cm.savedWs ~= nil then hum.WalkSpeed = cm.savedWs end
                if cm.wasJp then
                    if cm.savedUseJp ~= nil then hum.UseJumpPower = cm.savedUseJp end
                    if cm.savedJp ~= nil then hum.JumpPower = cm.savedJp end
                end
            end
        end)

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
        onStandOutHowler = function()
            local sh = handle._soHowler
            if sh.collector == nil then
                return
            end
            local ch = localPlayer and localPlayer.Character
            local rt = ch and ch:FindFirstChild("HumanoidRootPart")
            local p = rt and rt.Position
            sh.collector:toggle(env.clock(), p and p.X, p and p.Y, p and p.Z)
            if ui ~= nil and ui.setStandOutHowler ~= nil then
                ui.setStandOutHowler(sh.collector.statusText)
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
        local c = handle._cam
        if c.fast then
            local dx, dy, dz = x - c.x, y - c.y, z - c.z
            local depth = -(c.r02 * dx + c.r12 * dy + c.r22 * dz)
            if depth <= 0 then
                return 0, 0, false
            end
            local lx = c.r00 * dx + c.r10 * dy + c.r20 * dz
            local ly = c.r01 * dx + c.r11 * dy + c.r21 * dz
            local invD = c.focal / depth
            return c.halfW + lx * invD, c.halfH - ly * invD, true
        end
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
        Font = env.Font,
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

    handle._soPick.picker = stand_out_pickup.new({
        teleportTo = function(x, y, z)
            local character = localPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if root ~= nil then
                root.CFrame = env.CFrame.new(x, y, z)
                root.AssemblyLinearVelocity = env.Vector3.new(0, 0, 0)
            end
        end,
        faceAt = function(px, py, pz, lx, ly, lz)
            local character = localPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if root ~= nil then
                local p = env.Vector3.new(px, py, pz)
                local t = env.Vector3.new(lx, ly, lz)
                if env.CFrame.lookAt ~= nil then
                    root.CFrame = env.CFrame.lookAt(p, t)
                else
                    root.CFrame = env.CFrame.new(p, t)
                end
                root.AssemblyLinearVelocity = env.Vector3.new(0, 0, 0)
                pcall(function() root.AssemblyAngularVelocity = env.Vector3.new(0, 0, 0) end)
            end
        end,
        pressKey = function(keyStr)
            local okTb, focusedTb = pcall(function() return UserInputService:GetFocusedTextBox() end)
            if okTb and focusedTb ~= nil then return end
            local vim = env.virtualInputManager
            local kc = env.Enum and env.Enum.KeyCode and env.Enum.KeyCode[keyStr]
            if vim ~= nil and kc ~= nil then
                pcall(function() vim:SendKeyEvent(true, kc, false, game) end)
                if env.task and env.task.delay then
                    env.task.delay(0.05, function()
                        pcall(function() vim:SendKeyEvent(false, kc, false, game) end)
                    end)
                else
                    pcall(function() vim:SendKeyEvent(false, kc, false, game) end)
                end
            end
        end,
        isSummoned = function()
            local c = localPlayer.Character
            if c == nil then return false end
            local ok, v = pcall(function() return c:GetAttribute("Summoned") end)
            return ok and v == true
        end,
        canSummon = function()
            local c = localPlayer.Character
            if c == nil then return false end
            local okNo, noSum = pcall(function() return c:GetAttribute("NoSummon") end)
            if okNo and noSum == true then return false end
            local info = stand_out.playerInfo(localPlayer)
            return info.stand ~= ""
        end,
        firePrompt = function(prompt)
            if type(env.fireproximityprompt) == "function" then
                pcall(env.fireproximityprompt, prompt)
            end
        end,
        holdBegin = function(prompt)
            prompt:InputHoldBegin()
        end,
        holdEnd = function(prompt)
            prompt:InputHoldEnd()
        end,
        serverHop = function()
            if handle._soPick.hopping then
                return
            end
            handle._soPick.hopping = true
            local function doHop()
                local okHop, errHop = pcall(function()
                    local placeId = game.PlaceId
                    local jobId = game.JobId
                    local visited = {}
                    local recent = {}
                    local histFile = "calcite_so_hops.txt"
                    if type(env.isfile) == "function" and type(env.readfile) == "function" then
                        local okR, raw = pcall(function()
                            return env.isfile(histFile) and env.readfile(histFile) or ""
                        end)
                        if okR and type(raw) == "string" then
                            for line in string.gmatch(raw, "[^\r\n]+") do
                                if line ~= "" and not visited[line] then
                                    visited[line] = true
                                    table.insert(recent, line)
                                end
                            end
                        end
                    end
                    if type(jobId) == "string" and jobId ~= "" and not visited[jobId] then
                        visited[jobId] = true
                        table.insert(recent, jobId)
                    end
                    while #recent > 15 do
                        table.remove(recent, 1)
                    end
                    if type(env.writefile) == "function" then
                        pcall(env.writefile, histFile, table.concat(recent, "\n"))
                    end

                    -- Ставим автозапуск Calcite после телепорта, если экзекутор умеет queue_on_teleport
                    if type(env.queueOnTeleport) == "function" then
                        local hasLocal = false
                        if type(env.isfile) == "function" then
                            local okL, exists = pcall(env.isfile, "Calcite/Calcite.lua")
                            hasLocal = okL and exists == true
                        end
                        local reloadCode = hasLocal
                            and 'loadstring(readfile("Calcite/Calcite.lua"))()'
                            or 'loadstring(game:HttpGet("https://raw.githubusercontent.com/DSjlffff/Calcite/main/Calcite.lua"))()'
                        pcall(env.queueOnTeleport, reloadCode)
                    end

                    local chosen = nil
                    local HttpService = game:GetService("HttpService")
                    if type(env.httpGet) == "function" and HttpService ~= nil then
                        local cursor = nil
                        local pool = {}
                        for _ = 1, 3 do
                            local url = "https://games.roblox.com/v1/games/" .. tostring(placeId)
                                .. "/servers/Public?sortOrder=Asc&limit=100"
                            if cursor ~= nil and cursor ~= "" then
                                url = url .. "&cursor=" .. tostring(cursor)
                            end
                            local okGet, body = pcall(env.httpGet, url)
                            if not okGet or type(body) ~= "string" then
                                break
                            end
                            local okDec, decoded = pcall(function()
                                return HttpService:JSONDecode(body)
                            end)
                            if not okDec or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
                                break
                            end
                            for _, srv in decoded.data do
                                table.insert(pool, srv)
                            end
                            chosen = stand_out_pickup.pickServer(pool, jobId, visited)
                            if chosen ~= nil and not visited[chosen] then
                                break
                            end
                            cursor = decoded.nextPageCursor
                            if cursor == nil or cursor == "" then
                                break
                            end
                        end
                    end

                    local TeleportService = game:GetService("TeleportService")
                    if chosen ~= nil then
                        TeleportService:TeleportToPlaceInstance(placeId, chosen, localPlayer)
                    else
                        TeleportService:Teleport(placeId, localPlayer)
                    end
                end)
                if not okHop then
                    warn("Calcite StandOutPickup hop: " .. tostring(errHop))
                end
                handle._soPick.hopping = false
            end
            if env.task ~= nil and type(env.task.spawn) == "function" then
                env.task.spawn(doHop)
            else
                doHop()
            end
        end,
    })

    do
        local keyMap = {
            E = "E", R = "R", B = "B",
            ["1"] = "One", ["2"] = "Two", ["3"] = "Three", ["4"] = "Four", ["5"] = "Five",
            ["6"] = "Six", ["7"] = "Seven", ["8"] = "Eight", ["9"] = "Nine",
        }
        handle._soMob.noclip = noclip.new({
            character = function() return localPlayer.Character end,
        })
        handle._soMob.farmer = stand_out_mobs.new({
            setPose = function(px, py, pz, lx, ly, lz)
                local character = localPlayer.Character
                local root = character and character:FindFirstChild("HumanoidRootPart")
                if root ~= nil then
                    local p = env.Vector3.new(px, py, pz)
                    local t = env.Vector3.new(lx, ly, lz)
                    if env.CFrame.lookAt ~= nil then
                        root.CFrame = env.CFrame.lookAt(p, t)
                    else
                        root.CFrame = env.CFrame.new(p, t)
                    end
                    root.AssemblyLinearVelocity = env.Vector3.new(0, 0, 0)
                    pcall(function() root.AssemblyAngularVelocity = env.Vector3.new(0, 0, 0) end)
                end
            end,
            setNoclip = function(on)
                if handle._soMob.noclip ~= nil then
                    handle._soMob.noclip:step(on)
                end
            end,
            pressKey = function(keyStr)
                local okTb, focused = pcall(function() return UserInputService:GetFocusedTextBox() end)
                if okTb and focused ~= nil then return end
                local vim = env.virtualInputManager
                local kcName = keyMap[keyStr]
                local kc = kcName and env.Enum and env.Enum.KeyCode and env.Enum.KeyCode[kcName]
                if vim ~= nil and kc ~= nil then
                    pcall(function() vim:SendKeyEvent(true, kc, false, game) end)
                    if env.task and env.task.delay then
                        env.task.delay(0.05, function()
                            pcall(function() vim:SendKeyEvent(false, kc, false, game) end)
                        end)
                    else
                        pcall(function() vim:SendKeyEvent(false, kc, false, game) end)
                    end
                end
            end,
            clickM1 = function()
                local okTb, focusedTb = pcall(function() return UserInputService:GetFocusedTextBox() end)
                if okTb and focusedTb ~= nil then return end
                local menuIsOpen = ui ~= nil and ui.menuOpen()
                local lmbDown = false
                pcall(function()
                    if env.Enum and env.Enum.UserInputType then
                        lmbDown = UserInputService:IsMouseButtonPressed(env.Enum.UserInputType.MouseButton1) == true
                    end
                end)
                if lmbDown then return end

                -- Если меню закрыто и окно игры в фокусе — настоящий клик mouse1press/release бьёт 100% надёжно
                -- (не зависит от ShiftLock, GuiInset или repeatCount в VirtualInputManager)
                if not menuIsOpen and focused() and type(env.mouse1press) == "function" and type(env.mouse1release) == "function" then
                    pcall(env.mouse1press)
                    if env.task and env.task.delay then
                        env.task.delay(0.05, function() pcall(env.mouse1release) end)
                    else
                        pcall(env.mouse1release)
                    end
                    return
                end

                local vim = env.virtualInputManager
                if vim ~= nil then
                    local vw, vh = 800, 600
                    if camera ~= nil and camera.ViewportSize ~= nil then
                        vw = math.floor(camera.ViewportSize.X)
                        vh = math.floor(camera.ViewportSize.Y)
                    end
                    local cx, cy = math.floor(vw * 0.5), math.floor(vh * 0.5)
                    if menuIsOpen then
                        -- Пауза пока курсор над окном ClickGUI (учитываем +GuiInset, т.к. GetMouseLocation включает топбар)
                        local mx, my, mw, mh = nil, nil, nil, nil
                        if ui.menuRect ~= nil then
                            mx, my, mw, mh = ui.menuRect()
                        end
                        local ix, iy = 0, 0
                        pcall(function()
                            local gs = game:GetService("GuiService")
                            if gs ~= nil and gs.GetGuiInset ~= nil then
                                local tl = gs:GetGuiInset()
                                if tl ~= nil then ix, iy = tl.X, tl.Y end
                            end
                        end)
                        if mx ~= nil then
                            mx = mx + ix
                            my = my + iy
                        end
                        local pad = 20
                        if mx ~= nil and UserInputService.GetMouseLocation ~= nil then
                            local okM, mpos = pcall(function() return UserInputService:GetMouseLocation() end)
                            if okM and mpos ~= nil then
                                if mpos.X >= mx - pad and mpos.X <= mx + mw + pad
                                    and mpos.Y >= my - pad and mpos.Y <= my + mh + pad then
                                    return
                                end
                            end
                        end

                        -- Курсор вне меню -> кликаем строго ВНЕ окна ClickGUI (и мимо топбара/хотбара)
                        local candidates = {
                            { 12, math.floor(vh * 0.5) },
                            { math.max(12, vw - 12), math.floor(vh * 0.5) },
                            { math.floor(vw * 0.5), 76 },
                            { 12, math.max(80, vh - 140) },
                            { math.max(12, vw - 12), math.max(80, vh - 140) },
                        }
                        local picked = false
                        for _, pt in candidates do
                            local px, py = pt[1], pt[2]
                            local hitsMenu = mx ~= nil and px >= mx - pad and px <= mx + mw + pad
                                and py >= my - pad and py <= my + mh + pad
                            if not hitsMenu then
                                cx, cy = px, py
                                picked = true
                                break
                            end
                        end
                        if not picked then return end
                    end
                    pcall(function() vim:SendMouseButtonEvent(cx, cy, 0, true, game, 0) end)
                    if env.task and env.task.delay then
                        env.task.delay(0.05, function()
                            pcall(function() vim:SendMouseButtonEvent(cx, cy, 0, false, game, 0) end)
                        end)
                    else
                        pcall(function() vim:SendMouseButtonEvent(cx, cy, 0, false, game, 0) end)
                    end
                elseif not menuIsOpen and type(env.mouse1press) == "function" and type(env.mouse1release) == "function" then
                    pcall(env.mouse1press)
                    if env.task and env.task.delay then
                        env.task.delay(0.05, function() pcall(env.mouse1release) end)
                    else
                        pcall(env.mouse1release)
                    end
                end
            end,
            isSummoned = function()
                local c = localPlayer.Character
                if c == nil then return false end
                local ok, v = pcall(function() return c:GetAttribute("Summoned") end)
                return ok and v == true
            end,
            canSummon = function()
                local c = localPlayer.Character
                if c == nil then return false end
                local okNo, noSum = pcall(function() return c:GetAttribute("NoSummon") end)
                if okNo and noSum == true then return false end
                local info = stand_out.playerInfo(localPlayer)
                return info.stand ~= ""
            end,
            isSkillActive = function()
                local data = localPlayer:FindFirstChild("Data")
                local sa = data and data:FindFirstChild("SkillActive")
                return sa ~= nil and sa.Value == true
            end,
            isStunned = function()
                local c = localPlayer.Character
                if c == nil then return false end
                local ok, v = pcall(function() return c:GetAttribute("Stunned") end)
                return ok and v == true
            end,
            guiCooldowns = function()
                local pg = localPlayer:FindFirstChildOfClass("PlayerGui")
                return stand_out_mobs.guiCooldowns(pg)
            end,
        })

        handle._soBounty.runner = stand_out_bounty.new({
            readUi = function()
                local sb = handle._soBounty
                local t = env.clock()
                local needRohanUi = false
                if sb.rohan ~= nil and (sb.rohan.submitStage or 0) >= 1 then
                    if sb.rohanUiAt == nil or t - sb.rohanUiAt >= 0.4 then
                        sb.rohanUiAt = t
                        needRohanUi = true
                    end
                end
                if not needRohanUi and sb.uiCache ~= nil and sb.uiCacheAt ~= nil and t - sb.uiCacheAt < 0.08 then
                    return sb.uiCache
                end
                local pg = localPlayer:FindFirstChildOfClass("PlayerGui")
                local res = stand_out_bounty.readUi(pg, needRohanUi)
                if needRohanUi then
                    sb.rohanSubmitBtn = res.rohanSubmitBtn
                    sb.rohanOpen = res.rohanOpen
                elseif sb.rohan ~= nil and (sb.rohan.submitStage or 0) >= 1 then
                    res.rohanSubmitBtn = sb.rohanSubmitBtn
                    res.rohanOpen = sb.rohanOpen == true
                else
                    sb.rohanSubmitBtn = nil
                    sb.rohanOpen = false
                end
                sb.uiCache = res
                sb.uiCacheAt = t
                return res
            end,
            unlockedTier = function()
                if not handle._soBounty.modTried then
                    handle._soBounty.modTried = true
                    local mods = ReplicatedStorage and ReplicatedStorage:FindFirstChild("Modules")
                    local bMod = mods and mods:FindFirstChild("Bounty")
                    if bMod ~= nil and type(env.gameRequire) == "function" then
                        local ok, res = pcall(env.gameRequire, bMod)
                        if ok and type(res) == "table" then
                            handle._soBounty.mod = res
                        end
                    end
                end
                local m = handle._soBounty.mod
                if m ~= nil and type(m.GetUnlockedTier) == "function" then
                    local ok, t = pcall(m.GetUnlockedTier, localPlayer)
                    if ok and type(t) == "number" and t >= 1 then
                        return t
                    end
                end
                return nil
            end,
            petyrPosition = function()
                local gf = workspace:FindFirstChild("Game")
                local npcs = gf and gf:FindFirstChild("NPCs")
                local petyr = npcs and npcs:FindFirstChild("Petyr")
                local hrp = petyr and (petyr:FindFirstChild("HumanoidRootPart") or petyr.PrimaryPart)
                if hrp ~= nil and hrp.Position ~= nil then
                    return hrp.Position.X, hrp.Position.Y, hrp.Position.Z
                end
                local fb = stand_out_bounty.petyr_fallback
                return fb.X, fb.Y, fb.Z
            end,
            interactPetyr = function(openEvent)
                -- Если нужно открыть именно доску баунти — используем только OpenRequested:Fire(),
                -- чтобы не открывать одновременно диалог Petyr ("wanna start bounty" / "1. yes | 2. Bye") под доской.
                if openEvent ~= nil and openEvent.Fire ~= nil then
                    pcall(function() openEvent:Fire() end)
                    return
                end
                -- Для сдачи награды (openEvent == nil) открываем диалог Petyr через ClickDetector / ProximityPrompt
                local gf = workspace:FindFirstChild("Game")
                local npcs = gf and gf:FindFirstChild("NPCs")
                local petyr = npcs and npcs:FindFirstChild("Petyr")
                if petyr ~= nil then
                    local cd = petyr:FindFirstChild("ClickDetector")
                    if cd ~= nil and type(env.fireclickdetector) == "function" then
                        pcall(env.fireclickdetector, cd)
                        return
                    end
                    local pp = petyr:FindFirstChild("ProximityPrompt")
                    if pp ~= nil and type(env.fireproximityprompt) == "function" then
                        pcall(env.fireproximityprompt, pp)
                    end
                end
            end,
            teleportTo = function(x, y, z, lookX, lookY, lookZ)
                local character = localPlayer.Character
                local root = character and character:FindFirstChild("HumanoidRootPart")
                if root ~= nil then
                    if lookX ~= nil and lookY ~= nil and lookZ ~= nil and env.CFrame.lookAt ~= nil then
                        local pos = env.Vector3.new(x, y, z)
                        local lookFlat = env.Vector3.new(lookX, y, lookZ)
                        if (lookFlat - pos).Magnitude > 0.05 then
                            root.CFrame = env.CFrame.lookAt(pos, lookFlat)
                        else
                            root.CFrame = env.CFrame.new(x, y, z)
                        end
                        -- Наводим камеру на цель (сундук Cheap Jewelry), чтобы Stand Out сразу дал ей белую обводку фокуса
                        local cam = workspace.CurrentCamera
                        if cam ~= nil then
                            local dx, dz = lookX - x, lookZ - z
                            local d = math.sqrt(dx * dx + dz * dz)
                            if d > 0.05 then
                                local camPos = env.Vector3.new(x - (dx / d) * 4.5, y + 4.5, z - (dz / d) * 4.5)
                                pcall(function()
                                    cam.CFrame = env.CFrame.lookAt(camPos, env.Vector3.new(lookX, lookY, lookZ))
                                end)
                            end
                        end
                    else
                        root.CFrame = env.CFrame.new(x, y, z)
                    end
                    root.AssemblyLinearVelocity = env.Vector3.new(0, 0, 0)
                end
            end,
            activateButton = function(btn)
                if btn == nil then return end
                local fired = false
                local function trySignal(sig)
                    if sig == nil then return false end
                    if type(env.firesignal) == "function" then
                        local ok = pcall(env.firesignal, sig)
                        if ok then return true end
                    end
                    if type(env.getconnections) == "function" then
                        local ok, conns = pcall(env.getconnections, sig)
                        if ok and type(conns) == "table" and #conns > 0 then
                            local any = false
                            for _, conn in conns do
                                if conn.Fire ~= nil then
                                    pcall(function() conn:Fire() end)
                                    any = true
                                elseif type(conn.Function) == "function" then
                                    pcall(conn.Function)
                                    any = true
                                end
                            end
                            if any then return true end
                        end
                    end
                    return false
                end
                fired = trySignal(btn.Activated) or trySignal(btn.MouseButton1Click)
                if not fired and env.virtualInputManager ~= nil and btn.AbsolutePosition ~= nil and btn.AbsoluteSize ~= nil then
                    local cx = math.floor(btn.AbsolutePosition.X + btn.AbsoluteSize.X * 0.5)
                    local cy = math.floor(btn.AbsolutePosition.Y + btn.AbsoluteSize.Y * 0.5)
                    pcall(function() env.virtualInputManager:SendMouseButtonEvent(cx, cy, 0, true, game, 1) end)
                    if env.task and env.task.delay then
                        env.task.delay(0.03, function()
                            pcall(function() env.virtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1) end)
                        end)
                    else
                        pcall(function() env.virtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1) end)
                    end
                end
            end,
            clickUiButton = function(btn)
                -- Реальный клик VirtualInputManager: в Roblox AbsolutePosition ВСЕГДА смещён на -GuiInset (+58px даже при IgnoreGuiInset=true!),
                -- а перед кликом нужен SendMouseMoveEvent, чтобы GuiButton поймал наведение и сработал Activated
                if btn == nil or env.virtualInputManager == nil then
                    return false
                end
                local okPos, pos, sz = pcall(function() return btn.AbsolutePosition, btn.AbsoluteSize end)
                if not okPos or pos == nil or sz == nil or sz.X <= 0 or sz.Y <= 0 then
                    return false
                end
                local ix, iy = 0, 0
                pcall(function()
                    local gs = game:GetService("GuiService")
                    if gs ~= nil and gs.GetGuiInset ~= nil then
                        local tl = gs:GetGuiInset()
                        if tl ~= nil then ix, iy = tl.X, tl.Y end
                    end
                end)
                local cx = math.floor(pos.X + sz.X * 0.5 + ix)
                local cy = math.floor(pos.Y + sz.Y * 0.5 + iy)
                if ui ~= nil and ui.menuOpen() then
                    local mx, my, mw, mh = ui.menuRect ~= nil and ui.menuRect() or nil
                    if mx == nil or (cx >= mx - 8 and cx <= mx + mw + 8 and cy >= my - 8 and cy <= my + mh + 8) then
                        return false
                    end
                end
                local vim = env.virtualInputManager
                pcall(function() vim:SendMouseMoveEvent(cx, cy, game) end)
                if env.task and env.task.delay then
                    env.task.delay(0.03, function()
                        pcall(function() vim:SendMouseButtonEvent(cx, cy, 0, true, game, 0) end)
                        env.task.delay(0.05, function()
                            pcall(function() vim:SendMouseButtonEvent(cx, cy, 0, false, game, 0) end)
                        end)
                    end)
                else
                    pcall(function() vim:SendMouseButtonEvent(cx, cy, 0, true, game, 0) end)
                    pcall(function() vim:SendMouseButtonEvent(cx, cy, 0, false, game, 0) end)
                end
                return true
            end,
            pressKey = function(keyStr)
                local vim = env.virtualInputManager
                local kcName = keyMap[keyStr]
                local kc = kcName and env.Enum and env.Enum.KeyCode and env.Enum.KeyCode[kcName]
                if vim ~= nil and kc ~= nil then
                    pcall(function() vim:SendKeyEvent(true, kc, false, game) end)
                    if env.task and env.task.delay then
                        env.task.delay(0.05, function()
                            pcall(function() vim:SendKeyEvent(false, kc, false, game) end)
                        end)
                    else
                        pcall(function() vim:SendKeyEvent(false, kc, false, game) end)
                    end
                end
            end,
            trackerPosition = function()
                local ok, pos = pcall(function() return localPlayer:GetAttribute("VisibleBountyTrackerPosition") end)
                if ok and pos ~= nil and pos.X ~= nil and pos.Y ~= nil and pos.Z ~= nil then
                    return pos.X, pos.Y, pos.Z
                end
                return nil, nil, nil
            end,
            navActive = function()
                local ok, v = pcall(function() return localPlayer:GetAttribute("BountyNavigationActive") end)
                if ok and type(v) == "boolean" then
                    return v
                end
                return nil
            end,
            myMobs = function()
                return handle._soBounty.mobs
            end,
            activePuzzle = function()
                local sb = handle._soBounty
                if sb.puzzle ~= nil and sb.puzzle.open ~= false then
                    local pg = localPlayer:FindFirstChildOfClass("PlayerGui")
                    local jw = pg and pg:FindFirstChild("JewelryInspection")
                    if jw ~= nil and jw.Enabled == true then
                        sb.puzzleSawGui = true
                        return sb.puzzle
                    end
                    -- Если GUI уже открывалось и закрылось (после CLOSE [ESC / B]) — сразу сбрасываем, чтобы ре-открыть промпт!
                    if sb.puzzleSawGui then
                        sb.puzzle = nil
                        sb.puzzleSawGui = false
                        return nil
                    end
                    -- Если GUI так и не открылось за 1.5 с с момента получения пакета — очищаем
                    if sb.puzzleAt ~= nil and env.clock() - sb.puzzleAt > 1.5 then
                        sb.puzzle = nil
                    else
                        return sb.puzzle
                    end
                end
                return nil
            end,
            activeRohan = function()
                local sb = handle._soBounty
                if sb.rohan ~= nil then
                    -- Если прошло > 65 с без событий Drawing — сбрасываем, чтобы не зависнуть
                    if sb.rohanAt ~= nil and env.clock() - sb.rohanAt > 65.0 then
                        sb.rohan = nil
                        return nil
                    end
                    return sb.rohan
                end
                return nil
            end,
            activeVerity = function()
                local sb = handle._soBounty
                if sb.verity ~= nil then
                    if sb.verityAt ~= nil and env.clock() - sb.verityAt > 20.0 then
                        sb.verity = nil
                        return nil
                    end
                    return sb.verity
                end
                return nil
            end,
            activeKaraoke = function()
                local sb = handle._soBounty
                if sb.karaoke ~= nil then
                    local limit = math.max((sb.karaoke.duration or 30) + 25, 65)
                    if sb.karaokeAt ~= nil and env.clock() - sb.karaokeAt > limit then
                        sb.karaoke = nil
                        return nil
                    end
                    return sb.karaoke
                end
                return nil
            end,
            activeArmWrestling = function()
                local sb = handle._soBounty
                if sb.arm ~= nil then
                    if sb.armAt ~= nil and env.clock() - sb.armAt > 45.0 then
                        sb.arm = nil
                        return nil
                    end
                    return sb.arm
                end
                return nil
            end,
            sendArmWrestling = function(cmd, a1, a2, a3)
                local sb = handle._soBounty
                local rem = sb.armRemote
                if rem == nil then
                    pcall(function()
                        local rs = game:GetService("ReplicatedStorage")
                        local rems = rs and rs:FindFirstChild("Remotes")
                        rem = rems and rems:FindFirstChild("ArmWrestling")
                        sb.armRemote = rem
                    end)
                end
                if rem ~= nil then
                    pcall(function()
                        rem:FireServer(cmd, a1, a2, a3)
                    end)
                end
            end,
            activeTabletop = function()
                local sb = handle._soBounty
                if sb.tabletop ~= nil then
                    if sb.tabletopAt ~= nil and env.clock() - sb.tabletopAt > 45.0 then
                        sb.tabletop = nil
                        return nil
                    end
                    return sb.tabletop
                end
                return nil
            end,
            sendTabletop = function(cmd, payload)
                local sb = handle._soBounty
                local rem = sb.tabletopRemote
                if rem == nil then
                    pcall(function()
                        local rs = game:GetService("ReplicatedStorage")
                        local rems = rs and rs:FindFirstChild("Remotes")
                        rem = rems and rems:FindFirstChild("Tabletop")
                        sb.tabletopRemote = rem
                    end)
                end
                if rem ~= nil then
                    pcall(function()
                        rem:FireServer(cmd, payload)
                    end)
                end
            end,
            serverTime = function()
                if workspace ~= nil and workspace.GetServerTimeNow ~= nil then
                    local okT, t = pcall(function() return workspace:GetServerTimeNow() end)
                    if okT and type(t) == "number" then
                        return t
                    end
                end
                return env.clock()
            end,
            karaokeSongPlaying = function()
                local pg = localPlayer:FindFirstChildOfClass("PlayerGui")
                local kGui = pg and pg:FindFirstChild("Karaoke")
                if kGui == nil or kGui.Enabled ~= true then
                    return false
                end
                local rp = kGui:FindFirstChild("RhythmPanel")
                local songLbl = rp and rp:FindFirstChild("Song")
                if songLbl ~= nil and type(songLbl.Text) == "string" and songLbl.Text ~= "" and string.lower(songLbl.Text) ~= "ready" then
                    return true
                end
                return false
            end,
            sendKaraoke = function(cmd, a1, a2, a3)
                local sb = handle._soBounty
                local rem = sb.karaokeRemote
                if rem == nil then
                    pcall(function()
                        local rs = game:GetService("ReplicatedStorage")
                        local rems = rs and rs:FindFirstChild("Remotes")
                        rem = rems and rems:FindFirstChild("Karaoke")
                        sb.karaokeRemote = rem
                    end)
                end
                if rem ~= nil then
                    pcall(function()
                        if a3 ~= nil then
                            rem:FireServer(cmd, a1, a2, a3)
                        elseif a2 ~= nil then
                            rem:FireServer(cmd, a1, a2)
                        else
                            rem:FireServer(cmd, a1)
                        end
                    end)
                end
            end,
            makeV2 = function(x, y)
                if env.Vector2 ~= nil then
                    return env.Vector2.new(x, y)
                end
                return { X = x, Y = y }
            end,
            makeV3 = function(x, y, z)
                if env.Vector3 ~= nil then
                    return env.Vector3.new(x, y, z)
                end
                return { X = x, Y = y, Z = z }
            end,
            sendIncident = function(payload)
                local sb = handle._soBounty
                local rem = sb.remote
                if rem == nil then
                    pcall(function()
                        local rs = game:GetService("ReplicatedStorage")
                        local rems = rs and rs:FindFirstChild("Remotes")
                        rem = rems and rems:FindFirstChild("Bounty")
                        sb.remote = rem
                    end)
                end
                if rem ~= nil then
                    pcall(function() rem:FireServer("Incident", payload) end)
                end
            end,
            darbyState = function()
                local sb = handle._soBounty
                if sb.darby == nil then
                    sb.darby = stand_out_bounty.newDarbyState()
                end
                local pg = localPlayer:FindFirstChildOfClass("PlayerGui")
                local ssGui = pg and pg:FindFirstChild("StandStorage")
                local dGui = pg and pg:FindFirstChild("DarbyGoFish")
                local cam = workspace.CurrentCamera
                sb.darby.tableCamera = cam ~= nil and cam:FindFirstChild("StandStorageCamera") ~= nil
                if ssGui ~= nil and ssGui.Enabled == true then
                    if not sb.darby.storageOpen then
                        sb.darby.storageOpen = true
                        local t = env.clock() + 2.5
                        if t > (sb.darby.readyAt or 0) then
                            sb.darby.readyAt = t
                        end
                    end
                    -- Если мы снова на экране StandStorage (а DarbyGoFish закрыт и свежих событий Fish не было > 1.5 с) -> сброс active для рематча!
                    if sb.darby.active and (dGui == nil or dGui.Enabled == false)
                        and (sb.darbyAt == nil or env.clock() - sb.darbyAt > 1.5) then
                        sb.darby.active = false
                        sb.darby.sawGui = false
                    end
                elseif ssGui ~= nil and ssGui.Enabled == false and (dGui == nil or dGui.Enabled == false) then
                    sb.darby.storageOpen = false
                end
                if dGui ~= nil and dGui.Enabled == true then
                    sb.darby.sawGui = true
                end
                -- Сбрасываем active по закрытию DarbyGoFish ТОЛЬКО если окно реально открывалось
                -- (при прямом FishStart(1) клиент играет матч в фоне с DarbyGoFish.Enabled == false!)
                if sb.darby.active and sb.darby.sawGui and dGui ~= nil and dGui.Enabled == false
                    and sb.darbyAt ~= nil and env.clock() - sb.darbyAt > 4.5 then
                    sb.darby.active = false
                    sb.darby.sawGui = false
                end
                -- Если 20 сек не приходило ни одного события Fish — считаем партию завершённой для рематча
                if sb.darby.active and sb.darbyAt ~= nil and env.clock() - sb.darbyAt > 20.0 then
                    sb.darby.active = false
                    sb.darby.sawGui = false
                end
                return sb.darby
            end,
            sendStandStorage = function(cmd, arg)
                local sb = handle._soBounty
                local rem = sb.ssRemote
                if rem == nil then
                    pcall(function()
                        local rs = game:GetService("ReplicatedStorage")
                        local rems = rs and rs:FindFirstChild("Remotes")
                        rem = rems and rems:FindFirstChild("StandStorage")
                        sb.ssRemote = rem
                    end)
                end
                if rem ~= nil then
                    pcall(function() rem:FireServer(cmd, arg) end)
                end
            end,
            myPrompt = function()
                local sb = handle._soBounty
                local p = sb.prompt
                if p ~= nil and p.Parent ~= nil then
                    local isCd = false
                    pcall(function() isCd = p:IsA("ClickDetector") end)
                    if isCd then
                        local lx, ly, lz = stand_out_bounty.promptPosition(p)
                        if lx ~= nil then sb.px, sb.py, sb.pz = lx, ly, lz end
                        return p, sb.px, sb.py, sb.pz
                    elseif p.Enabled == true then
                        local okA, avail = pcall(function() return p:GetAttribute("StoryPromptAvailable") end)
                        if not (okA and avail == false) then
                            -- Читаем живую позицию p.Parent (O(1)) — важно для бегающих HarvestUnit1..3!
                            local lx, ly, lz = stand_out_bounty.promptPosition(p)
                            if lx ~= nil then
                                sb.px, sb.py, sb.pz = lx, ly, lz
                            end
                            return p, sb.px, sb.py, sb.pz
                        end
                    end
                end
                sb.prompt = nil
                return nil, nil, nil, nil
            end,
            holdPromptBegin = function(prompt, holdDur)
                if prompt == nil then return end
                local vim = env.virtualInputManager
                local defaultH = env.Enum and env.Enum.KeyCode and env.Enum.KeyCode.H
                if prompt == "__rawH" then
                    if vim ~= nil and defaultH ~= nil then
                        pcall(function() vim:SendKeyEvent(true, defaultH, false, game) end)
                    end
                    return
                end
                local isCd = false
                pcall(function() isCd = prompt:IsA("ClickDetector") end)
                if isCd then
                    if type(env.fireclickdetector) == "function" then
                        pcall(env.fireclickdetector, prompt)
                    end
                    return
                end
                -- Убираем RequiresLineOfSight локально, чтобы камень/столб/знак не перекрывал обзор промпту
                pcall(function() prompt.RequiresLineOfSight = false end)
                local kc = nil
                pcall(function() kc = prompt.KeyboardKeyCode end)
                kc = kc or defaultH
                if holdDur <= 0.05 and type(env.fireproximityprompt) == "function" then
                    pcall(env.fireproximityprompt, prompt)
                end
                if vim ~= nil and kc ~= nil then
                    pcall(function() vim:SendKeyEvent(true, kc, false, game) end)
                else
                    pcall(function() prompt:InputHoldBegin() end)
                end
            end,
            holdPromptEnd = function(prompt)
                if prompt == nil then return end
                local vim = env.virtualInputManager
                local defaultH = env.Enum and env.Enum.KeyCode and env.Enum.KeyCode.H
                if prompt == "__rawH" then
                    if vim ~= nil and defaultH ~= nil then
                        pcall(function() vim:SendKeyEvent(false, defaultH, false, game) end)
                    end
                    return
                end
                local isCd = false
                pcall(function() isCd = prompt:IsA("ClickDetector") end)
                if isCd then return end
                local kc = nil
                pcall(function() kc = prompt.KeyboardKeyCode end)
                kc = kc or defaultH
                if vim ~= nil and kc ~= nil then
                    pcall(function() vim:SendKeyEvent(false, kc, false, game) end)
                end
                pcall(function() prompt:InputHoldEnd() end)
            end,
            fightMobs = function(now, mobEntries, meX, meY, meZ)
                if handle._soMob.farmer == nil then return nil end
                local base = settings.standOutMobs
                local fightOpts = {
                    filter = "All",
                    nameFilter = "",
                    autoSummon = base.autoSummon,
                    autoSkill = base.autoSkill,
                    skills = base.skills,
                    autoR = base.autoR,
                    autoM1 = base.autoM1,
                    distance = base.distance,
                    method = base.method,
                }
                return handle._soMob.farmer:update(now, mobEntries, fightOpts, meX, meY, meZ)
            end,
            stopFighting = function()
                if handle._soMob.farmer ~= nil then
                    handle._soMob.farmer:stop()
                end
            end,
        })

        handle._soHowler.collector = stand_out_howler.new({
            readOpened = function()
                local ok, val = pcall(function()
                    local d = localPlayer and localPlayer:FindFirstChild("Data")
                    local st = d and d:FindFirstChild("Stats")
                    local sv = st and st:FindFirstChild("HowlerCasesOpened")
                    return sv and sv.Value or ""
                end)
                return ok and type(val) == "string" and val or ""
            end,
            teleportTo = function(x, y, z, lookX, lookY, lookZ)
                local character = localPlayer.Character
                local root = character and character:FindFirstChild("HumanoidRootPart")
                if root ~= nil then
                    if lookX ~= nil and lookY ~= nil and lookZ ~= nil and env.CFrame.lookAt ~= nil then
                        local pos = env.Vector3.new(x, y, z)
                        local lookFlat = env.Vector3.new(lookX, y, lookZ)
                        if (lookFlat - pos).Magnitude > 0.05 then
                            root.CFrame = env.CFrame.lookAt(pos, lookFlat)
                        else
                            root.CFrame = env.CFrame.new(x, y, z)
                        end
                        -- Наводим камеру на цель (сундук Cheap Jewelry), чтобы Stand Out сразу дал ей белую обводку фокуса
                        local cam = workspace.CurrentCamera
                        if cam ~= nil then
                            local dx, dz = lookX - x, lookZ - z
                            local d = math.sqrt(dx * dx + dz * dz)
                            if d > 0.05 then
                                local camPos = env.Vector3.new(x - (dx / d) * 4.5, y + 4.5, z - (dz / d) * 4.5)
                                pcall(function()
                                    cam.CFrame = env.CFrame.lookAt(camPos, env.Vector3.new(lookX, lookY, lookZ))
                                end)
                            end
                        end
                    else
                        root.CFrame = env.CFrame.new(x, y, z)
                    end
                    root.AssemblyLinearVelocity = env.Vector3.new(0, 0, 0)
                end
            end,
            sendHowler = function(cmd, arg)
                local sh = handle._soHowler
                local rem = sh.remote
                if rem == nil then
                    pcall(function()
                        local rs = game:GetService("ReplicatedStorage")
                        local rems = rs and rs:FindFirstChild("Remotes")
                        rem = rems and rems:FindFirstChild("HowlerCases")
                        sh.remote = rem
                    end)
                end
                if rem ~= nil then
                    pcall(function() rem:FireServer(cmd, arg) end)
                end
            end,
            scanLocal = function()
                return stand_out_howler.scanLocalProps(workspace)
            end,
            scanAreas = function()
                return stand_out_howler.scanAreaPoints(workspace)
            end,
            firePrompt = function(prompt)
                if type(env.fireproximityprompt) == "function" then
                    pcall(env.fireproximityprompt, prompt)
                end
            end,
            loadSpots = function()
                if type(env.isfile) == "function" and type(env.readfile) == "function" then
                    local ok, raw = pcall(function()
                        return env.isfile("calcite_so_howler_spots.txt") and env.readfile("calcite_so_howler_spots.txt") or ""
                    end)
                    if ok and type(raw) == "string" then
                        return raw
                    end
                end
                return ""
            end,
            saveSpots = function(text)
                if type(env.writefile) == "function" and type(text) == "string" then
                    pcall(env.writefile, "calcite_so_howler_spots.txt", text)
                end
            end,
            loadVisited = function()
                if type(env.isfile) == "function" and type(env.readfile) == "function" then
                    local ok, raw = pcall(function()
                        return env.isfile("calcite_so_howler_visited2.txt") and env.readfile("calcite_so_howler_visited2.txt") or ""
                    end)
                    if ok and type(raw) == "string" then
                        return raw
                    end
                end
                return ""
            end,
            saveVisited = function(text)
                if type(env.writefile) == "function" and type(text) == "string" then
                    pcall(env.writefile, "calcite_so_howler_visited2.txt", text)
                end
            end,
            notify = function(title, text)
                if ui ~= nil and ui.notify ~= nil then
                    ui.notify(title, text)
                end
            end,
        })
    end

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
        local s = settingsModule.inEffectInto(handle._inEffect, settings, mode)
        handle._inEffect = s
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
                local wantHitboxes = modes.has(mode, "Aim")
                local townWeapon = s.townWeapon and s.townWeapon.enabled
                local iaWeapon = s.iaWeapon and s.iaWeapon.enabled
                local standOutInfo = s.standOut and (s.standOut.stand or s.standOut.subAbility or s.standOut.weapon)
                for _, record in roster do
                    players.refresh(record, wantYba, wantHitboxes)
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
                    elseif standOutInfo then
                        local info = stand_out.playerInfo(record.player)
                        record.weapon = stand_out.format(info, s.standOut.stand, s.standOut.subAbility, s.standOut.weapon)
                    end
                end
            end

            if s.standOutPickup ~= nil and s.standOutPickup.enabled and now - handle._soPick.lastScan >= 1.0 then
                handle._soPick.lastScan = now
                handle._soPick.entries = stand_out_pickup.scan(workspace, s.standOutPickup)
            end
            if s.standOutMobs ~= nil and s.standOutMobs.enabled and now - handle._soMob.lastScan >= 0.8 then
                handle._soMob.lastScan = now
                local pNames = {}
                for _, pl in Players:GetPlayers() do
                    pNames[pl.Name] = true
                end
                handle._soMob.entries = stand_out_mobs.scan(workspace, pNames)
            end
            -- Подписываемся на ReplicatedStorage.Remotes.Bounty.OnClientEvent сразу в Stand Out,
            -- чтобы не пропустить DrawingOpen/Puzzle даже если Auto Bounty включили после открытия окна
            if handle._soBounty.runner ~= nil and handle._soBounty.remoteConn == nil and not handle._soBounty.remoteTried then
                local sb = handle._soBounty
                sb.remoteTried = true
                pcall(function()
                    local rs = game:GetService("ReplicatedStorage")
                    local rems = rs and rs:FindFirstChild("Remotes")
                    local bRem = rems and rems:FindFirstChild("Bounty")
                    if bRem ~= nil then
                        sb.remote = bRem
                        sb.remoteConn = bRem.OnClientEvent:Connect(function(kind, bountyId, sub, data)
                            if kind == "Incident" then
                                if sub == "ClosePuzzle" then
                                    sb.puzzle = nil
                                    sb.puzzleSawGui = false
                                    sb.verity = nil
                                    return
                                end
                                if sub == "VerityDialogue" or sub == "VerityDialogueClose" then
                                    local nowV = env.clock()
                                    sb.verity = stand_out_bounty.applyVerityEvent(sb.verity, bountyId, sub, data, nowV)
                                    sb.verityAt = nowV
                                    return
                                end
                                if type(sub) == "string" and (string.find(sub, "Drawing", 1, true) ~= nil or string.find(string.lower(sub), "rohan", 1, true) ~= nil) then
                                    local nowR = env.clock()
                                    sb.rohan = stand_out_bounty.applyRohanEvent(sb.rohan, bountyId, sub, data, nowR)
                                    sb.rohanAt = nowR
                                    return
                                end
                            end
                            if kind == "Incident" and type(data) == "table" then
                                -- Пре-челендж Rohan иногда приходит с sub="Puzzle" и без Target/Values/Placed (только Token для DrawingChallenge)
                                if sub == "Puzzle" and data.Kind == "Drawing" and data.Token ~= nil then
                                    local nowR = env.clock()
                                    sb.rohan = stand_out_bounty.applyRohanEvent(sb.rohan, bountyId, "DrawingIntro", data, nowR)
                                    sb.rohanAt = nowR
                                    return
                                end
                                local isPuzzleEvt = sub == "Puzzle"
                                    or (sb.puzzle ~= nil and data.Token ~= nil and data.Token == sb.puzzle.token)
                                    or (sb.puzzle ~= nil and type(sub) == "string" and string.find(string.lower(sub), "puzzle", 1, true) ~= nil)
                                if isPuzzleEvt then
                                    if data.Open == false then
                                        sb.puzzle = nil
                                        sb.puzzleSawGui = false
                                        return
                                    end
                                    local ver = data.Version
                                    if ver == nil and sb.puzzle ~= nil then ver = sb.puzzle.serverVersion end
                                    ver = ver or 0
                                    sb.puzzle = {
                                        id = bountyId or (sb.puzzle and sb.puzzle.id),
                                        token = data.Token or (sb.puzzle and sb.puzzle.token),
                                        kind = data.Kind or (sb.puzzle and sb.puzzle.kind),
                                        version = ver,
                                        serverVersion = ver,
                                        sentCount = 0,
                                        sentAt = nil,
                                        target = data.Target or (sb.puzzle and sb.puzzle.target),
                                        values = data.Values or (sb.puzzle and sb.puzzle.values),
                                        placed = data.Placed or (sb.puzzle and sb.puzzle.placed),
                                        open = true,
                                        attempted = {},
                                    }
                                    sb.puzzleSawGui = false
                                    sb.puzzleAt = env.clock()
                                end
                            end
                        end)
                    end
                end)
            end
            -- Подписываемся на ReplicatedStorage.Remotes.Karaoke.OnClientEvent сразу в Stand Out (Usagi's Karaoke Night)
            if handle._soBounty.runner ~= nil and handle._soBounty.karaokeConn == nil and not handle._soBounty.karaokeTried then
                local sb = handle._soBounty
                sb.karaokeTried = true
                pcall(function()
                    local rs = game:GetService("ReplicatedStorage")
                    local rems = rs and rs:FindFirstChild("Remotes")
                    local kRem = rems and rems:FindFirstChild("Karaoke")
                    if kRem ~= nil then
                        sb.karaokeRemote = kRem
                        sb.karaokeConn = kRem.OnClientEvent:Connect(function(kind, data)
                            local nowK = env.clock()
                            local nowSrv = nowK
                            if workspace ~= nil and workspace.GetServerTimeNow ~= nil then
                                local okT, t = pcall(function() return workspace:GetServerTimeNow() end)
                                if okT and type(t) == "number" then
                                    nowSrv = t
                                end
                            end
                            sb.karaoke = stand_out_bounty.applyKaraokeEvent(sb.karaoke, kind, data, nowSrv, nowK)
                            sb.karaokeAt = nowK
                        end)
                    end
                end)
            end
            -- Подписываемся на ReplicatedStorage.Remotes.ArmWrestling.OnClientEvent сразу в Stand Out (Paco's Challenge)
            if handle._soBounty.runner ~= nil and handle._soBounty.armConn == nil and not handle._soBounty.armTried then
                local sb = handle._soBounty
                sb.armTried = true
                pcall(function()
                    local rs = game:GetService("ReplicatedStorage")
                    local rems = rs and rs:FindFirstChild("Remotes")
                    local aRem = rems and rems:FindFirstChild("ArmWrestling")
                    if aRem ~= nil then
                        sb.armRemote = aRem
                        sb.armConn = aRem.OnClientEvent:Connect(function(kind, data)
                            local nowA = env.clock()
                            sb.arm = stand_out_bounty.applyArmWrestlingEvent(sb.arm, kind, data, nowA)
                            sb.armAt = nowA
                        end)
                    end
                end)
            end
            -- Подписываемся на ReplicatedStorage.Remotes.Tabletop.OnClientEvent сразу в Stand Out (Iced Tea Run)
            if handle._soBounty.runner ~= nil and handle._soBounty.tabletopConn == nil and not handle._soBounty.tabletopTried then
                local sb = handle._soBounty
                sb.tabletopTried = true
                pcall(function()
                    local rs = game:GetService("ReplicatedStorage")
                    local rems = rs and rs:FindFirstChild("Remotes")
                    local tRem = rems and rems:FindFirstChild("Tabletop")
                    if tRem ~= nil then
                        sb.tabletopRemote = tRem
                        sb.tabletopConn = tRem.OnClientEvent:Connect(function(kind, data)
                            local nowT = env.clock()
                            sb.tabletop = stand_out_bounty.applyTabletopEvent(sb.tabletop, kind, data, nowT)
                            sb.tabletopAt = nowT
                        end)
                    end
                end)
            end
            if s.standOutBounty ~= nil and s.standOutBounty.enabled then
                local pNames = {}
                for _, pl in Players:GetPlayers() do
                    pNames[pl.Name] = true
                end
                local sb = handle._soBounty
                -- Подписываемся на ReplicatedStorage.Remotes.StandStorage.OnClientEvent для D'Arby Go Fish
                if sb.ssConn == nil and not sb.ssTried then
                    sb.ssTried = true
                    pcall(function()
                        local rs = game:GetService("ReplicatedStorage")
                        local rems = rs and rs:FindFirstChild("Remotes")
                        local ssRem = rems and rems:FindFirstChild("StandStorage")
                        if ssRem ~= nil then
                            sb.ssRemote = ssRem
                            if sb.darby == nil then
                                sb.darby = stand_out_bounty.newDarbyState()
                            end
                            sb.ssConn = ssRem.OnClientEvent:Connect(function(kind, data)
                                if sb.darby == nil then
                                    sb.darby = stand_out_bounty.newDarbyState()
                                end
                                local nowT = env.clock()
                                stand_out_bounty.applyDarbyEvent(sb.darby, kind, data, nowT)
                                if kind == "Fish" then
                                    sb.darbyAt = nowT
                                end
                            end)
                        end
                    end)
                end
                local tx, ty, tz = nil, nil, nil
                local okT, pos = pcall(function() return localPlayer:GetAttribute("VisibleBountyTrackerPosition") end)
                if okT and pos ~= nil and pos.X ~= nil and pos.Y ~= nil and pos.Z ~= nil then
                    tx, ty, tz = pos.X, pos.Y, pos.Z
                end
                local uiSnap = stand_out_bounty.readUi(localPlayer:FindFirstChildOfClass("PlayerGui"))
                sb.mobs = stand_out_bounty.scanMyMobs(workspace, localPlayer.UserId, pNames, localPlayer.Name, tx, ty, tz, uiSnap.trackerObjective)
                local allowNpc = stand_out_bounty.isNpcObjective(uiSnap.trackerObjective)
                local objChanged = sb.lastObjective ~= uiSnap.trackerObjective
                sb.lastObjective = uiSnap.trackerObjective
                -- Быстрый скан нашей папки BountyWorld.Party_<UserId> (0.25 с) для мгновенного перехода Catch1->Catch2->Box3->Assembly;
                -- тяжёлый фолбэк по Workspace.Game — не чаще раза в 1.0 с
                local cachedOk = false
                if not objChanged and sb.prompt ~= nil and sb.prompt.Parent ~= nil then
                    local isCd = false
                    pcall(function() isCd = sb.prompt:IsA("ClickDetector") end)
                    -- ClickDetector (NPC вроде Dragona) не кэшируем надолго, чтобы включившийся промпт в Party_<UserId> сразу побеждал
                    if not isCd and sb.prompt.Enabled == true then
                        cachedOk = true
                        local okA, avail = pcall(function() return sb.prompt:GetAttribute("StoryPromptAvailable") end)
                        if okA and avail == false then cachedOk = false end
                    end
                    -- Если трекер переехал даже на 3 студа (напр. Box2 -> Box3 на том же столе, ~4.3 ст!) — сразу пересканируем
                    if cachedOk and tx ~= nil and sb.px ~= nil and not stand_out_bounty.isMovingPrompt(sb.prompt) then
                        local ddx, ddy, ddz = sb.px - tx, sb.py - ty, sb.pz - tz
                        if ddx * ddx + ddy * ddy + ddz * ddz > 9 then
                            cachedOk = false
                        end
                    end
                end
                if not cachedOk then
                    local allowFallback = (now - sb.lastPromptScan >= 2.5)
                    if allowFallback then
                        sb.lastPromptScan = now
                    end
                    sb.prompt, sb.px, sb.py, sb.pz = stand_out_bounty.findMyPrompt(workspace, localPlayer.UserId, tx, ty, tz, allowFallback, allowNpc, uiSnap.trackerObjective)
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
        do
            local c = handle._cam
            local cf = camera.CFrame
            local fov = camera.FieldOfView
            if cf ~= nil and cf.GetComponents ~= nil and type(fov) == "number" and fov > 0 and screenH > 0 then
                c.x, c.y, c.z, c.r00, c.r01, c.r02, c.r10, c.r11, c.r12, c.r20, c.r21, c.r22 = cf:GetComponents()
                c.halfW = screenW * 0.5
                c.halfH = screenH * 0.5
                c.focal = c.halfH / math.tan(math.rad(fov) * 0.5)
                c.fast = true
            else
                c.fast = false
            end
        end

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

        if s.enabled and not overlayHidden then
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

        -- Player WalkSpeed / JumpPower: применяем каждый кадр пока включено, восстанавливаем при выключении;
        -- когда оба выключены и восстанавливать нечего — вообще не создаём pcall и не ищем Humanoid
        do
            local cm = handle._charMove
            local wantWs = s.walkSpeed ~= nil and s.walkSpeed.enabled == true
            local wantJp = s.jumpPower ~= nil and s.jumpPower.enabled == true
            if wantWs or wantJp or cm.wasWs or cm.wasJp then
                pcall(function()
                    local ch = localPlayer and localPlayer.Character
                    if ch ~= cm.lastChar then
                        cm.lastChar = ch
                        cm.savedWs = nil
                        cm.savedJp = nil
                        cm.savedUseJp = nil
                        cm.wasWs = false
                        cm.wasJp = false
                    end
                    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                    if hum ~= nil then
                        if wantWs and (ui.walkSpeedActive == nil or ui.walkSpeedActive()) then
                            if not cm.wasWs then
                                cm.savedWs = hum.WalkSpeed
                                cm.wasWs = true
                            end
                            hum.WalkSpeed = s.walkSpeed.value or 32
                        elseif cm.wasWs then
                            cm.wasWs = false
                            if cm.savedWs ~= nil then hum.WalkSpeed = cm.savedWs end
                            cm.savedWs = nil
                        end

                        if wantJp and (ui.jumpPowerActive == nil or ui.jumpPowerActive()) then
                            if not cm.wasJp then
                                cm.savedJp = hum.JumpPower
                                cm.savedUseJp = hum.UseJumpPower
                                cm.wasJp = true
                            end
                            hum.UseJumpPower = true
                            hum.JumpPower = s.jumpPower.value or 80
                        elseif cm.wasJp then
                            cm.wasJp = false
                            if cm.savedUseJp ~= nil then hum.UseJumpPower = cm.savedUseJp end
                            if cm.savedJp ~= nil then hum.JumpPower = cm.savedJp end
                            cm.savedUseJp = nil
                            cm.savedJp = nil
                        end
                    end
                end)
            end
        end

        -- NoClip (Town): Humanoid каждый тик возвращает CanCollide=true, поэтому цикл нужен каждый кадр;
        -- при выключении шаг восстанавливает коллизию у частей, которые мы трогали
        if s.noclip ~= nil then
            noclipper:step(s.noclip.enabled == true)
        end

        -- HUD overlays: watermark (всегда), reload bar (MVS), hotkeys панель (обновляем не чаще 1 раза в 0.12с)
        if s.watermark ~= nil then
            local dt = 1 / 60
            hud.step(dt, now, not overlayHidden and s.watermark.enabled == true, not overlayHidden and s.reloadBar and s.reloadBar.enabled == true)
            local hkShow = (not overlayHidden and s.hotkeys ~= nil and s.hotkeys.enabled == true)
            local cm = handle._charMove
            if hkShow ~= cm.hkVis or (hkShow and (cm.hkAt == nil or now - cm.hkAt >= 0.12)) then
                cm.hkVis = hkShow
                cm.hkAt = now
                if hkShow then
                    hud.setHotkeys(ui.hotkeys(s), true)
                else
                    hud.setHotkeys(nil, false)
                end
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

        -- Stand Out Howler's Cases: подписка на Reveal + шаг автосбора (имеет приоритет над автофармом пока активен)
        local howlerBusy = false
        if modes.has(mode, "StandOutPickup") and handle._soHowler.collector ~= nil then
            if handle._soHowler.conn == nil and not handle._soHowler.tried then
                handle._soHowler.tried = true
                pcall(function()
                    local rs = game:GetService("ReplicatedStorage")
                    local rems = rs and rs:FindFirstChild("Remotes")
                    local hRem = rems and rems:FindFirstChild("HowlerCases")
                    if hRem ~= nil then
                        handle._soHowler.remote = hRem
                        handle._soHowler.conn = hRem.OnClientEvent:Connect(function(ev, id, cf)
                            if ev == "Reveal" and type(id) == "string" and cf ~= nil and cf.Position ~= nil then
                                handle._soHowler.collector:onReveal(id, cf.Position.X, cf.Position.Y, cf.Position.Z)
                            end
                        end)
                    end
                end)
            end
            local okH, busyH = pcall(function()
                return handle._soHowler.collector:update(now, haveLocal and localX or nil, haveLocal and localY or nil, haveLocal and localZ or nil)
            end)
            if okH then
                howlerBusy = busyH == true
            end
            ui.setStandOutHowler(handle._soHowler.collector.statusText)
        end

        -- Stand Out Auto Pick Up: телепорт к ближайшему мировому предмету / закопанному припасу и подбор
        local soPick = handle._soPick
        if not howlerBusy and s.standOutPickup ~= nil and s.standOutPickup.enabled and haveLocal and soPick.picker ~= nil then
            if not soPick.wasOn then
                soPick.entries = stand_out_pickup.scan(workspace, s.standOutPickup)
                soPick.wasOn = true
            end
            local okPick, errPick = pcall(function()
                soPick.picker:update(now, soPick.entries, s.standOutPickup, localX, localY, localZ)
            end)
            if not okPick then
                warn("Calcite StandOutPickup: " .. tostring(errPick))
            end
            ui.setStandOutPickup(soPick.picker.taken, soPick.picker.lastTargetName)
        elseif soPick.wasOn then
            soPick.wasOn = false
            if soPick.picker ~= nil then
                soPick.picker:stop()
                ui.setStandOutPickup(soPick.picker.taken, "")
            end
        end

        -- Stand Out Mob Farming: работает только пока свой персонаж жив; после респавна сразу пересканирует мобов
        local soMob = handle._soMob
        local localAlive = haveLocal
        if localAlive then
            local myChar = localPlayer.Character
            local myHum = myChar and myChar:FindFirstChildOfClass("Humanoid")
            if myHum == nil or myHum.Health <= 0 then
                localAlive = false
            end
        end
        local itemBusy = howlerBusy or (s.standOutPickup ~= nil and s.standOutPickup.enabled
            and soPick.picker ~= nil and soPick.picker.target ~= nil)
        -- Stand Out Auto Bounty (использует Farm Config для боя с мобами баунти; уступает Item farm на подбор)
        local soBounty = handle._soBounty
        local bountyOn = s.standOutBounty ~= nil and s.standOutBounty.enabled and localAlive and soBounty.runner ~= nil
        if bountyOn then
            if not soBounty.wasOn then
                local pNames = {}
                for _, pl in Players:GetPlayers() do
                    pNames[pl.Name] = true
                end
                local tx, ty, tz = nil, nil, nil
                local okT, pos = pcall(function() return localPlayer:GetAttribute("VisibleBountyTrackerPosition") end)
                if okT and pos ~= nil and pos.X ~= nil and pos.Y ~= nil and pos.Z ~= nil then
                    tx, ty, tz = pos.X, pos.Y, pos.Z
                end
                local uiSnap = stand_out_bounty.readUi(localPlayer:FindFirstChildOfClass("PlayerGui"))
                soBounty.mobs = stand_out_bounty.scanMyMobs(workspace, localPlayer.UserId, pNames, localPlayer.Name, tx, ty, tz, uiSnap.trackerObjective)
                soBounty.wasOn = true
            end
            if not itemBusy then
                local okB, errB = pcall(function()
                    soBounty.runner:update(now, s.standOutBounty, localX, localY, localZ)
                end)
                if not okB then
                    warn("Calcite StandOutBounty: " .. tostring(errB))
                end
                ui.setStandOutBounty(soBounty.runner.completed, soBounty.runner.statusText)
            end
        elseif soBounty.wasOn then
            soBounty.wasOn = false
            soBounty.prompt = nil
            soBounty.lastPromptScan = -99
            if soBounty.runner ~= nil then
                soBounty.runner:stop()
                ui.setStandOutBounty(soBounty.runner.completed, "")
            end
        end

        -- Stand Out Mob Farming (уступает Item farm и Auto Bounty)
        if s.standOutMobs ~= nil and s.standOutMobs.enabled and localAlive and soMob.farmer ~= nil and not bountyOn then
            if not soMob.wasOn then
                local pNames = {}
                for _, pl in Players:GetPlayers() do
                    pNames[pl.Name] = true
                end
                soMob.entries = stand_out_mobs.scan(workspace, pNames)
                soMob.wasOn = true
            end
            if not itemBusy then
                local okMob, errMob = pcall(function()
                    soMob.farmer:update(now, soMob.entries, s.standOutMobs, localX, localY, localZ)
                end)
                if not okMob then
                    warn("Calcite StandOutMobs: " .. tostring(errMob))
                end
                ui.setStandOutMob(soMob.farmer.kills, soMob.farmer.statusText)
            end
        elseif soMob.wasOn then
            soMob.wasOn = false
            if soMob.farmer ~= nil then
                soMob.farmer:stop()
                ui.setStandOutMob(soMob.farmer.kills, "")
            end
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

    handle.unload = unload
    handle.version = main.version
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
local choiceLabels = { "Авто", "Universal", "YBA", "Blox Strike", "Steal an Egg", "Town", "MVS", "Item Asylum", "Rivals", "Stand Out" }
local choiceOf = { ["Авто"] = "Auto", ["Universal"] = "Universal", ["YBA"] = "Yba", ["Blox Strike"] = "Strike", ["Steal an Egg"] = "StealEgg", ["Town"] = "Town", ["MVS"] = "Mvs", ["Item Asylum"] = "ItemAsylum", ["Rivals"] = "Rivals", ["Stand Out"] = "StandOut" }

-- Для KeyPicker с SyncToggleState = true: в режиме Hold страхуем проверку GetState() каждый кадр
-- (если окно потеряло фокус или открыт чат, Hold сразу отпускается), в Toggle / None решает сам тумблер
local function syncKeyActive(opt)
    if opt == nil then return true end
    local okMode, mode = pcall(function() return opt.Mode end)
    if not okMode or mode ~= "Hold" then return true end
    local okKey, keyValue = pcall(function() return opt.Value end)
    if not okKey or keyValue == nil or keyValue == "None" or tostring(keyValue) == "None" then
        return true
    end
    local okState, state = pcall(function() return opt:GetState() end)
    return okState and state == true
end

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

    -- Stand Out ESP: стенд, спек (SubAbility) и оружие из Player.Data (stand_out.lua)
    local standOutGroup = visualsTab:AddRightGroupbox("Stand Out")
    toggle(standOutGroup, "StandOutStand", "Стенд", settings.standOut, "stand")
    toggle(standOutGroup, "StandOutSubAbility", "Спек", settings.standOut, "subAbility")
    toggle(standOutGroup, "StandOutWeapon", "Оружие", settings.standOut, "weapon")

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

    -- Stand Out AutoFarm: Item farm + Mob Farming + Farm Config (grouped in one local table for Luau register budget)
    local soFarm = {}
    soFarm.itemGroup = farmTab:AddLeftGroupbox("Item farm")
    toggle(soFarm.itemGroup, "StandOutPickupEnabled", "Автоподбор", settings.standOutPickup, "enabled")
    toggle(soFarm.itemGroup, "StandOutPickupWorld", "Предметы на карте", settings.standOutPickup, "worldItems")
    toggle(soFarm.itemGroup, "StandOutPickupBuried", "Закопанные припасы", settings.standOutPickup, "buried")
    toggle(soFarm.itemGroup, "StandOutPickupSeaTrash", "Морской мусор (R)", settings.standOutPickup, "seaTrash")
    toggle(soFarm.itemGroup, "StandOutPickupReturn", "Возвращаться назад", settings.standOutPickup, "returnBack")
    toggle(soFarm.itemGroup, "StandOutPickupHop", "Смена сервера если пусто", settings.standOutPickup, "hopWhenEmpty")
    soFarm.pickupCount = soFarm.itemGroup:AddLabel("Подобрано: 0")

    soFarm.mobGroup = farmTab:AddLeftGroupbox("Mob Farming")
    toggle(soFarm.mobGroup, "StandOutMobEnabled", "Включить", settings.standOutMobs, "enabled")
    do
        local filterLabels = { "Все мобы", "Без боссов", "Только боссы" }
        local filterOf = { ["Все мобы"] = "All", ["Без боссов"] = "NoBosses", ["Только боссы"] = "BossesOnly" }
        local filterIdx = if settings.standOutMobs.filter == "NoBosses" then 2
            elseif settings.standOutMobs.filter == "BossesOnly" then 3 else 1
        soFarm.mobGroup:AddDropdown("StandOutMobFilter", {
            Text = "Фильтр мобов", Values = filterLabels, Default = filterIdx,
        })
        Options.StandOutMobFilter:OnChanged(function()
            settings.standOutMobs.filter = filterOf[Options.StandOutMobFilter.Value] or "All"
        end)
        soFarm.mobGroup:AddInput("StandOutMobName", {
            Text = "Имя моба", Default = settings.standOutMobs.nameFilter or "", Placeholder = "Seal, DIO...",
        })
        Options.StandOutMobName:OnChanged(function()
            settings.standOutMobs.nameFilter = tostring(Options.StandOutMobName.Value or "")
        end)
    end
    soFarm.mobStatus = soFarm.mobGroup:AddLabel("Убито: 0")

    soFarm.cfgGroup = farmTab:AddRightGroupbox("Farm Config")
    toggle(soFarm.cfgGroup, "StandOutMobAutoSummon", "Auto Summon (E)", settings.standOutMobs, "autoSummon")
    toggle(soFarm.cfgGroup, "StandOutMobAutoSkill", "Auto Skill", settings.standOutMobs, "autoSkill")
    do
        local skillList = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
        local skillDefault = {}
        for _, k in skillList do
            if settings.standOutMobs.skills[k] then
                table.insert(skillDefault, k)
            end
        end
        soFarm.cfgGroup:AddDropdown("StandOutMobSkills", {
            Text = "Скиллы", Values = skillList, Default = skillDefault, Multi = true,
        })
        Options.StandOutMobSkills:OnChanged(function()
            local chosen = Options.StandOutMobSkills.Value or {}
            for _, k in skillList do
                settings.standOutMobs.skills[k] = chosen[k] == true
            end
        end)
    end
    toggle(soFarm.cfgGroup, "StandOutMobAutoR", "Auto Heavy (R)", settings.standOutMobs, "autoR")
    toggle(soFarm.cfgGroup, "StandOutMobAutoM1", "M1 на кулдауне", settings.standOutMobs, "autoM1")
    slider(soFarm.cfgGroup, "StandOutMobDistance", "Дистанция", settings.standOutMobs, "distance", 2, 20, " ст")
    do
        local methodList = { "Behind", "Below", "Over", "Front" }
        soFarm.cfgGroup:AddDropdown("StandOutMobMethod", {
            Text = "Метод", Values = methodList,
            Default = table.find(methodList, settings.standOutMobs.method) or 1,
        })
        Options.StandOutMobMethod:OnChanged(function()
            settings.standOutMobs.method = Options.StandOutMobMethod.Value or "Behind"
        end)
    end

    soFarm.bountyGroup = farmTab:AddRightGroupbox("Auto Bounty")
    toggle(soFarm.bountyGroup, "StandOutBountyEnabled", "Включить", settings.standOutBounty, "enabled")
    do
        local tierLabels = { "Максимум (авто)", "1", "2", "3", "4", "5", "6", "7", "8" }
        local tierDefault = if settings.standOutBounty.tier == "Max" then 1
            else (table.find(tierLabels, tostring(settings.standOutBounty.tier)) or 1)
        soFarm.bountyGroup:AddDropdown("StandOutBountyTier", {
            Text = "Тир", Values = tierLabels, Default = tierDefault,
        })
        Options.StandOutBountyTier:OnChanged(function()
            local v = Options.StandOutBountyTier.Value
            settings.standOutBounty.tier = if v == "Максимум (авто)" then "Max" else tostring(v or "Max")
        end)
    end
    toggle(soFarm.bountyGroup, "StandOutBountySkipIncidents", "Пропускать мини-игры", settings.standOutBounty, "skipIncidents")
    soFarm.bountyStatus = soFarm.bountyGroup:AddLabel("Завершено: 0")

    soFarm.howlerGroup = farmTab:AddRightGroupbox("Howler's Cases")
    soFarm.howlerGroup:AddButton({
        Text = "Collect Howler's Case",
        Func = function()
            if deps.onStandOutHowler ~= nil then
                deps.onStandOutHowler()
            end
        end,
    })
    soFarm.howlerStatus = soFarm.howlerGroup:AddLabel("Кейсы: 0/10")

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

    -- WalkSpeed / JumpPower (группируется в soFarm чтобы не тратить регистры menu.create)
    soFarm.charGroup = playerTab:AddLeftGroupbox("Персонаж")
    toggle(soFarm.charGroup, "WalkSpeedEnabled", "WalkSpeed", settings.walkSpeed, "enabled"):AddKeyPicker("WalkSpeedKey", {
        Default = "None",
        Mode = "Toggle",
        Modes = { "Toggle", "Hold" },
        SyncToggleState = true,
        NoUI = true,
        Text = "WalkSpeed",
    })
    slider(soFarm.charGroup, "WalkSpeedValue", "Скорость ходьбы", settings.walkSpeed, "value", 16, 200, " st/s")
    toggle(soFarm.charGroup, "JumpPowerEnabled", "JumpPower", settings.jumpPower, "enabled"):AddKeyPicker("JumpPowerKey", {
        Default = "None",
        Mode = "Toggle",
        Modes = { "Toggle", "Hold" },
        SyncToggleState = true,
        NoUI = true,
        Text = "JumpPower",
    })
    slider(soFarm.charGroup, "JumpPowerValue", "Сила прыжка", settings.jumpPower, "value", 50, 250, "")

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
        playerTab:SetVisible(modes.has(mode, "Bhop") or modes.has(mode, "Fly") or modes.has(mode, "NoClip")
            or modes.has(mode, "CharMove"))
        bhopGroup:SetVisible(modes.has(mode, "Bhop"))
        flyGroup:SetVisible(modes.has(mode, "Fly"))
        noclipGroup:SetVisible(modes.has(mode, "NoClip"))
        soFarm.charGroup:SetVisible(modes.has(mode, "CharMove"))
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
        standOutGroup:SetVisible(modes.has(mode, "StandOutInfo"))
        -- в MVS visibleOnly форсится в settings.inEffect, тоггл прячем
        pcall(function() visibleOnlyToggle:SetVisible(mode ~= "Mvs") end)
        -- Reload bar работает только в MVS (gated через MvsGun), прячем toggle в других режимах
        pcall(function() reloadBarToggle:SetVisible(modes.has(mode, "MvsGun")) end)
        -- Hit logs — только в Town (там autoFire шлёт FireEvent сам и мы знаем кому попали)
        pcall(function() hitLogsToggle:SetVisible(modes.has(mode, "TownGun")) end)
        npcTab:SetVisible(modes.has(mode, "Npc"))
        stealTab:SetVisible(modes.has(mode, "Steal"))
        teleportTab:SetVisible(modes.has(mode, "Teleport"))
        farmTab:SetVisible(modes.has(mode, "AutoFarm") or modes.has(mode, "StandOutPickup")
            or modes.has(mode, "StandOutMobs") or modes.has(mode, "StandOutBounty"))
        farmGroup:SetVisible(modes.has(mode, "AutoFarm"))
        soFarm.itemGroup:SetVisible(modes.has(mode, "StandOutPickup"))
        soFarm.mobGroup:SetVisible(modes.has(mode, "StandOutMobs"))
        soFarm.cfgGroup:SetVisible(modes.has(mode, "StandOutMobs") or modes.has(mode, "StandOutBounty"))
        soFarm.bountyGroup:SetVisible(modes.has(mode, "StandOutBounty"))
        soFarm.howlerGroup:SetVisible(modes.has(mode, "StandOutPickup"))
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

    -- Stand Out Auto Pick Up & Mob Farming status labels
    function ui.setStandOutPickup(count, targetName)
        local text = string.format("Подобрано: %d", count)
        if targetName ~= nil and targetName ~= "" then
            text = text .. " | " .. targetName
        end
        if text ~= soFarm.shownPickup then
            soFarm.shownPickup = text
            soFarm.pickupCount:SetText(text)
        end
    end

    function ui.setStandOutMob(kills, targetText)
        local text = string.format("Убито: %d", kills)
        if targetText ~= nil and targetText ~= "" then
            text = text .. " | " .. targetText
        end
        if text ~= soFarm.shownMob then
            soFarm.shownMob = text
            soFarm.mobStatus:SetText(text)
        end
    end

    function ui.setStandOutBounty(completed, statusText)
        local text = string.format("Завершено: %d", completed)
        if statusText ~= nil and statusText ~= "" then
            text = text .. " | " .. statusText
        end
        if text ~= soFarm.shownBounty then
            soFarm.shownBounty = text
            soFarm.bountyStatus:SetText(text)
        end
    end

    function ui.setStandOutHowler(statusText)
        local text = statusText or "Кейсы: 0/10"
        if text ~= soFarm.shownHowler then
            soFarm.shownHowler = text
            soFarm.howlerStatus:SetText(text)
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

    function ui.walkSpeedActive()
        return syncKeyActive(Options.WalkSpeedKey)
    end

    function ui.jumpPowerActive()
        return syncKeyActive(Options.JumpPowerKey)
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
        if modes.has(modes.resolve(settings.modeChoice, deps.universeId), "CharMove") then
            local wsKey = keyOf(Options.WalkSpeedKey)
            local wsBound = wsKey ~= "None" and wsKey ~= "?"
            if settings.walkSpeed and (settings.walkSpeed.enabled or wsBound) then
                table.insert(out, {
                    id = "walkspeed",
                    name = "WalkSpeed",
                    key = wsBound and wsKey or "ON",
                    active = settings.walkSpeed.enabled == true and ui.walkSpeedActive(),
                })
            end
            local jpKey = keyOf(Options.JumpPowerKey)
            local jpBound = jpKey ~= "None" and jpKey ~= "?"
            if settings.jumpPower and (settings.jumpPower.enabled or jpBound) then
                table.insert(out, {
                    id = "jumppower",
                    name = "JumpPower",
                    key = jpBound and jpKey or "ON",
                    active = settings.jumpPower.enabled == true and ui.jumpPowerActive(),
                })
            end
        end
        return out
    end

    -- while the window is open the mouse is the user's
    function ui.menuOpen()
        return Library.Toggled == true
    end

    function ui.menuRect()
        local frame = Window and Window.MainFrame
        if frame == nil then return nil end
        local ok, pos, sz = pcall(function()
            return frame.AbsolutePosition, frame.AbsoluteSize
        end)
        if ok and pos ~= nil and sz ~= nil then
            return pos.X, pos.Y, sz.X, sz.Y
        end
        return nil
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

-- Stand Out: open-world JoJo RPG/PvP (no Roblox Teams; Player.Data has Stand, SubAbility, Weapon)
modes.standout_universe = 8172250815

-- what the user can pick in the menu, in the order of the list there
modes.choices = { "Auto", "Universal", "Yba", "Strike", "StealEgg", "Town", "Mvs", "ItemAsylum", "Rivals", "StandOut" }

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
    -- Stand Out: без команд; ESP игроков + автоподбор + фарм мобов + авто-баунти + WalkSpeed/JumpPower
    StandOut = { Players = true, Health = true, StandOutInfo = true, StandOutPickup = true, StandOutMobs = true, StandOutBounty = true, CharMove = true },
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

    if modes.standout_universe ~= 0 and universeId == modes.standout_universe then
        return "StandOut"
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

    if mode == "StandOut" then
        return "Stand Out"
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
-- wantHitboxes (defaults true) collects body parts for Aim; skipped in modes without Aim to save FindFirstChild calls
function players.refresh(record, wantYba, wantHitboxes)
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
    if wantHitboxes ~= false then
        record.parts = hitbox.collect(character)
    end

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
        -- Stand Out ESP: стенд, спек (SubAbility) и оружие из Player.Data (stand_out.lua)
        standOut = {
            stand = true,
            subAbility = true,
            weapon = false,
        },
        -- Stand Out Auto Pick Up: телепорт к мировым предметам и закопанным припасам (stand_out_pickup.lua)
        standOutPickup = {
            enabled = false,
            worldItems = true,
            buried = true,
            seaTrash = false,
            returnBack = true,
            hopWhenEmpty = false,
        },
        -- Stand Out Mob Farming: фарм враждебных мобов (stand_out_mobs.lua)
        standOutMobs = {
            enabled = false,
            filter = "All",       -- "All" | "NoBosses" | "BossesOnly"
            nameFilter = "",      -- подстрока имени моба (пусто = любой)
            autoSummon = true,
            autoSkill = true,
            skills = { ["1"] = true, ["2"] = true, ["3"] = true, ["4"] = true },
            autoR = true,
            autoM1 = true,
            distance = 6,
            method = "Behind",    -- "Behind" | "Below" | "Over" | "Front"
        },
        -- Stand Out Auto Bounty: баунти у Petyr на лучшем доступном тире (stand_out_bounty.lua)
        standOutBounty = {
            enabled = false,
            tier = "Max",         -- "Max" | "1".."8"
            skipIncidents = true, -- пропускать инциденты с ручными мини-играми
        },
        -- Player WalkSpeed / JumpPower
        walkSpeed = {
            enabled = false,
            value = 32,
        },
        jumpPower = {
            enabled = false,
            value = 80,
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

-- copies shallow fields of src into dst (reusing dst to avoid per-frame table.clone churn)
local function copyInto(dst, src)
    if src == nil then
        return nil
    end
    if dst == nil then
        return table.clone(src)
    end
    for k, v in src do
        dst[k] = v
    end
    return dst
end

-- the settings as they are in effect in a mode: what the mode does not have is off, whatever its switch says,
-- since a feature whose controls are hidden must not keep working out of sight.
-- Reuses `out` when provided so the render loop allocates zero tables per frame.
function settings.inEffectInto(out, s, mode)
    local e = out
    local reusing = e ~= nil
    if not reusing then
        e = table.clone(s)
    end
    local items = copyInto(reusing and e.items or nil, s.items)
    local aim = copyInto(reusing and e.aim or nil, s.aim)
    local bhop = copyInto(reusing and e.bhop or nil, s.bhop)
    local farm = copyInto(reusing and e.farm or nil, s.farm)
    local steal = copyInto(reusing and e.steal or nil, s.steal)
    local statusKinds = s.statusKinds
    if not modes.has(mode, "Statuses") or not modes.has(mode, "TimeErase") then
        statusKinds = copyInto(reusing and e._statusKinds or nil, s.statusKinds)
        for id in statusKinds do
            if (id == "timeErase" and not modes.has(mode, "TimeErase")) or (id ~= "timeErase" and not modes.has(mode, "Statuses")) then
                statusKinds[id] = false
            end
        end
    end
    local fullbright = copyInto(reusing and e.fullbright or nil, s.fullbright)
    local fly = copyInto(reusing and e.fly or nil, s.fly)
    local noclip = copyInto(reusing and e.noclip or nil, s.noclip)
    local chams = copyInto(reusing and e.chams or nil, s.chams)
    local crosshair = copyInto(reusing and e.crosshair or nil, s.crosshair)
    local nospread = copyInto(reusing and e.nospread or nil, s.nospread)
    local silentaim = copyInto(reusing and e.silentaim or nil, s.silentaim)
    local townSilent = copyInto(reusing and e.townSilent or nil, s.townSilent)
    local townWeapon = copyInto(reusing and e.townWeapon or nil, s.townWeapon)
    local mvsSilent = copyInto(reusing and e.mvsSilent or nil, s.mvsSilent)
    local iaWeapon = copyInto(reusing and e.iaWeapon or nil, s.iaWeapon)
    local standOut = copyInto(reusing and e.standOut or nil, s.standOut)
    local standOutPickup = copyInto(reusing and e.standOutPickup or nil, s.standOutPickup)
    local standOutMobs = copyInto(reusing and e.standOutMobs or nil, s.standOutMobs)
    local standOutBounty = copyInto(reusing and e.standOutBounty or nil, s.standOutBounty)
    local walkSpeed = copyInto(reusing and e.walkSpeed or nil, s.walkSpeed)
    local jumpPower = copyInto(reusing and e.jumpPower or nil, s.jumpPower)
    local watermark = copyInto(reusing and e.watermark or nil, s.watermark)
    local reloadBar = copyInto(reusing and e.reloadBar or nil, s.reloadBar)
    local hotkeys = copyInto(reusing and e.hotkeys or nil, s.hotkeys)
    local mouseAimBuf = reusing and e._mouseAim or nil
    local mobsSkillsBuf = reusing and e._mobsSkills or nil

    if reusing then
        for k, v in s do
            e[k] = v
        end
    end

    e.items = items
    e.aim = aim
    e.bhop = bhop
    e.farm = farm
    e.steal = steal
    e.statusKinds = statusKinds
    if reusing and statusKinds ~= s.statusKinds then
        e._statusKinds = statusKinds
    end
    e.fullbright = fullbright
    e.fly = fly
    e.noclip = noclip
    e.chams = chams
    e.crosshair = crosshair
    e.nospread = nospread
    e.silentaim = silentaim
    e.townSilent = townSilent
    e.townWeapon = townWeapon
    e.mvsSilent = mvsSilent
    e.iaWeapon = iaWeapon
    e.standOut = standOut
    e.standOutPickup = standOutPickup
    e.standOutMobs = standOutMobs
    e.standOutBounty = standOutBounty
    e.walkSpeed = walkSpeed
    e.jumpPower = jumpPower
    e.watermark = watermark
    e.reloadBar = reloadBar
    e.hotkeys = hotkeys

    if not modes.has(mode, "Players") then
        e.enabled = false
        e.chams.enabled = false
    end
    if not modes.has(mode, "Items") then
        e.items.enabled = false
    end
    if not modes.has(mode, "AutoFarm") then
        e.farm.enabled = false
    end
    if not modes.has(mode, "Steal") then
        e.steal.enabled = false
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
    if not modes.has(mode, "Fullbright") then
        e.fullbright.enabled = false
    end
    if not modes.has(mode, "Fly") then
        e.fly.enabled = false
    end
    if not modes.has(mode, "NoClip") then
        e.noclip.enabled = false
    end
    if not modes.has(mode, "Crosshair") then
        e.crosshair.enabled = false
    end
    if not modes.has(mode, "ShotHook") then
        e.nospread.enabled = false
        e.silentaim.enabled = false
    end
    if not modes.has(mode, "TownGun") then
        e.townSilent.enabled = false
        e.townWeapon.enabled = false
    end
    if e.townWeapon.enabled then
        e.weapon = true
    end
    if not modes.has(mode, "MvsGun") then
        e.mvsSilent.enabled = false
        e.reloadBar.enabled = false
    end
    if not modes.has(mode, "IaWeapon") then
        e.iaWeapon.enabled = false
    end
    if e.iaWeapon.enabled then
        e.weapon = true
    end
    if not modes.has(mode, "StandOutInfo") then
        e.standOut.stand = false
        e.standOut.subAbility = false
        e.standOut.weapon = false
    end
    if e.standOut.stand or e.standOut.subAbility or e.standOut.weapon then
        e.weapon = true
    end
    if not modes.has(mode, "StandOutPickup") then
        e.standOutPickup.enabled = false
    end
    if s.standOutMobs and s.standOutMobs.skills then
        e.standOutMobs.skills = copyInto(mobsSkillsBuf, s.standOutMobs.skills)
        if reusing then
            e._mobsSkills = e.standOutMobs.skills
        end
    end
    if not modes.has(mode, "StandOutMobs") then
        e.standOutMobs.enabled = false
    end
    if not modes.has(mode, "StandOutBounty") then
        e.standOutBounty.enabled = false
    end
    if not modes.has(mode, "CharMove") then
        e.walkSpeed.enabled = false
        e.jumpPower.enabled = false
    end

    -- whether any Silent Aim (Town/MVS/Strike) is on
    e.aim.silent = e.townSilent.enabled or e.mvsSilent.enabled or e.silentaim.enabled

    if mode == "Mvs" then
        e.aim.visibleOnly = true
        e.aim.speed = 1e6
        e.aim.fullScreen = true
    end
    if mode == "Town" and e.townSilent.enabled then
        e.aim.fullScreen = true
    end

    e.mouseAim = e.aim
    if e.aim.silent then
        e.mouseAim = copyInto(mouseAimBuf, e.aim)
        e.mouseAim.silent = false
        if reusing then
            e._mouseAim = e.mouseAim
        end
    end

    return e
end

function settings.inEffect(s, mode)
    return settings.inEffectInto(nil, s, mode)
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

__modules["stand_out"] = function(require)
-- Stand Out mode: pure read helpers for player ESP.
-- Факты игры из tools/standout_probe_scene.lua (UniverseId = 8172250815, PlaceId = 128828638194450):
--   • без Roblox Teams (Team=nil, Neutral=true)
--   • персонажи: Workspace.Game.Players.<Name>, обычные R6 с Humanoid + HumanoidRootPart
--   • у каждого Player есть папка Data с StringValue: Stand, StandOverride, SubAbility, Weapon, WeaponOverride
local stand_out = {}

local function cleanString(value)
    if type(value) ~= "string" then
        return ""
    end
    local trimmed = string.match(value, "^%s*(.-)%s*$") or ""
    if trimmed == "" or trimmed == "None" then
        return ""
    end
    return trimmed
end

local function stringIn(folder, name)
    if folder == nil then
        return ""
    end
    local obj = folder:FindFirstChild(name)
    if obj == nil or obj.ClassName ~= "StringValue" then
        return ""
    end
    return cleanString(obj.Value)
end

-- Читает стенд, спек (SubAbility) и оружие игрока из Player.Data.
-- Возвращает { stand = "...", subAbility = "...", weapon = "..." } (пустые строки, если нет).
function stand_out.playerInfo(player)
    if player == nil then
        return { stand = "", subAbility = "", weapon = "" }
    end

    local data = player:FindFirstChild("Data")
    if data == nil then
        return { stand = "", subAbility = "", weapon = "" }
    end

    local stand = stringIn(data, "StandOverride")
    if stand == "" then
        stand = stringIn(data, "Stand")
    end

    local subAbility = stringIn(data, "SubAbility")

    local weapon = stringIn(data, "WeaponOverride")
    if weapon == "" then
        weapon = stringIn(data, "Weapon")
    end
    if weapon == "Fists" then
        weapon = ""
    end

    return {
        stand = stand,
        subAbility = subAbility,
        weapon = weapon,
    }
end

-- Собирает подпись под рамкой игрока по выбранным флагам.
function stand_out.format(info, showStand, showSub, showWeapon)
    if info == nil then
        return ""
    end

    local parts = {}
    if showStand and info.stand ~= nil and info.stand ~= "" then
        table.insert(parts, info.stand)
    end
    if showSub and info.subAbility ~= nil and info.subAbility ~= "" then
        table.insert(parts, info.subAbility)
    end
    if showWeapon and info.weapon ~= nil and info.weapon ~= "" then
        table.insert(parts, info.weapon)
    end

    return table.concat(parts, " | ")
end

return stand_out
end

__modules["stand_out_bounty"] = function(require)
-- Stand Out Auto Bounty: берёт баунти у Petyr на максимальном доступном тире (до Tier 8)
-- и выполняет его автоматически (боевые баунти через stand_out_mobs + Farm Config, поисковые — телепортом к промпту).
-- Факты игры из tools/standout_probe_bounty.lua и standout_probe_bounty2.lua:
--   • Petyr: Workspace.Game.NPCs.Petyr, позиция (-219.7, 19.9, 1688.5), ProximityPrompt + ClickDetector
--   • UI: PlayerGui.Bounty -> OpenRequested (BindableEvent), BountySelect (TierSelector.Label/Next/Previous,
--     Objectives.Bounty_1..7 с attr BountyComplete, Start.Begin с Activated), BountyTracker (Title/TitleAlt)
--   • Активный трекер: Player:GetAttribute("VisibleBountyTrackerPosition") (Vector3)
--   • Мои мобы баунти: Workspace.Game.Players.<Mob> с FightableNPC=true и BountyOwnerId == LocalPlayer.UserId
--   • Мои объекты баунти: Workspace.Game.BountyWorld.Party_<UserId>
--   • Модуль игры: ReplicatedStorage.Modules.Bounty (MaxTier=8, GetUnlockedTier, IncidentRules.Names)
-- Чистая логика поверх deps, проверяется tests/stand_out_bounty_test.lua.
local stand_out_bounty = {}

stand_out_bounty.petyr_fallback = { X = -219.7, Y = 19.9, Z = 1688.5 }
stand_out_bounty.max_tier = 8
stand_out_bounty.step_delay = 0.25
stand_out_bounty.open_retry = 1.2
stand_out_bounty.begin_wait = 1.8
stand_out_bounty.travel_retry = 2.0

-- Все известные инциденты Stand Out (Harvest, Hey Ya!, Cheap Jewelry, D'Arby, Rohan, Usagi's Karaoke,
-- Your Personal Helper Friend, Paco's Challenge и Iced Tea Run) поддерживаются автопрохождением!
local INCIDENT_NAMES = {}

local Runner = {}
Runner.__index = Runner

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function safeAttr(obj, name)
    if obj == nil or obj.GetAttribute == nil then
        return nil
    end
    local ok, val = pcall(function()
        return obj:GetAttribute(name)
    end)
    if ok then
        return val
    end
    return nil
end

local function safeIsA(obj, cls)
    if obj == nil or obj.IsA == nil then
        return false
    end
    local ok, res = pcall(function()
        return obj:IsA(cls)
    end)
    return ok and res == true
end

local function safeHoldDuration(prompt)
    if prompt == nil then
        return 0
    end
    local ok, val = pcall(function()
        return prompt.HoldDuration
    end)
    if ok and type(val) == "number" and finite(val) and val > 0 then
        return val
    end
    return 0
end

local function isHoldKeyH(prompt)
    if prompt == nil or safeIsA(prompt, "ClickDetector") then
        return false
    end
    local ok, kc = pcall(function()
        return prompt.KeyboardKeyCode
    end)
    if not ok or kc == nil then
        return true
    end
    local okN, name = pcall(function()
        return kc.Name
    end)
    return (okN and name == "H") or tostring(kc) == "H"
end

function stand_out_bounty.isIncident(title)
    if type(title) ~= "string" then
        return false
    end
    local clean = string.lower(string.match(title, "^%s*(.-)%s*$") or "")
    if INCIDENT_NAMES[clean] == true then
        return true
    end
    -- Также матчим по заголовку трекера вида "Tier 3 - Cheap Jewelry, Expensive Problem 0/1 | 10:24"
    for name in INCIDENT_NAMES do
        if string.find(clean, name, 1, true) ~= nil then
            return true
        end
    end
    return false
end

-- Парсит прогресс вида "1/2" или "4/4" из заголовка трекера ("Tier 3 - MISSING FROG 1/2 | 03:08")
function stand_out_bounty.parseProgress(titleText)
    if type(titleText) ~= "string" then
        return nil, nil
    end
    local cur, total = string.match(titleText, "(%d+)%s*/%s*(%d+)")
    if cur ~= nil and total ~= nil then
        return tonumber(cur), tonumber(total)
    end
    return nil, nil
end
-- Парсит номер тира из текста вида "TIER 3" или "TIER 1  |  LV 0-9"
function stand_out_bounty.parseTier(labelText)
    if type(labelText) ~= "string" then
        return nil
    end
    local num = string.match(string.upper(labelText), "TIER%s*(%d+)")
    return num and tonumber(num) or nil
end

-- Читает состояние Bounty UI (открыта ли доска, какой тир выбран, активен ли трекер, список баунти, диалог сдачи награды).
-- scanRohan=true включается ТОЛЬКО в момент сдачи работы Рохану, чтобы не гонять GetDescendants по всему PlayerGui каждый кадр!
function stand_out_bounty.readUi(playerGui, scanRohan)
    local info = {
        trackerActive = false,
        trackerTitle = "",
        trackerObjective = "",
        selectOpen = false,
        currentTier = nil,
        nextBtn = nil,
        prevBtn = nil,
        beginBtn = nil,
        openEvent = nil,
        claimBtn = nil,
        yesBtn = nil,
        dialogueOptions = {}, -- { button, text, key }
        jewelryOpen = false,
        jewelryActionBtn = nil,
        jewelryCloseBtn = nil,
        standStorageOpen = false,
        darbyChallengeBtn = nil,
        darbyBountyPrompt = false,
        darbyOpen = false,
        rohanOpen = false,
        rohanSubmitBtn = nil,
        bounties = {}, -- { button, title, complete, isIncident }
    }
    if playerGui == nil then
        return info
    end

    pcall(function()
        local jw = playerGui:FindFirstChild("JewelryInspection")
        if jw ~= nil and jw.Enabled == true then
            info.jewelryOpen = true
            local pres = jw:FindFirstChild("Presentation")
            local foot = pres and pres:FindFirstChild("Footer")
            local actBtn = foot and foot:FindFirstChild("Action")
            if actBtn ~= nil and actBtn.Visible == true then
                info.jewelryActionBtn = actBtn
            end
            local closeBtn = foot and foot:FindFirstChild("Close")
            if closeBtn ~= nil and closeBtn.Visible ~= false then
                info.jewelryCloseBtn = closeBtn
            end
        end

        local ssGui = playerGui:FindFirstChild("StandStorage")
        if ssGui ~= nil and ssGui.Enabled == true then
            info.standStorageOpen = true
            if ssGui.GetDescendants ~= nil then
                for _, d in ssGui:GetDescendants() do
                    if (safeIsA(d, "TextButton") or safeIsA(d, "ImageButton")) and d.Visible ~= false then
                        local txt = ""
                        if safeIsA(d, "TextButton") and type(d.Text) == "string" and d.Text ~= "" then
                            txt = d.Text
                        elseif d.GetDescendants ~= nil then
                            for _, sub in d:GetDescendants() do
                                if safeIsA(sub, "TextLabel") and type(sub.Text) == "string" and sub.Text ~= "" then
                                    txt = sub.Text
                                    break
                                end
                            end
                        end
                        if string.match(string.lower(txt), "^%s*challenge%s*$") ~= nil then
                            info.darbyChallengeBtn = d
                        end
                    elseif safeIsA(d, "TextLabel") and d.Visible ~= false and type(d.Text) == "string" then
                        local tl = string.lower(d.Text)
                        if string.find(tl, "go fish", 1, true) ~= nil or string.find(tl, "bounty", 1, true) ~= nil then
                            info.darbyBountyPrompt = true
                        end
                    end
                end
            end
        end
        local dGui = playerGui:FindFirstChild("DarbyGoFish")
        if dGui ~= nil and dGui.Enabled == true then
            info.darbyOpen = true
        end

        -- Окно мини-игры ROHAN'S DRAWING CONTEST ("YOUR DRAWING" + кнопка "SUBMIT") — сканируем ТОЛЬКО при scanRohan == true
        -- (в отдельной pcall), чтобы не вызывать GetDescendants по всему PlayerGui 144 раза в секунду!
        if scanRohan == true then pcall(function()
            local function isVisuallyVisible(obj, stopAt)
                local cur = obj
                while cur ~= nil and cur ~= stopAt do
                    if safeIsA(cur, "GuiObject") then
                        if cur.Visible == false then
                            return false
                        end
                        if cur.ClassName == "CanvasGroup" and type(cur.GroupTransparency) == "number" and cur.GroupTransparency >= 0.99 then
                            return false
                        end
                    end
                    cur = cur.Parent
                end
                return true
            end
            local function scanRohanContainer(container)
                if container == nil or container.GetDescendants == nil then return false end
                local hasRohanTitle = false
                local submitBtn = nil
                for _, d in container:GetDescendants() do
                    if safeIsA(d, "TextLabel") and d.Visible ~= false and type(d.Text) == "string" and d.Text ~= "" then
                        local tl = string.lower(d.Text)
                        if (string.find(tl, "rohan's drawing", 1, true) ~= nil or string.find(tl, "your drawing", 1, true) ~= nil)
                            and isVisuallyVisible(d, container) then
                            hasRohanTitle = true
                        end
                    elseif (safeIsA(d, "TextButton") or safeIsA(d, "ImageButton")) and d.Visible ~= false then
                        local txt = ""
                        if safeIsA(d, "TextButton") and type(d.Text) == "string" and d.Text ~= "" then
                            txt = d.Text
                        elseif d.GetDescendants ~= nil then
                            for _, sub in d:GetDescendants() do
                                if safeIsA(sub, "TextLabel") and type(sub.Text) == "string" and sub.Text ~= "" then
                                    txt = sub.Text
                                    break
                                end
                            end
                        end
                        if string.match(string.lower(txt), "^%s*submit%s*$") ~= nil and isVisuallyVisible(d, container) then
                            submitBtn = d
                        end
                    end
                end
                if hasRohanTitle and submitBtn ~= nil then
                    info.rohanOpen = true
                    info.rohanSubmitBtn = submitBtn
                    return true
                end
                return false
            end
            if playerGui.GetChildren ~= nil then
                for _, gui in playerGui:GetChildren() do
                    if safeIsA(gui, "ScreenGui") and gui.Enabled == true then
                        local gn = gui.Name or ""
                        if gn ~= "Dialogue" and gn ~= "JewelryInspection" and gn ~= "StandStorage" and gn ~= "DarbyGoFish"
                            and string.sub(gn, 1, 7) ~= "Calcite" then
                            if gn == "Bounty" then
                                if gui.GetChildren ~= nil then
                                    for _, ch in gui:GetChildren() do
                                        if safeIsA(ch, "GuiObject") and ch.Name ~= "BountyTracker" and ch.Name ~= "BountySelect" and ch.Visible == true then
                                            if scanRohanContainer(ch) then break end
                                        end
                                    end
                                end
                            elseif scanRohanContainer(gui) then
                                break
                            end
                        end
                    end
                end
            end
        end) end

        -- Проверяем активный диалог (Petyr claim/yes, а также квестовые NPC вроде Meryl Mei Qi и Dragona)
        local dlg = playerGui:FindFirstChild("Dialogue")
        if dlg ~= nil and (dlg.Enabled == nil or dlg.Enabled == true) and dlg.GetDescendants ~= nil then
            local seenKeys = {}
            local function recordOption(btn, txt)
                if type(txt) ~= "string" or txt == "" then return end
                local plain = string.gsub(txt, "<[^>]+>", "")
                local low = string.lower(plain)
                if string.find(low, "claim", 1, true) ~= nil and string.find(low, "reward", 1, true) ~= nil then
                    info.claimBtn = btn
                elseif string.match(low, "^%s*1%.%s*yes%s*$") ~= nil then
                    info.yesBtn = btn
                end
                local key = string.match(plain, "^%s*(%d)%.")
                if key ~= nil and not seenKeys[key] then
                    seenKeys[key] = true
                    table.insert(info.dialogueOptions, {
                        button = btn,
                        text = plain,
                        key = key,
                    })
                end
            end
            for _, d in dlg:GetDescendants() do
                if (safeIsA(d, "TextButton") or safeIsA(d, "ImageButton")) and d.Visible ~= false then
                    local txt = ""
                    if safeIsA(d, "TextButton") and type(d.Text) == "string" and d.Text ~= "" then
                        txt = d.Text
                    elseif d.GetDescendants ~= nil then
                        for _, sub in d:GetDescendants() do
                            if safeIsA(sub, "TextLabel") and type(sub.Text) == "string" and sub.Text ~= "" then
                                txt = sub.Text
                                break
                            end
                        end
                    end
                    recordOption(d, txt)
                end
            end
            -- В Stand Out опции диалога часто лежат в TextLabel "Box" (1. ..., 2. ..., 3. ...)
            if #info.dialogueOptions == 0 then
                for _, d in dlg:GetDescendants() do
                    if safeIsA(d, "TextLabel") and d.Visible ~= false and type(d.Text) == "string" and d.Text ~= "" then
                        local btn = d.Parent
                        if btn == nil or not (safeIsA(btn, "TextButton") or safeIsA(btn, "ImageButton")) then
                            btn = d
                        end
                        recordOption(btn, d.Text)
                    end
                end
            end
        end

        local bountyGui = playerGui:FindFirstChild("Bounty")
        if bountyGui == nil then
            return
        end
        info.openEvent = bountyGui:FindFirstChild("OpenRequested")

        local tracker = bountyGui:FindFirstChild("BountyTracker")
        if tracker ~= nil and (safeIsA(tracker, "GuiObject") or tracker.Visible ~= nil) and tracker.Visible == true then
            local faded = false
            if tracker.ClassName == "CanvasGroup" and type(tracker.GroupTransparency) == "number" and tracker.GroupTransparency >= 0.9 then
                faded = true
            end
            local t1 = tracker:FindFirstChild("Title")
            local t1l = t1 and t1:FindFirstChild("TextLabel")
            if t1l ~= nil and (safeIsA(t1l, "TextLabel") or type(t1l.Text) == "string") then
                info.trackerTitle = tostring(t1l.Text or "")
            end
            local t2 = tracker:FindFirstChild("TitleAlt")
            local t2l = t2 and t2:FindFirstChild("TextLabel")
            if t2l ~= nil and (safeIsA(t2l, "TextLabel") or type(t2l.Text) == "string") then
                info.trackerObjective = tostring(t2l.Text or "")
            end
            local titleVisible = t1 == nil or t1.Visible ~= false
            if not faded and titleVisible and info.trackerTitle ~= "" and stand_out_bounty.parseTier(info.trackerTitle) ~= nil then
                info.trackerActive = true
            end
        end

        local sel = bountyGui:FindFirstChild("BountySelect")
        if sel == nil then
            return
        end
        info.selectOpen = sel.Visible == true
        if not info.selectOpen then
            return
        end

        local ts = sel:FindFirstChild("TierSelector")
        if ts ~= nil then
            local lbl = ts:FindFirstChild("Label")
            if lbl ~= nil and (safeIsA(lbl, "TextLabel") or type(lbl.Text) == "string") then
                info.currentTier = stand_out_bounty.parseTier(lbl.Text)
            end
            info.nextBtn = ts:FindFirstChild("Next")
            info.prevBtn = ts:FindFirstChild("Previous")
        end

        local startBox = sel:FindFirstChild("Start")
        info.beginBtn = startBox and startBox:FindFirstChild("Begin") or nil

        local rot = sel:FindFirstChild("RotationTimer")
        if rot ~= nil and (safeIsA(rot, "TextLabel") or type(rot.Text) == "string") then
            info.rotationText = tostring(rot.Text or "")
        end

        local objectives = sel:FindFirstChild("Objectives")
        if objectives ~= nil and objectives.GetChildren ~= nil then
            local buttons = {}
            for _, child in objectives:GetChildren() do
                if string.match(child.Name or "", "^Bounty_%d+$") and child.Visible ~= false then
                    table.insert(buttons, child)
                end
            end
            table.sort(buttons, function(a, b)
                local na = tonumber(string.match(a.Name, "%d+")) or 0
                local nb = tonumber(string.match(b.Name, "%d+")) or 0
                return na < nb
            end)
            for _, btn in buttons do
                local tl = btn:FindFirstChild("Title")
                local title = ""
                if tl ~= nil and (safeIsA(tl, "TextLabel") or type(tl.Text) == "string") then
                    title = tostring(tl.Text or "")
                end
                if title ~= "" then
                    local isComplete = safeAttr(btn, "BountyComplete") == true
                        or string.find(string.upper(title), "| COMPLETE", 1, true) ~= nil
                    table.insert(info.bounties, {
                        button = btn,
                        title = title,
                        complete = isComplete,
                        isIncident = stand_out_bounty.isIncident(title),
                    })
                end
            end
        end
    end)

    return info
end

-- Выбирает лучший незавершённый баунти на текущем тире.
-- Если skipIncidents == true, берёт только не-инциденты (боевые + поиск).
function stand_out_bounty.pickBounty(bounties, skipIncidents)
    if bounties == nil then
        return nil
    end
    for _, b in bounties do
        if not b.complete and not b.isIncident then
            return b
        end
    end
    if not skipIncidents then
        for _, b in bounties do
            if not b.complete then
                return b
            end
        end
    end
    return nil
end

-- Ищет живых мобов, принадлежащих НАШЕМУ баунти:
--   1) Приоритет 1: BountyOwnerId / BountyLeaderId == userId (число или строка) или ForcedTargetName == playerName
--   2) Приоритет 2: имя моба (напр. "Hubert") встречается в тексте цели трекера ("Defeat Hubert (0/1)")
--      либо моб имеет BountyId и находится в радиусе 80 студов от VisibleBountyTrackerPosition
--   3) Приоритет 3: любой живой FightableNPC (кроме мирных диалоговых NPC) в радиусе 45 студов от точки трекера
function stand_out_bounty.scanMyMobs(workspace, userId, playerNames, playerName, tx, ty, tz, trackerObjective)
    local owned, matched, nearby = {}, {}, {}
    if workspace == nil or userId == nil then
        return owned
    end
    local gameFolder = workspace:FindFirstChild("Game")
    if gameFolder == nil then
        return owned
    end

    local uidStr = tostring(userId)
    local objLow = type(trackerObjective) == "string" and string.lower(trackerObjective) or ""
    -- Извлекаем точное имя цели из цели трекера ("Defeat DIO Servants (0/1)" -> "dio servants", "Defeat Hubert (0/1)" -> "hubert"),
    -- чтобы короткое имя мирового босса ("DIO") никогда не матчилось как подстрока внутри "DIO Servants"!
    local targetPhrase = nil
    if objLow ~= "" then
        local t = string.gsub(objLow, "%s*%(%d+%s*/%s*%d+%)%s*$", "")
        t = string.gsub(t, "%s+%d+%s*/%s*%d+%s*$", "")
        t = string.gsub(t, "^%s*defeat%s+", "")
        t = string.gsub(t, "^%s*kill%s+", "")
        t = string.gsub(t, "^%s*eliminate%s+", "")
        t = string.gsub(t, "^%s*beat%s+", "")
        t = string.gsub(t, "^%s*fight%s+", "")
        t = string.gsub(t, "^%s*stop%s+", "")
        t = string.gsub(t, "^%s*the%s+", "")
        t = string.gsub(t, "^%s*all%s+", "")
        t = string.gsub(t, "[%p]+$", "")
        t = string.match(t, "^%s*(.-)%s*$")
        if t ~= nil and #t >= 3 and t ~= objLow then
            targetPhrase = t
        end
    end
    local function normMobName(raw)
        local n = string.lower(raw or "")
        n = string.gsub(n, "_", " ")
        return string.match(n, "^%s*(.-)%s*$") or ""
    end
    local function matchesTargetPhrase(mobLow, phrase)
        if phrase == nil or mobLow == "" then return false end
        if mobLow == phrase then return true end
        if (mobLow .. "s") == phrase or (mobLow .. "es") == phrase then return true end
        if (phrase .. "s") == mobLow or (phrase .. "es") == mobLow then return true end
        -- Также поддерживаем слитное написание без пробелов ("dioservant" <-> "dio servants")
        local mFlat = string.gsub(mobLow, "%s+", "")
        local pFlat = string.gsub(phrase, "%s+", "")
        if mFlat == pFlat or (mFlat .. "s") == pFlat or (mFlat .. "es") == pFlat or (pFlat .. "s") == mFlat then
            return true
        end
        return false
    end
    local seen = {}

    local function checkModel(m, requireNoDialogue)
        if m == nil or seen[m] or not safeIsA(m, "Model") then return end
        seen[m] = true
        if playerNames ~= nil and playerNames[m.Name] then return end
        if safeAttr(m, "Stand") == true then return end
        if safeAttr(m, "FightableNPC") ~= true then return end
        if requireNoDialogue then
            if safeAttr(m, "DialogueOverride") ~= nil then return end
            if m.FindFirstChildWhichIsA ~= nil and m:FindFirstChildWhichIsA("ClickDetector", true) ~= nil then return end
        end

        local hum = m:FindFirstChildOfClass("Humanoid")
        if hum == nil or not finite(hum.Health) or hum.Health <= 0 then return end
        local root = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
        if root == nil then return end

        local cfg = safeAttr(m, "Config")
        local stripped = string.match(m.Name or "Mob", "^(.-)_%d+$") or (m.Name or "Mob")
        local name = (type(cfg) == "string" and cfg ~= "" and cfg ~= "Default") and cfg or stripped

        local entry = {
            model = m,
            humanoid = hum,
            root = root,
            name = name,
            rawName = m.Name or "",
            isBoss = safeAttr(m, "BossNPC") == true or safeAttr(m, "CommandBoss") == true,
        }

        -- Приоритет 1: прямой владелец баунти или ForcedTargetName == мой ник
        local ownerId = safeAttr(m, "BountyOwnerId") or safeAttr(m, "BountyLeaderId")
        local forced = safeAttr(m, "ForcedTargetName")
        if (ownerId ~= nil and (ownerId == userId or tostring(ownerId) == uidStr))
            or (type(playerName) == "string" and playerName ~= "" and forced == playerName) then
            table.insert(owned, entry)
            return
        end
        -- Чужой баунти-моб — пропускаем!
        if ownerId ~= nil then
            return
        end

        local hasTracker = tx ~= nil and ty ~= nil and tz ~= nil and root.Position ~= nil
            and finite(root.Position.X) and finite(root.Position.Y) and finite(root.Position.Z)
        local d2 = math.huge
        if hasTracker then
            local p = root.Position
            local dx, dy, dz = p.X - tx, p.Y - ty, p.Z - tz
            d2 = dx * dx + dy * dy + dz * dz
        end
        local hasBountyId = safeAttr(m, "BountyId") ~= nil

        -- Приоритет 2: точное (или ед./мн. число) совпадение имени моба с целью трекера ("Defeat Hubert (0/1)" -> Hubert;
        -- "Defeat DIO Servants (0/1)" -> "DIO Servant", но НЕ мировой босс "DIO"!)
        -- Если есть TrackerPos и у моба нет BountyId — требуем близость к точке трекера (<= 120 ст),
        -- чтобы не улетать бить посторонних мировых мобов/боссов в другом конце карты!
        if targetPhrase ~= nil then
            local sLow = normMobName(stripped)
            local cLow = normMobName(name)
            if matchesTargetPhrase(sLow, targetPhrase) or matchesTargetPhrase(cLow, targetPhrase) then
                if hasBountyId or not hasTracker or d2 <= 120 * 120 then
                    table.insert(matched, entry)
                    return
                end
            end
        end

        -- Приоритет 2b / 3: близость к точке трекера VisibleBountyTrackerPosition
        if hasTracker then
            if hasBountyId and d2 <= 80 * 80 then
                table.insert(matched, entry)
            elseif d2 <= 45 * 45 and safeAttr(m, "BeachSeal") ~= true and not entry.isBoss then
                table.insert(nearby, entry)
            end
        end
    end

    local pf = gameFolder:FindFirstChild("Players")
    if pf ~= nil and pf.GetChildren ~= nil then
        for _, c in pf:GetChildren() do
            checkModel(c, false)
        end
    end

    local bw = gameFolder:FindFirstChild("BountyWorld")
    local partyFolder = bw and bw:FindFirstChild("Party_" .. uidStr)
    if partyFolder ~= nil and partyFolder.GetDescendants ~= nil then
        for _, d in partyFolder:GetDescendants() do
            if safeIsA(d, "Model") then
                checkModel(d, false)
            end
        end
    end

    local npcs = gameFolder:FindFirstChild("NPCs")
    if npcs ~= nil and npcs.GetChildren ~= nil then
        for _, c in npcs:GetChildren() do
            checkModel(c, true)
        end
    end

    if #owned > 0 then return owned end
    if #matched > 0 then return matched end
    return nearby
end

-- Возвращает живую мировую позицию промпта (важно для бегающих HarvestUnit1..3 и моделей без PrimaryPart).
function stand_out_bounty.promptPosition(d)
    if d == nil or d.Parent == nil then
        return nil, nil, nil
    end
    local holder = d.Parent
    local pos = nil
    if safeIsA(holder, "Attachment") and holder.WorldPosition ~= nil then
        pos = holder.WorldPosition
    elseif safeIsA(holder, "BasePart") and holder.Position ~= nil then
        pos = holder.Position
    elseif safeIsA(holder, "Model") then
        if holder.PrimaryPart ~= nil and holder.PrimaryPart.Position ~= nil then
            pos = holder.PrimaryPart.Position
        elseif holder.GetPivot ~= nil then
            local okP, piv = pcall(function() return holder:GetPivot().Position end)
            if okP and piv ~= nil then
                pos = piv
            end
        end
        if pos == nil and holder.GetDescendants ~= nil then
            for _, sub in holder:GetDescendants() do
                if safeIsA(sub, "BasePart") and sub.Position ~= nil then
                    pos = sub.Position
                    break
                end
            end
        end
    end
    if pos ~= nil and finite(pos.X) and finite(pos.Y) and finite(pos.Z) then
        return pos.X, pos.Y, pos.Z
    end
    return nil, nil, nil
end

-- Вычисляет точку прямо ПЕРЕД сундуком/верстаком Cheap Jewelry со свободной стороны стола
-- (не на крышке сундука и не со стороны забора/знака [P]!), чтобы коробка гарантированно получала белую обводку.
function stand_out_bounty.jewelryStandPos(prompt, px, py, pz)
    local fx, fz = 0, 1
    pcall(function()
        local cur = prompt
        local scene = nil
        for _ = 1, 5 do
            if cur == nil then break end
            if cur.Name == "Incident_Jewelry" then
                scene = cur
                break
            end
            cur = cur.Parent
        end
        if scene ~= nil and scene.FindFirstChild ~= nil then
            local c2 = scene:FindFirstChild("Container2")
            local c2r = c2 and c2:FindFirstChild("Root")
            local asm = scene:FindFirstChild("Assembly")
            local asmr = asm and asm:FindFirstChild("Root")
            if c2r ~= nil and c2r.Position ~= nil and asmr ~= nil and asmr.Position ~= nil then
                local dx = asmr.Position.X - c2r.Position.X
                local dz = asmr.Position.Z - c2r.Position.Z
                local len = math.sqrt(dx * dx + dz * dz)
                if len > 0.1 then
                    fx, fz = dx / len, dz / len
                end
            end
        end
    end)
    local pname = prompt ~= nil and tostring(prompt.Name or "") or ""
    local dist = string.find(pname, "Assembly", 1, true) ~= nil and 2.6 or 4.2
    return px + fx * dist, py + 1.5, pz + fz * dist
end

-- true для подвижных промптов (напр. бегающие HarvestUnit1..3 в "Small Change, Big Problem").
function stand_out_bounty.isMovingPrompt(prompt)
    if prompt == nil then
        return false
    end
    local pname = prompt.Name or ""
    if string.find(pname, "BountyIncident_Catch", 1, true) ~= nil then
        return true
    end
    local holder = prompt.Parent
    local model = holder and holder.Parent
    if model ~= nil and safeAttr(model, "HarvestMoving") == true then
        return true
    end
    return false
end

-- Проверяет, просит ли текущая цель поговорить с квестовым NPC (Meryl Mei Qi, Dragona, D'Arby и т.п.)
function stand_out_bounty.isNpcObjective(objectiveText)
    if type(objectiveText) ~= "string" or objectiveText == "" then
        return false
    end
    local low = string.lower(objectiveText)
    if string.find(low, "claim your reward", 1, true) ~= nil
        or string.find(low, "return to petyr", 1, true) ~= nil then
        return false
    end
    -- Явный диалог с NPC ("Ask Dragona to help recover the scattered necklace stones", "Ask Meryl...", "Talk to...")
    -- всегда имеет приоритет, даже если внутри фразы встречается слово "recover" или "rebuild"
    if string.find(low, "ask ", 1, true) ~= nil
        or string.find(low, "talk to", 1, true) ~= nil
        or string.find(low, "speak to", 1, true) ~= nil then
        return true
    end
    -- Шаги осмотра сундуков / сборки на верстаке / подбора камня — НЕ диалог с NPC Dragona!
    if string.find(low, "inspect ", 1, true) ~= nil
        or string.find(low, "reassemble", 1, true) ~= nil
        or string.find(low, "rebuild", 1, true) ~= nil
        or string.find(low, "recover ", 1, true) ~= nil
        or string.find(low, "workbench", 1, true) ~= nil then
        return false
    end
    return string.find(low, "meryl", 1, true) ~= nil
        or string.find(low, "dragona", 1, true) ~= nil
        or string.find(low, "d'arby", 1, true) ~= nil
        or string.find(low, "darby", 1, true) ~= nil
        or string.find(low, "go fish", 1, true) ~= nil
        or string.find(low, "rohan", 1, true) ~= nil
        or string.find(low, "drawing", 1, true) ~= nil
        or string.find(low, "sketch", 1, true) ~= nil
        or string.find(low, "usagi", 1, true) ~= nil
        or string.find(low, "karaoke", 1, true) ~= nil
        or string.find(low, "sing ", 1, true) ~= nil
        or string.find(low, "hospital nurse", 1, true) ~= nil
        or string.find(low, "nurse", 1, true) ~= nil
end

function stand_out_bounty.isDarbyObjective(objectiveText, titleText)
    local combined = string.lower((objectiveText or "") .. " " .. (titleText or ""))
    return string.find(combined, "d'arby", 1, true) ~= nil
        or string.find(combined, "darby", 1, true) ~= nil
        or string.find(combined, "go fish", 1, true) ~= nil
end

-- Точные ID символов Go Fish из ReplicatedStorage.Remotes.StandStorage (проверено tools/standout_probe_darby2.lua)
stand_out_bounty.darby_symbol_ids = {
    Jelly = 1,
    Fish = 2,
    Beyond = 3,
    Humu = 4,
    Shark = 5,
    Frog = 6,
    Seal = 7,
    Bass = 8,
}

function stand_out_bounty.newDarbyState()
    return {
        storageOpen = false,
        tableCamera = false,
        active = false,
        view = nil,
        seq = 0,
        darbyKnown = {},
        lastMissedAt = {},
        lastSentSeq = -1,
        lastSentActionId = -1,
        lastSentAt = -99,
        readyAt = 0,   -- ждём окончания анимации раздачи ("Wait for the cards.")
        busyUntil = 0, -- защита от телепорта/повторного [H] во время перехода CHALLENGE -> диалог -> Go Fish
    }
end

-- Обновляет состояние партии D'Arby Go Fish по пакету StandStorage.OnClientEvent (чистый редьюсер).
function stand_out_bounty.applyDarbyEvent(st, kind, data, now)
    if st == nil then
        return
    end
    now = now or 0
    local function waitUntil(t)
        if t > (st.readyAt or 0) then
            st.readyAt = t
        end
    end

    if kind == "Error" or (type(data) == "table" and (data.Error ~= nil or data.Message ~= nil)) then
        -- Сервер попросил подождать (напр. "Wait for the cards.") -> отступаем и пробуем снова
        waitUntil(now + 2.5)
        st.lastSentSeq = -1
        st.lastSentActionId = -1
        return
    end
    if type(data) ~= "table" then
        return
    end
    if kind == "Open" or kind == "State" then
        if kind == "Open" then
            st.storageOpen = true
            st.active = false
            st.sawGui = false
            waitUntil(now + 2.5)
            st.busyUntil = math.max(st.busyUntil or 0, now + 5.0)
        end
        return
    end
    if kind == "Close" then
        st.storageOpen = false
        st.active = false
        st.busyUntil = 0
        return
    end
    if kind ~= "Fish" then
        return
    end

    st.busyUntil = math.max(st.busyUntil or 0, now + 6.0)
    if data.Started == true then
        st.active = true
        st.view = nil
        st.seq = 0
        st.darbyKnown = {}
        st.lastMissedAt = {}
        st.lastSentSeq = -1
        st.lastSentActionId = -1
        st.lastSentAt = -99
        -- Анимация раздачи стартовых 4 карт идёт ~3.5 с ("Wait for the cards.")
        waitUntil(now + 4.0)
    end

    if data.Ended == true or data.Finished == true or data.Closed == true or data.Winner ~= nil or data.Result ~= nil then
        st.active = false
        waitUntil(now + 2.0)
    end

    if type(data.Events) == "table" then
        for _, ev in data.Events do
            if type(ev) == "table" then
                if type(ev.Seq) == "number" and ev.Seq >= st.seq then
                    st.seq = ev.Seq
                end
                if type(ev.View) == "table" then
                    st.view = ev.View
                    st.active = true
                end
                local ek = ev.Kind
                local sym = ev.Symbol
                if ek == "Deal" then
                    waitUntil(now + 4.0)
                elseif ek == "Action" then
                    waitUntil(now + 1.8)
                elseif ek == "Give" then
                    waitUntil(now + 2.0)
                elseif ek == "Book" then
                    waitUntil(now + 2.2)
                elseif ek == "Turn" then
                    waitUntil(now + 1.0)
                end

                if ek == "Ask" and ev.By == "Darby" and type(sym) == "string" then
                    -- Чтобы спросить карту в Go Fish, D'Arby обязан иметь хотя бы 1 такую у себя в руке!
                    st.darbyKnown[sym] = true
                elseif ek == "Give" and ev.To == "Darby" and type(sym) == "string" then
                    st.darbyKnown[sym] = true
                elseif ek == "Give" and ev.From == "Darby" and type(sym) == "string" then
                    -- D'Arby отдал ВСЕ свои карты этого символа — у него сейчас точно 0 таких!
                    st.darbyKnown[sym] = nil
                    st.lastMissedAt[sym] = st.seq
                elseif ek == "Book" and type(sym) == "string" then
                    st.darbyKnown[sym] = nil
                elseif ek == "GoFish" and ev.By == "You" and type(sym) == "string" then
                    st.darbyKnown[sym] = nil
                    st.lastMissedAt[sym] = st.seq
                elseif ek == "End" or ek == "Finish" or ek == "Win" or ek == "Lose" or ek == "Result" or ev.Winner ~= nil then
                    st.active = false
                    waitUntil(now + 2.0)
                end
            end
        end
    end
end

-- Выбирает оптимальную карту для запроса у D'Arby:
--   1) Гарантированное попадание (D'Arby сам спрашивал или брал у нас эту карту — берём где у нас больше копий)
--   2) Иначе карта, по которой мы дольше всего не получали GoFish (при равенстве — больше копий в руке)
function stand_out_bounty.pickDarbyAsk(hand, darbyKnown, lastMissedAt)
    if type(hand) ~= "table" then
        return nil
    end
    local bestKnown, bestKnownCnt = nil, -1
    local bestOther, bestOtherMiss, bestOtherCnt = nil, math.huge, -1

    for sym, cnt in pairs(hand) do
        if type(sym) == "string" and type(cnt) == "number" and cnt > 0 and stand_out_bounty.darby_symbol_ids[sym] ~= nil then
            if darbyKnown ~= nil and darbyKnown[sym] then
                if cnt > bestKnownCnt or (cnt == bestKnownCnt and (bestKnown == nil or sym < bestKnown)) then
                    bestKnown = sym
                    bestKnownCnt = cnt
                end
            else
                local missed = (lastMissedAt ~= nil and lastMissedAt[sym]) or 0
                if missed < bestOtherMiss
                    or (missed == bestOtherMiss and cnt > bestOtherCnt)
                    or (missed == bestOtherMiss and cnt == bestOtherCnt and (bestOther == nil or sym < bestOther)) then
                    bestOther = sym
                    bestOtherMiss = missed
                    bestOtherCnt = cnt
                end
            end
        end
    end

    return bestKnown or bestOther
end

-- Возвращает следующую команду для StandStorage:FireServer(cmd, arg) + текст статуса.
function stand_out_bounty.nextDarbyMove(st, now, uiOpen)
    if st == nil then
        return nil, nil, nil
    end

    local scoreTag = "Go Fish"
    if type(st.view) == "table" and type(st.view.Books) == "table" then
        local yb = type(st.view.Books.You) == "table" and #st.view.Books.You or 0
        local db = type(st.view.Books.Darby) == "table" and #st.view.Books.Darby or 0
        scoreTag = string.format("Go Fish (%d:%d)", yb, db)
    end

    -- Ждём окончания анимации раздачи/взятия карт, чтобы сервер не выдал "Wait for the cards."
    if st.readyAt ~= nil and now < st.readyAt then
        return nil, nil, scoreTag .. ": жду карты..."
    end

    if st.active and type(st.view) == "table" then
        local v = st.view
        local act = v.Action
        if type(act) == "table" and act.Id ~= nil then
            local already = (act.Id == st.lastSentActionId) and (now - st.lastSentAt < 3.0)
            if not already then
                if act.Kind == "Draw" then
                    st.lastSentActionId = act.Id
                    st.lastSentAt = now
                    return "FishDraw", act.Id, scoreTag .. ": беру карту"
                elseif act.Kind == "Give" then
                    st.lastSentActionId = act.Id
                    st.lastSentAt = now
                    return "FishGive", act.Id, scoreTag .. ": отдаю карту"
                end
            end
            return nil, nil, scoreTag .. ": ход"
        end

        if v.Turn == "You" then
            local already = (st.seq == st.lastSentSeq) and (now - st.lastSentAt < 3.0)
            if not already then
                local sym = stand_out_bounty.pickDarbyAsk(v.Hand, st.darbyKnown, st.lastMissedAt)
                if sym ~= nil then
                    st.lastSentSeq = st.seq
                    st.lastSentAt = now
                    return "FishAsk", stand_out_bounty.darby_symbol_ids[sym], scoreTag .. ": прошу " .. sym
                end
            end
            return nil, nil, scoreTag .. ": мой ход"
        end
        return nil, nil, scoreTag .. ": ход D'Arby"
    end

    if (st.storageOpen or uiOpen) and not st.active then
        if now - st.lastSentAt >= 3.0 then
            st.lastSentAt = now
            return "FishStart", 1, "Go Fish: начинаю партию"
        end
        return nil, nil, "Go Fish: запуск..."
    end

    return nil, nil, nil
end

-- Выбирает нужный вариант ответа в диалоге квестового NPC (Meryl -> Dragona, Dragona -> Let's open them, и т.п.)
function stand_out_bounty.pickDialogueOption(options, objLow)
    if type(options) ~= "table" or #options == 0 then
        return nil
    end
    local function findMatch(patterns)
        for _, opt in options do
            local low = string.lower(opt.text or "")
            for _, pat in patterns do
                if string.find(low, pat, 1, true) ~= nil then
                    return opt
                end
            end
        end
        return nil
    end

    if type(objLow) == "string" then
        local reqSong = string.match(objLow, "sing%s+(.-)%s+with")
        if reqSong ~= nil and #reqSong >= 3 then
            local songOpt = findMatch({ reqSong })
            if songOpt ~= nil then
                return songOpt
            end
        end
    end

    local preferred = findMatch({ "just deal", "you're on", "thank you", "challenge", "draw", "sketch", "contest", "karaoke", "sing", "duet", "dragona", "let's open", "open them", "howler", "payment record", "record", "evidence" })
        or findMatch({ "necklace", "pendant", "stones", "restored", "fixed", "rebuilt", "accept", "start", "let's", "sure", "here", "ready", "yes" })
    if preferred ~= nil then
        return preferred
    end

    -- Фолбэк: первый вариант, который не является отказом/побочным диалогом
    local ignore = { "i'll be back", "give me a minute", "later", "bye", "driving practice", "fashion lessons", "never mind", "go over the rules", "not now", "not yet" }
    for _, opt in options do
        local low = string.lower(opt.text or "")
        local skip = false
        for _, bad in ignore do
            if string.find(low, bad, 1, true) ~= nil then
                skip = true
                break
            end
        end
        if not skip then
            return opt
        end
    end
    return options[1]
end

-- Равномерно ресемплирует полилинию штриха (массив Vector2 / {X,Y}) ровно в count точек (128, как клиент Rohan).
function stand_out_bounty.sampleStroke(pts, count, makeV2)
    local out = {}
    if type(pts) ~= "table" or #pts == 0 then
        return out
    end
    local n = math.max(2, tonumber(count) or 128)
    local ctor = makeV2 or function(x, y) return { X = x, Y = y } end
    local m = #pts
    if m == 1 then
        local p = pts[1]
        for _ = 1, n do
            table.insert(out, ctor(p.X, p.Y))
        end
        return out
    end

    local cum = { 0 }
    local total = 0
    for i = 2, m do
        local a, b = pts[i - 1], pts[i]
        local dx, dy = (b.X - a.X), (b.Y - a.Y)
        total += math.sqrt(dx * dx + dy * dy)
        cum[i] = total
    end

    if total <= 1e-6 then
        local p = pts[1]
        for _ = 1, n do
            table.insert(out, ctor(p.X, p.Y))
        end
        return out
    end

    local seg = 1
    for i = 0, n - 1 do
        local d = (i / (n - 1)) * total
        while seg < m - 1 and cum[seg + 1] < d do
            seg += 1
        end
        local d0, d1 = cum[seg], cum[seg + 1]
        local span = d1 - d0
        local t = span > 1e-9 and math.clamp((d - d0) / span, 0, 1) or 0
        local a, b = pts[seg], pts[seg + 1]
        table.insert(out, ctor(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t))
    end
    return out
end

-- Обрабатывает серверные пакеты ReplicatedStorage.Remotes.Bounty.OnClientEvent("Incident", bountyId, sub, data)
-- для ROHAN'S DRAWING CONTEST (DrawingOpen -> DrawingStart -> DrawingStroke -> DrawingClose).
function stand_out_bounty.applyRohanEvent(state, bountyId, sub, data, now)
    if type(sub) ~= "string" then
        return state
    end
    if sub == "DrawingClose" then
        return nil
    end
    if type(data) ~= "table" then
        return state
    end
    if sub == "DrawingOpen" then
        return {
            id = bountyId or (state and state.id),
            token = data.Token,
            strokes = type(data.Strokes) == "table" and data.Strokes or {},
            nextIdx = 1,
            acceptedCount = 0,
            started = false,
            readySent = false,
            waitingAck = false,
            submitStage = 0,
            submittedAt = 0,
            openedAt = now,
            lastSentAt = 0,
            challengeToken = nil,
        }
    end
    if sub == "DrawingStart" then
        if state == nil then
            return nil
        end
        if data.Token == nil or data.Token == state.token then
            state.started = true
            state.lastSentAt = 0
        end
        return state
    end
    if sub == "DrawingStroke" then
        if state == nil then
            return nil
        end
        if data.Token == nil or data.Token == state.token then
            state.waitingAck = false
            if data.Accepted == true then
                state.acceptedCount = (state.acceptedCount or 0) + 1
                if type(data.Next) == "number" then
                    state.nextIdx = data.Next
                else
                    state.nextIdx = (state.nextIdx or 1) + 1
                end
            end
        end
        return state
    end
    -- Пре-челендж (если перед DrawingOpen пришёл пакет с Token для DrawingChallenge)
    local subLow = string.lower(sub)
    if (string.find(subLow, "drawing", 1, true) ~= nil or string.find(subLow, "rohan", 1, true) ~= nil)
        and data.Token ~= nil and (state == nil or state.strokes == nil) then
        return {
            id = bountyId or (state and state.id),
            challengeToken = data.Token,
            strokes = nil,
            openedAt = now,
            lastSentAt = 0,
        }
    end
    return state
end

-- Генерирует следующий пакет для ROHAN'S DRAWING CONTEST (100% точность по эталонным Strokes от сервера).
function stand_out_bounty.nextRohanMove(rohan, now, makeV2)
    if type(rohan) ~= "table" then
        return nil, nil
    end
    if rohan.challengeToken ~= nil and rohan.strokes == nil then
        if now - (rohan.lastSentAt or 0) >= 0.8 then
            rohan.lastSentAt = now
            return {
                Id = rohan.id,
                Token = rohan.challengeToken,
                Action = "DrawingChallenge",
            }, "Rohan: начинаю конкурс"
        end
        return nil, "Rohan: запуск..."
    end
    if type(rohan.strokes) ~= "table" or #rohan.strokes == 0 then
        return nil, nil
    end
    local total = #rohan.strokes
    if not rohan.started then
        if not rohan.readySent and now - (rohan.openedAt or 0) >= 0.45 then
            rohan.readySent = true
            rohan.lastSentAt = now
            return {
                Id = rohan.id,
                Token = rohan.token,
                Action = "DrawingReady",
            }, "Rohan: готов к рисованию"
        end
        if rohan.readySent and now - (rohan.openedAt or 0) >= 1.5 then
            rohan.started = true
            rohan.lastSentAt = 0
        else
            return nil, "Rohan: жду старт..."
        end
    end

    local idx = rohan.nextIdx or 1
    if idx > total then
        local stage = rohan.submitStage or 0
        if stage == 0 then
            if now - (rohan.lastSentAt or 0) < 0.25 then
                return nil, string.format("Rohan: готово %d/%d", total, total)
            end
            rohan.submitStage = 1
            rohan.lastSentAt = now
            rohan.submittedAt = now
            return {
                Action = "DrawingSubmit",
                Id = rohan.id,
                Token = rohan.token,
            }, string.format("Rohan: сдаю %d/%d", total, total)
        elseif stage == 2 and now - (rohan.lastSentAt or 0) >= 0.8 then
            rohan.submitStage = 3
            rohan.lastSentAt = now
            return {
                Action = "DrawingFinish",
                Id = rohan.id,
                Token = rohan.token,
            }, string.format("Rohan: сдаю %d/%d", total, total)
        elseif stage >= 3 and now - (rohan.lastSentAt or 0) >= 2.0 then
            rohan.lastSentAt = now
            return {
                Action = "DrawingSubmit",
                Id = rohan.id,
                Token = rohan.token,
            }, string.format("Rohan: сдаю %d/%d", total, total)
        end
        return nil, string.format("Rohan: сдаю %d/%d", total, total)
    end

    -- Ждём подтверждения предыдущего штриха до 0.8s (обычно приходит за 0.05s), затем шлём следующий
    if rohan.waitingAck and now - (rohan.lastSentAt or 0) < 0.8 then
        return nil, string.format("Rohan: штрих %d/%d", idx, total)
    end
    if now - (rohan.lastSentAt or 0) < 0.14 then
        return nil, string.format("Rohan: штрих %d/%d", idx, total)
    end

    local pts = stand_out_bounty.sampleStroke(rohan.strokes[idx], 128, makeV2)
    rohan.waitingAck = true
    rohan.lastSentAt = now
    return {
        Action = "DrawingStroke",
        Id = rohan.id,
        Token = rohan.token,
        Index = idx,
        Points = pts,
    }, string.format("Rohan: штрих %d/%d", idx, total)
end

-- Определяет длительность удержания hold-ноты караоке (поддерживает разные имена полей)
local function karaokeHoldDuration(note)
    if type(note) ~= "table" then
        return 0
    end
    local d = tonumber(note.Hold)
        or tonumber(note.Duration)
        or tonumber(note.Length)
        or tonumber(note.HoldTime)
        or tonumber(note.HoldDuration)
        or tonumber(note.Sustain)
    if d ~= nil and finite(d) and d > 0 then
        return d
    end
    if type(note.EndTime) == "number" and type(note.Time) == "number" and note.EndTime > note.Time then
        return note.EndTime - note.Time
    end
    if note.Hold == true then
        return 0.6
    end
    return 0
end

-- Обрабатывает серверные пакеты ReplicatedStorage.Remotes.Karaoke.OnClientEvent (Prepare / Start / Hit / End)
-- для USAGI'S KARAOKE NIGHT.
function stand_out_bounty.applyKaraokeEvent(state, kind, data, nowServer, nowClock)
    if type(kind) ~= "string" then
        return state
    end
    if kind == "End" or kind == "Cancel" or kind == "Leave" or kind == "Close" then
        return nil
    end
    if kind == "Prepare" and type(data) == "table" and data.Id ~= nil then
        local notes = {}
        if type(data.Notes) == "table" then
            for i, n in ipairs(data.Notes) do
                if type(n) == "table" and type(n.Time) == "number" and type(n.Key) == "string" then
                    table.insert(notes, {
                        index = i,
                        time = n.Time,
                        key = n.Key,
                        hold = karaokeHoldDuration(n),
                        pressed = false,
                        holding = false,
                    })
                end
            end
            table.sort(notes, function(a, b)
                if a.time ~= b.time then
                    return a.time < b.time
                end
                return a.index < b.index
            end)
        end
        return {
            id = data.Id,
            title = data.Title or data.SongName or "Karaoke",
            duration = tonumber(data.Duration) or 25,
            travelTime = tonumber(data.TravelTime) or 4,
            notes = notes,
            started = false,
            readySent = false,
            playingSynced = false,
            songOrigin = nil,
            preparedAt = nowClock or 0,
            resolved = 0,
            perfects = 0,
            score = 0,
            pendingReleases = {},
        }
    end
    if state == nil then
        return nil
    end
    if type(data) == "table" and data.Id ~= nil and data.Id ~= state.id then
        return state
    end
    if kind == "Start" then
        state.started = true
        local st = type(data) == "table" and tonumber(data.Start) or nil
        local travel = state.travelTime or 4
        if st ~= nil and finite(st) then
            if st > nowServer + 1.0 then
                state.songOrigin = st
            else
                state.songOrigin = st + travel
            end
        else
            state.songOrigin = nowServer + travel
        end
        return state
    end
    if kind == "Hit" and type(data) == "table" and type(data.Result) == "table" then
        local res = data.Result
        if type(res.Resolved) == "number" then
            state.resolved = res.Resolved
        end
        if type(res.Score) == "number" then
            state.score = res.Score
        end
        if res.Grade == "Perfect" then
            state.perfects = (state.perfects or 0) + 1
        end
        if res.Holding == true and type(res.Index) == "number" then
            -- Страховка на случай hold-ноты без явного числового поля: продлеваем удержание!
            for _, pr in state.pendingReleases do
                if pr.noteIdx == res.Index and pr.at < nowServer + 0.25 then
                    pr.at = nowServer + 0.55
                end
            end
        end
        return state
    end
    return state
end

-- Выдаёт команды для Remotes.Karaoke:FireServer(...) на текущий кадр:
-- точные Input / Release ровно по расписанию Notes[i].Time (Perfect на каждой ноте).
function stand_out_bounty.stepKaraoke(state, nowServer, nowClock, songPlayingInUi)
    local cmds = {}
    if type(state) ~= "table" or state.id == nil then
        return cmds, nil
    end
    if not state.started then
        if not state.readySent and (nowClock - (state.preparedAt or 0)) >= 1.5 then
            state.readySent = true
            table.insert(cmds, { "Ready", state.id })
        end
        return cmds, "Karaoke: подготовка..."
    end

    if songPlayingInUi == false then
        state.sawReadyUi = true
    elseif songPlayingInUi == true and not state.playingSynced then
        state.playingSynced = true
        if state.songOrigin == nil or (state.sawReadyUi and math.abs(nowServer - state.songOrigin) > 0.35) then
            state.songOrigin = nowServer
        end
    end

    if state.songOrigin == nil then
        return cmds, "Karaoke: жду старт..."
    end

    local elapsed = nowServer - state.songOrigin
    if elapsed < 0 then
        return cmds, string.format("Karaoke: старт %.1fс", -elapsed)
    end

    -- 1) Отпускаем клавиши, чьё время удержания истекло
    local keep = {}
    for _, pr in state.pendingReleases do
        if nowServer >= pr.at then
            table.insert(cmds, { "Release", state.id, pr.key, nowServer })
        else
            table.insert(keep, pr)
        end
    end
    state.pendingReleases = keep

    -- 2) Нажимаем все ноты, дошедшие до линии попадания (elapsed >= note.time)
    local pressedCount = 0
    local total = #state.notes
    for _, note in state.notes do
        if note.pressed then
            pressedCount += 1
        elseif elapsed >= note.time then
            -- Если эта же клавиша ещё зажата от предыдущей ноты — сначала отпускаем её
            local nextKeep = {}
            for _, pr in state.pendingReleases do
                if pr.key == note.key then
                    table.insert(cmds, { "Release", state.id, pr.key, nowServer })
                else
                    table.insert(nextKeep, pr)
                end
            end
            state.pendingReleases = nextKeep

            note.pressed = true
            pressedCount += 1
            table.insert(cmds, { "Input", state.id, note.key, nowServer })
            local holdDur = (note.hold ~= nil and note.hold > 0) and note.hold or 0.06
            table.insert(state.pendingReleases, {
                key = note.key,
                at = nowServer + holdDur,
                noteIdx = note.index,
            })
        end
    end

    return cmds, string.format("Karaoke: %d/%d", pressedCount, total)
end

-- Обрабатывает серверные пакеты VerityDialogue / VerityDialogueClose для "Your Personal Helper Friend" (Berity).
function stand_out_bounty.applyVerityEvent(state, bountyId, sub, data, now)
    if type(sub) ~= "string" then
        return state
    end
    if sub == "VerityDialogueClose" or sub == "ClosePuzzle" then
        return nil
    end
    if sub == "VerityDialogue" and type(data) == "table" and data.Token ~= nil then
        return {
            id = bountyId or (state and state.id),
            token = data.Token,
            choices = type(data.Choices) == "table" and data.Choices or {},
            openedAt = now or 0,
            lastSentAt = 0,
        }
    end
    return state
end

-- Выбирает сюжетный вариант ответа в VerityChoices (любой, кроме Id="Leave" / "Never mind")
-- и формирует пакет { Action = "VerityChoice", Id, Token, Choice }.
function stand_out_bounty.nextVerityChoice(verity, now)
    if type(verity) ~= "table" or verity.token == nil or type(verity.choices) ~= "table" or #verity.choices == 0 then
        return nil, nil
    end
    if (now - (verity.openedAt or 0)) < 0.35 then
        return nil, "Berity: читаю диалог..."
    end
    if (now - (verity.lastSentAt or 0)) < 0.9 then
        return nil, "Berity: отвечаю..."
    end
    local picked = nil
    for _, ch in ipairs(verity.choices) do
        if type(ch) == "table" and type(ch.Id) == "string" then
            local idLow = string.lower(ch.Id)
            local txtLow = string.lower(tostring(ch.Text or ""))
            if idLow ~= "leave" and string.find(txtLow, "never mind", 1, true) == nil then
                picked = ch
                break
            end
        end
    end
    if picked == nil then
        picked = verity.choices[1]
    end
    if type(picked) ~= "table" or picked.Id == nil then
        return nil, nil
    end
    verity.lastSentAt = now
    return {
        Action = "VerityChoice",
        Id = verity.id,
        Token = verity.token,
        Choice = picked.Id,
    }, "Berity: " .. tostring(picked.Id)
end

-- Обрабатывает серверные пакеты ReplicatedStorage.Remotes.ArmWrestling.OnClientEvent (Start / Round / Progress / End)
-- для PACO'S CHALLENGE (армрестлинг за столом BanditArmWrestling).
function stand_out_bounty.applyArmWrestlingEvent(state, kind, data, nowClock)
    if type(kind) ~= "string" then
        return state
    end
    if kind == "End" or kind == "PoseEnd" or kind == "Cancel" or kind == "Leave" then
        return nil
    end
    if kind == "Start" and type(data) == "table" and data.Id ~= nil then
        return {
            id = data.Id,
            opponent = data.Opponent or "Paco",
            startedAt = nowClock or 0,
            round = 0,
            pressure = 0,
            pending = nil,
        }
    end
    if kind == "Round" and type(data) == "table" and data.Id ~= nil
        and type(data.Round) == "number" and type(data.Start) == "number"
        and type(data.Duration) == "number" and type(data.Target) == "number" then
        if state == nil or state.id ~= data.Id then
            state = {
                id = data.Id,
                opponent = "Paco",
                startedAt = nowClock or 0,
                round = 0,
                pressure = 0,
                pending = nil,
            }
        end
        local hitAt = data.Start + data.Duration * (data.Target / 360)
        state.round = data.Round
        state.pending = {
            id = data.Id,
            round = data.Round,
            hitAt = hitAt,
        }
        return state
    end
    if state ~= nil and kind == "Progress" and type(data) == "table" and type(data.Pressure) == "number" then
        state.pressure = data.Pressure
    end
    return state
end

-- Возвращает команду { "Input", id, round, nowServer } ровно в момент совпадения стрелки с Target (Grade=3 Perfect).
function stand_out_bounty.stepArmWrestling(state, nowServer)
    if type(state) ~= "table" or state.id == nil then
        return nil, nil
    end
    local label = string.format("Arm Wrestling: раунд %d", state.round or 0)
    if state.pending ~= nil and type(nowServer) == "number" and nowServer >= state.pending.hitAt then
        local p = state.pending
        state.pending = nil
        return { "Input", p.id, p.round, nowServer }, label
    end
    return nil, label
end

local function tabletopBandMid(band)
    if type(band) ~= "table" then
        return nil
    end
    local lo = tonumber(band.Min) or tonumber(band.min) or tonumber(band.Low) or tonumber(band.low)
        or tonumber(band.Start) or tonumber(band.From) or tonumber(band[1])
    local hi = tonumber(band.Max) or tonumber(band.max) or tonumber(band.High) or tonumber(band.high)
        or tonumber(band.End) or tonumber(band.To) or tonumber(band[2])
    if lo ~= nil and hi ~= nil and finite(lo) and finite(hi) and hi > lo then
        if hi > 1.5 then
            lo = lo / 100
            hi = hi / 100
        end
        return math.clamp((lo + hi) * 0.5, 0.05, 0.95)
    end
    -- Стандартный зелёный диапазон ICED TEA RUN ("stop between 75% and 90%")
    return 0.825
end

-- Обрабатывает серверные пакеты ReplicatedStorage.Remotes.Tabletop.OnClientEvent (Start / State / End)
-- для ICED TEA RUN (приготовление 4 стаканов чая: Hold POUR -> Drag Ice -> Drag Lemon -> Hold STIR -> Drag Glass).
function stand_out_bounty.applyTabletopEvent(state, kind, data, nowClock)
    if type(kind) ~= "string" then
        return state
    end
    if kind == "End" or kind == "Cancel" or kind == "Close" then
        return nil
    end
    if kind == "Start" and type(data) == "table" and data.Token ~= nil then
        local st = type(data.State) == "table" and data.State or {}
        return {
            token = data.Token,
            title = tostring(data.Title or "Iced tea"),
            steps = type(data.Steps) == "table" and data.Steps or {},
            index = tonumber(st.Index) or 1,
            fill = tonumber(st.Fill) or 0,
            done = st.Done == true,
            openedAt = nowClock or 0,
            stepChangedAt = nowClock or 0,
            lastActionAt = 0,
            holding = false,
            holdStart = nil,
            serverHoldStart = nil,
            holdEndSent = false,
        }
    end
    if state == nil or type(data) ~= "table" then
        return state
    end
    if data.Token ~= nil and data.Token ~= state.token then
        return state
    end
    if kind == "State" and type(data.State) == "table" then
        local st = data.State
        local prevIndex = state.index
        local newIndex = tonumber(st.Index) or prevIndex
        state.index = newIndex
        state.fill = tonumber(st.Fill) or 0
        state.done = st.Done == true
        if type(st.HoldStart) == "number" and finite(st.HoldStart) then
            state.serverHoldStart = st.HoldStart
        else
            state.serverHoldStart = nil
        end
        local cue = tostring(data.Cue or "")
        if newIndex ~= prevIndex then
            state.stepChangedAt = nowClock or 0
            state.holding = false
            state.holdStart = nil
            state.serverHoldStart = nil
            state.holdEndSent = false
        elseif cue == "Short" or cue == "Spill" or cue == "Miss" or cue == "Reset" then
            state.holding = false
            state.holdStart = nil
            state.serverHoldStart = nil
            state.holdEndSent = false
        end
    end
    return state
end

-- Выдаёт следующую команду для Remotes.Tabletop:FireServer(cmd, payload) по текущему шагу Steps[Index].
function stand_out_bounty.stepTabletop(state, nowServer, nowClock, makeV3)
    if type(state) ~= "table" or state.token == nil or state.done then
        return nil, nil, nil
    end
    local idx = state.index or 1
    local step = type(state.steps) == "table" and state.steps[idx] or nil
    if type(step) ~= "table" then
        return nil, nil, state.title .. ": готово"
    end
    local label = string.format("%s (%d/%d)", state.title, idx, #state.steps)
    local sinceStep = (nowClock or 0) - (state.stepChangedAt or state.openedAt or 0)
    if sinceStep < 0.25 then
        return nil, nil, label
    end

    if step.Kind == "Hold" then
        local secs = tonumber(step.Seconds) or 2.0
        local targetFill = tabletopBandMid(step.Band)
        if not state.holding then
            if (nowClock or 0) - (state.lastActionAt or 0) >= 0.35 then
                state.holding = true
                state.holdStart = nowServer
                state.serverHoldStart = nil
                state.holdEndSent = false
                state.lastActionAt = nowClock or 0
                return "HoldBegin", { Token = state.token, At = nowServer }, label
            end
            return nil, nil, label
        end
        local startTs = state.serverHoldStart or state.holdStart or nowServer
        if targetFill ~= nil then
            -- Наливание с зелёной зоной (POUR): отпускаем ровно в середине диапазона (82.5%)
            local remaining = math.max(0.04, targetFill - (state.fill or 0))
            local holdDur = secs * remaining
            if not state.holdEndSent and nowServer >= startTs + holdDur then
                state.holdEndSent = true
                state.lastActionAt = nowClock or 0
                return "HoldEnd", { Token = state.token, At = nowServer }, label
            elseif state.holdEndSent and (nowClock or 0) - (state.lastActionAt or 0) >= 1.2 then
                state.holding = false
                state.holdEndSent = false
            end
        else
            -- Автозавершающееся удержание (STIR): сервер сам переведёт на следующий шаг через Seconds;
            -- страховка HoldEnd только если затянулось на +0.8с сверх нормы
            if not state.holdEndSent and nowServer >= startTs + secs + 0.8 then
                state.holdEndSent = true
                state.lastActionAt = nowClock or 0
                return "HoldEnd", { Token = state.token, At = nowServer }, label
            end
        end
        return nil, nil, label
    elseif step.Kind == "Drag" then
        local key = step.Prop
        local to = step.To
        if key ~= nil and to ~= nil and (nowClock or 0) - (state.lastActionAt or 0) >= 0.45 then
            state.lastActionAt = nowClock or 0
            local dropY = (to.Y or 0) + (tonumber(step.MinHeight) or 0) + 0.15
            local ctor = makeV3 or function(x, y, z) return { X = x, Y = y, Z = z } end
            return "Drop", {
                Token = state.token,
                Key = key,
                Point = ctor(to.X or 0, dropY, to.Z or 0),
            }, label
        end
        return nil, nil, label
    end

    return nil, nil, label
end

-- Проверяет, остались ли ещё невыполненные ходы в головоломке (без изменения puzzle.attempted).
function stand_out_bounty.puzzleMovesRemaining(puzzle)
    if type(puzzle) ~= "table" or puzzle.open == false then
        return 0
    end
    local attempted = puzzle.attempted or {}
    local count = 0
    if puzzle.kind == "Rails" and type(puzzle.target) == "table" then
        for r, want in pairs(puzzle.target) do
            if type(r) == "number" then
                local cur = type(puzzle.values) == "table" and puzzle.values[r] or nil
                if cur ~= want and not attempted[r] then
                    count += 1
                end
            end
        end
        return count
    end
    if puzzle.kind == "Assembly" then
        local placedMap = {}
        if type(puzzle.placed) == "table" then
            for k, v in pairs(puzzle.placed) do
                if type(k) == "string" and v then
                    placedMap[k] = true
                elseif type(v) == "string" then
                    placedMap[v] = true
                end
            end
        end
        for _, comp in { "Heart", "Star", "Moon", "Clasp" } do
            if not placedMap[comp] and not attempted[comp] then
                count += 1
            end
        end
        return count
    end
    return 0
end

-- Генерирует следующий пакет решения головоломки Cheap Jewelry (Rails -> PlaceClasp, Assembly -> FitComponent).
function stand_out_bounty.nextPuzzleMove(puzzle)
    if type(puzzle) ~= "table" or puzzle.open == false then
        return nil
    end
    puzzle.attempted = puzzle.attempted or {}
    local ver = puzzle.version
    if ver == nil then
        ver = puzzle.serverVersion or 0
    end

    if puzzle.kind == "Rails" and type(puzzle.target) == "table" then
        local rows = {}
        for r in pairs(puzzle.target) do
            if type(r) == "number" then
                table.insert(rows, r)
            end
        end
        table.sort(rows)
        for _, row in rows do
            local want = puzzle.target[row]
            local cur = type(puzzle.values) == "table" and puzzle.values[row] or nil
            if cur ~= want and not puzzle.attempted[row] then
                puzzle.attempted[row] = true
                return {
                    Action = "PlaceClasp",
                    Id = puzzle.id,
                    Token = puzzle.token,
                    Row = row,
                    Notch = want,
                    Version = ver,
                }
            end
        end
        return nil
    end

    if puzzle.kind == "Assembly" then
        local placedMap = {}
        if type(puzzle.placed) == "table" then
            for k, v in pairs(puzzle.placed) do
                if type(k) == "string" and v then
                    placedMap[k] = true
                elseif type(v) == "string" then
                    placedMap[v] = true
                end
            end
        end
        local order = { "Heart", "Star", "Moon", "Clasp" }
        for _, comp in order do
            if not placedMap[comp] and not puzzle.attempted[comp] then
                puzzle.attempted[comp] = true
                return {
                    Action = "FitComponent",
                    Id = puzzle.id,
                    Token = puzzle.token,
                    Component = comp,
                    Version = ver,
                }
            end
        end
        return nil
    end

    return nil
end

-- Ищет активный ProximityPrompt баунти: сначала в Workspace.Game.BountyWorld.Party_<userId>,
-- затем StoryActors (BountyIncident_* вроде PacoPickup), ArmWrestlingTables (если цель — армрестлинг),
-- если allowNpcFallback == true — квестовых NPC в Workspace.Game.NPCs рядом с трекером (Meryl, Dragona, Paco, Hospital Nurse),
-- а иначе при allowWorldFallback ~= false — ближайший активный промпт в радиусе 25 студов от трекера (кроме NPC).
function stand_out_bounty.findMyPrompt(workspace, userId, tx, ty, tz, allowWorldFallback, allowNpcFallback, objectiveText)
    if workspace == nil or userId == nil then
        return nil, nil, nil, nil
    end
    local gameFolder = workspace:FindFirstChild("Game")
    if gameFolder == nil then
        return nil, nil, nil, nil
    end
    local objLow = type(objectiveText) == "string" and string.lower(objectiveText) or ""

    local function promptUsable(d)
        if safeIsA(d, "ProximityPrompt") then
            local reach = d.MaxActivationDistance
            local avail = safeAttr(d, "StoryPromptAvailable")
            return d.Enabled == true and avail ~= false and finite(reach) and reach > 0
        end
        if safeIsA(d, "ClickDetector") then
            local reach = d.MaxActivationDistance
            return finite(reach) and reach > 0
        end
        return false
    end

    -- 1) Приоритет: наша папка BountyWorld.Party_<userId> (быстрый обход; если включено несколько промптов —
    -- берём БЛИЖАЙШИЙ к VisibleBountyTrackerPosition, чтобы не путать Container1/Container2/Container3!)
    local bw = gameFolder:FindFirstChild("BountyWorld")
    local partyFolder = bw and bw:FindFirstChild("Party_" .. tostring(userId))
    local partyOwnsPrompts = false
    local wantPitcherOnly = string.find(objLow, "make the iced tea", 1, true) ~= nil
        or string.find(objLow, "make iced tea", 1, true) ~= nil
    local wantGlassOnly = string.find(objLow, "drink", 1, true) ~= nil
        and string.find(objLow, "tea", 1, true) ~= nil
    if partyFolder ~= nil and partyFolder.GetDescendants ~= nil then
        local bestP, bestX, bestY, bestZ = nil, nil, nil, nil
        local bestDist2 = math.huge
        for _, d in partyFolder:GetDescendants() do
            if safeIsA(d, "ProximityPrompt") or safeIsA(d, "ClickDetector") then
                -- Не считаем выключенный сюжетный UsagiPickupPrompt внутри Incident_Paco за «сцену со своими промптами»
                if d.Name ~= "UsagiPickupPrompt" then
                    partyOwnsPrompts = true
                end
            end
            if promptUsable(d) then
                local pname = tostring(d.Name or "")
                local skipTeaMismatch = (wantPitcherOnly and string.find(pname, "BountyIncident_Glass", 1, true) ~= nil)
                    or (wantGlassOnly and string.find(pname, "BountyIncident_Pitcher", 1, true) ~= nil)
                if not skipTeaMismatch then
                    local x, y, z = stand_out_bounty.promptPosition(d)
                    if x ~= nil then
                        if tx ~= nil and ty ~= nil and tz ~= nil then
                            local dx, dy, dz = x - tx, y - ty, z - tz
                            local d2 = dx * dx + dy * dy + dz * dz
                            if d2 < bestDist2 then
                                bestDist2 = d2
                                bestP, bestX, bestY, bestZ = d, x, y, z
                            end
                        else
                            return d, x, y, z
                        end
                    end
                end
            end
        end
        if bestP ~= nil then
            return bestP, bestX, bestY, bestZ
        end
    end

    -- 1.2) StoryActors (напр. Workspace.Game.StoryActors.Paco.HumanoidRootPart.BountyIncident_PacoPickup)
    if tx ~= nil and ty ~= nil and tz ~= nil then
        local storyActors = gameFolder:FindFirstChild("StoryActors")
        if storyActors ~= nil and storyActors.GetDescendants ~= nil then
            local bestS, bestX, bestY, bestZ = nil, nil, nil, nil
            local bestScore = math.huge
            for _, d in storyActors:GetDescendants() do
                if promptUsable(d) then
                    local x, y, z = stand_out_bounty.promptPosition(d)
                    if x ~= nil then
                        local dx, dy, dz = x - tx, y - ty, z - tz
                        local d2 = dx * dx + dy * dy + dz * dz
                        if d2 <= 25 * 25 then
                            local isIncidentP = string.find(tostring(d.Name or ""), "BountyIncident_", 1, true) ~= nil
                            local score = isIncidentP and d2 or (d2 + 10000)
                            if score < bestScore then
                                bestScore = score
                                bestS, bestX, bestY, bestZ = d, x, y, z
                            end
                        end
                    end
                end
            end
            if bestS ~= nil then
                return bestS, bestX, bestY, bestZ
            end
        end
    end

    -- 1.3) ArmWrestlingTables (PACO'S CHALLENGE этап 1/4: "Arm wrestle Paco at the table 1/4")
    if tx ~= nil and ty ~= nil and tz ~= nil and string.find(objLow, "arm wrestle", 1, true) ~= nil then
        local tables = gameFolder:FindFirstChild("ArmWrestlingTables")
        if tables ~= nil and tables.GetDescendants ~= nil then
            local bestT, bestX, bestY, bestZ = nil, nil, nil, nil
            local bestScore = math.huge
            for _, d in tables:GetDescendants() do
                if safeIsA(d, "ProximityPrompt") and promptUsable(d) then
                    local x, y, z = stand_out_bounty.promptPosition(d)
                    if x ~= nil then
                        local dx, dy, dz = x - tx, y - ty, z - tz
                        local d2 = dx * dx + dy * dy + dz * dz
                        if d2 <= 15 * 15 then
                            local okO, ot = pcall(function() return string.lower(tostring(d.ObjectText or "")) end)
                            local pacoMatch = okO and (string.find(ot, "paco", 1, true) ~= nil or string.find(ot, "challenge", 1, true) ~= nil)
                            local score = pacoMatch and d2 or (d2 + 500)
                            if score < bestScore then
                                bestScore = score
                                bestT, bestX, bestY, bestZ = d, x, y, z
                            end
                        end
                    end
                end
            end
            if bestT ~= nil then
                return bestT, bestX, bestY, bestZ
            end
        end
    end

    -- 1.5) Квестовые NPC (Meryl Mei Qi, Dragona, Paco, Hospital Nurse): ищем промпт внутри Workspace.Game.NPCs рядом с трекером
    -- Предпочитаем BountyIncident_* -> ProximityPrompt -> ClickDetector на одном и том же NPC
    if allowNpcFallback == true and tx ~= nil and ty ~= nil and tz ~= nil then
        local npcsFolder = gameFolder:FindFirstChild("NPCs")
        if npcsFolder ~= nil and npcsFolder.GetDescendants ~= nil then
            local bestNpc, bestX, bestY, bestZ = nil, nil, nil, nil
            local bestScore = math.huge
            for _, d in npcsFolder:GetDescendants() do
                if promptUsable(d) then
                    local x, y, z = stand_out_bounty.promptPosition(d)
                    if x ~= nil then
                        local dx, dy, dz = x - tx, y - ty, z - tz
                        local dist2 = dx * dx + dy * dy + dz * dz
                        if dist2 <= 15 * 15 then
                            local bonus = 0
                            if string.find(tostring(d.Name or ""), "BountyIncident_", 1, true) ~= nil then
                                bonus = -20
                            elseif safeIsA(d, "ProximityPrompt") then
                                bonus = -10
                            end
                            local score = dist2 + bonus
                            if score < bestScore then
                                bestScore = score
                                bestNpc = d
                                bestX, bestY, bestZ = x, y, z
                            end
                        end
                    end
                end
            end
            if bestNpc ~= nil then
                return bestNpc, bestX, bestY, bestZ
            end
        end
    end

    -- Если сцена инцидента в Party_<userId> сама содержит промпты (Harvest / Hey Ya! / Jewelry), но сейчас все выключены
    -- (идёт сценка или шаг "Stand still on the gold square") — не хватаем случайные промпты мира рядом!
    if partyOwnsPrompts then
        return nil, nil, nil, nil
    end

    -- 2) Фолбэк: любой включённый ProximityPrompt / ClickDetector в радиусе 25 студов от VisibleBountyTrackerPosition
    -- (пропускаем NPC-промпты Petyr/магазинов и садовые горшки)
    if allowWorldFallback ~= false and tx ~= nil and ty ~= nil and tz ~= nil then
        local npcsFolder = gameFolder:FindFirstChild("NPCs")
        local bestPrompt, bestX, bestY, bestZ = nil, nil, nil, nil
        local bestDist2 = 25 * 25

        local function scanContainer(container)
            if container == nil or container.GetDescendants == nil then return end
            for _, d in container:GetDescendants() do
                if promptUsable(d) then
                    local inNpcs = npcsFolder ~= nil and d.IsDescendantOf ~= nil and d:IsDescendantOf(npcsFolder)
                    if not inNpcs then
                        local x, y, z = stand_out_bounty.promptPosition(d)
                        if x ~= nil then
                            local dx, dy, dz = x - tx, y - ty, z - tz
                            local dist2 = dx * dx + dy * dy + dz * dz
                            if dist2 <= bestDist2 then
                                bestDist2 = dist2
                                bestPrompt = d
                                bestX, bestY, bestZ = x, y, z
                            end
                        end
                    end
                end
            end
        end

        -- Пропускаем уже проверенные папки и служебные контейнеры без промптов (Map НЕ пропускаем: там Clean The Rock / Three Wishes!)
        local skipGameChildren = {
            Terrain = true, Visuals = true, VFX = true, Effects = true, Lighting = true,
            NPCs = true, BountyWorld = true, StoryActors = true, ArmWrestlingTables = true, Players = true,
        }
        if gameFolder.GetChildren ~= nil then
            for _, ch in gameFolder:GetChildren() do
                if not skipGameChildren[ch.Name] then
                    scanContainer(ch)
                end
            end
        else
            scanContainer(gameFolder)
        end
        -- Также проверяем объекты вне Workspace.Game (если объект баунти заспавнен прямо в Workspace)
        if bestPrompt == nil and workspace.GetChildren ~= nil then
            for _, top in workspace:GetChildren() do
                if top ~= gameFolder and top.Name ~= "Terrain" and top.Name ~= "Camera" then
                    scanContainer(top)
                end
            end
        end

        if bestPrompt ~= nil then
            return bestPrompt, bestX, bestY, bestZ
        end
    end

    return nil, nil, nil, nil
end

-- deps:
--   readUi() -> table from stand_out_bounty.readUi
--   unlockedTier() -> number | nil (optional, from Modules.Bounty.GetUnlockedTier)
--   petyrPosition() -> x, y, z
--   interactPetyr(openEvent)
--   teleportTo(x, y, z)
--   activateButton(btn)
--   trackerPosition() -> x, y, z | nil
--   myMobs() -> entries
--   myPrompt() -> prompt, x, y, z | nil
--   triggerPrompt(prompt)
--   fightMobs(now, mobEntries, meX, meY, meZ) -> target | nil
--   stopFighting()
function stand_out_bounty.new(deps)
    return setmetatable({
        deps = deps,
        state = "idle",         -- "idle" | "opening" | "seeking_tier" | "picking" | "starting" | "active"
        since = 0,
        lastAction = -99,
        lastTierSeen = nil,
        tierStuckCount = 0,
        fallbackTier = nil,     -- если на max tier все не-инциденты пройдены, пробуем тир ниже
        completed = 0,
        statusText = "",
        wasTrackerActive = false,
        promptHolding = nil,
        promptSince = 0,
        rawHObjective = nil,
        rawHPos = nil,
    }, Runner)
end

function Runner:_releasePrompt()
    if self.promptHolding ~= nil then
        if self.deps.holdPromptEnd ~= nil then
            pcall(self.deps.holdPromptEnd, self.promptHolding)
        end
        self.promptHolding = nil
    end
    self.rawHObjective = nil
    self.rawHPos = nil
end

function Runner:stop()
    self:_releasePrompt()
    if self.deps.stopFighting ~= nil then
        pcall(self.deps.stopFighting)
    end
    self.state = "idle"
    self.lastTierSeen = nil
    self.tierStuckCount = 0
    self.fallbackTier = nil
    self.statusText = ""
end

function Runner:_desiredTier(opts)
    local pref = opts.tier or "Max"
    if pref ~= "Max" then
        local n = tonumber(pref)
        if n ~= nil and n >= 1 and n <= stand_out_bounty.max_tier then
            return n
        end
    end
    if self.fallbackTier ~= nil then
        return self.fallbackTier
    end
    -- Всегда пробуем дойти кнопкой Next до максимального тира (8), пока тир в UI не перестанет расти
    return stand_out_bounty.max_tier
end

function Runner:update(now, opts, meX, meY, meZ)
    if meX == nil or meY == nil or meZ == nil then
        self:stop()
        return
    end

    local ui = self.deps.readUi()

    local puzzle = self.deps.activePuzzle ~= nil and self.deps.activePuzzle() or nil
    local rohan = self.deps.activeRohan ~= nil and self.deps.activeRohan() or nil
    local karaoke = self.deps.activeKaraoke ~= nil and self.deps.activeKaraoke() or nil
    local arm = self.deps.activeArmWrestling ~= nil and self.deps.activeArmWrestling() or nil
    local tabletop = self.deps.activeTabletop ~= nil and self.deps.activeTabletop() or nil
    local verity = self.deps.activeVerity ~= nil and self.deps.activeVerity() or nil
    local darbySt = self.deps.darbyState ~= nil and self.deps.darbyState() or nil
    local inInspection = ui.jewelryOpen == true or ui.jewelryActionBtn ~= nil or puzzle ~= nil
    local inRohan = rohan ~= nil or ui.rohanOpen == true
    local inKaraoke = karaoke ~= nil
    local inArm = arm ~= nil
    local inTabletop = tabletop ~= nil
    local inVerity = verity ~= nil
    local inDarbyGame = ui.darbyOpen == true or (darbySt ~= nil and darbySt.active == true)
    local darbyBusy = darbySt ~= nil and ((darbySt.tableCamera == true) or (darbySt.busyUntil ~= nil and now < darbySt.busyUntil))
    local inDarbyStorage = (ui.standStorageOpen == true or darbyBusy)
        and (ui.darbyBountyPrompt == true or stand_out_bounty.isDarbyObjective(ui.trackerObjective, ui.trackerTitle) or darbyBusy)

    -- Парсим прогресс баунти (например 1/2 -> не завершено; 4/4 -> все шаги выполнены)
    local progCur, progTotal = stand_out_bounty.parseProgress(ui.trackerTitle)
    local hasIncompleteSteps = progCur ~= nil and progTotal ~= nil and progCur < progTotal

    -- Дополнительно сверяем с атрибутом BountyNavigationActive (CanvasGroup трекера может оставаться Visible=true),
    -- но если на трекере явно видны незавершённые шаги (например MISSING FROG 1/2), таймер ИЛИ открыто окно мини-игры
    -- (игра может прятать BountyTracker во время мини-игры!) — баунти точно активно!
    local hasActiveBounty = ui.trackerActive or inInspection or inRohan or inKaraoke or inArm or inTabletop or inVerity or inDarbyGame or inDarbyStorage
    if hasActiveBounty and not hasIncompleteSteps and not inInspection and not inRohan and not inKaraoke and not inArm and not inTabletop and not inVerity and not inDarbyGame and not inDarbyStorage and self.deps.navActive ~= nil then
        local okNav, nav = pcall(self.deps.navActive)
        if okNav and nav == false then
            local hasClock = string.find(ui.trackerTitle or "", "%d+:%d%d") ~= nil
            local objLowCheck = string.lower(ui.trackerObjective or "")
            local isClaimStep = ui.claimBtn ~= nil
                or string.find(objLowCheck, "claim", 1, true) ~= nil
                or string.find(objLowCheck, "return to petyr", 1, true) ~= nil
            if not hasClock and not isClaimStep then
                local mobsCheck = self.deps.myMobs()
                local promptCheck = self.deps.myPrompt()
                if (mobsCheck == nil or #mobsCheck == 0) and promptCheck == nil then
                    hasActiveBounty = false
                end
            end
        end
    end

    -- Если на персонаже уже висит инцидент с мини-игрой, а включено «Пропускать мини-игры»,
    -- идём к Petyr и перезаписываем его на боевой/поисковый баунти!
    local replaceIncident = hasActiveBounty and not inInspection and not inRohan and not inKaraoke and not inArm and not inTabletop and not inVerity and not inDarbyGame and (opts.skipIncidents ~= false) and stand_out_bounty.isIncident(ui.trackerTitle)

    -- Отслеживаем завершение баунти (трекер был активен -> исчез)
    if self.wasTrackerActive and not hasActiveBounty then
        self.completed += 1
        self.fallbackTier = nil
        if self.deps.stopFighting ~= nil then
            pcall(self.deps.stopFighting)
        end
        self.state = "idle"
    end
    self.wasTrackerActive = hasActiveBounty and not replaceIncident

    -- Если баунти уже активно (и это не мини-игра под замену) — выполняем его!
    if hasActiveBounty and not replaceIncident then
        self.state = "active"
        local title = ui.trackerTitle ~= "" and ui.trackerTitle or "Bounty"
        local objLow = string.lower(ui.trackerObjective or "")

        -- 0) Если диалог с кнопкой "1. Claim my bounty reward." уже открыт — сразу забираем награду
        if ui.claimBtn ~= nil then
            self:_releasePrompt()
            if self.deps.stopFighting ~= nil then
                pcall(self.deps.stopFighting)
            end
            if now - self.lastAction >= 0.45 then
                self.lastAction = now
                self.deps.activateButton(ui.claimBtn)
                if self.deps.pressKey ~= nil then
                    pcall(self.deps.pressKey, "1")
                end
            end
            self.statusText = "Забираю награду..."
            return
        end

        -- 0.40) Your Personal Helper Friend (Berity): авто-выбор варианта ответа в VerityDialogue
        if inVerity then
            self:_releasePrompt()
            if self.deps.stopFighting ~= nil then
                pcall(self.deps.stopFighting)
            end
            if self.deps.sendIncident ~= nil then
                local move, suffix = stand_out_bounty.nextVerityChoice(verity, now)
                if move ~= nil then
                    self.lastAction = now
                    pcall(self.deps.sendIncident, move)
                end
                self.statusText = title .. " | " .. (suffix or "Berity...")
            else
                self.statusText = title .. " | Berity..."
            end
            return
        end

        -- 0.41) PACO'S CHALLENGE — армрестлинг: отправляем Input ровно в Start + Duration * (Target / 360) -> Grade=3 Perfect
        if inArm then
            self:_releasePrompt()
            if self.deps.stopFighting ~= nil then
                pcall(self.deps.stopFighting)
            end
            local nowSrv = self.deps.serverTime ~= nil and self.deps.serverTime() or now
            local cmd, suffix = stand_out_bounty.stepArmWrestling(arm, nowSrv)
            if cmd ~= nil and self.deps.sendArmWrestling ~= nil then
                self.lastAction = now
                pcall(self.deps.sendArmWrestling, cmd[1], cmd[2], cmd[3], cmd[4])
            end
            self.statusText = title .. " | " .. (suffix or "Arm Wrestling...")
            return
        end

        -- 0.415) ICED TEA RUN — Tabletop мини-игра: Hold POUR (82.5%) -> Drop Ice -> Drop Lemon -> Hold STIR -> Drop Glass
        if inTabletop then
            self:_releasePrompt()
            if self.deps.stopFighting ~= nil then
                pcall(self.deps.stopFighting)
            end
            local nowSrv = self.deps.serverTime ~= nil and self.deps.serverTime() or now
            local cmd, payload, suffix = stand_out_bounty.stepTabletop(tabletop, nowSrv, now, self.deps.makeV3)
            if cmd ~= nil and self.deps.sendTabletop ~= nil then
                self.lastAction = now
                pcall(self.deps.sendTabletop, cmd, payload)
            end
            self.statusText = title .. " | " .. (suffix or "Iced Tea...")
            return
        end

        -- 0.42) USAGI'S KARAOKE NIGHT: точные Input/Release по расписанию Notes из Remotes.Karaoke("Prepare")
        if inKaraoke then
            self:_releasePrompt()
            if self.deps.stopFighting ~= nil then
                pcall(self.deps.stopFighting)
            end
            local nowSrv = self.deps.serverTime ~= nil and self.deps.serverTime() or now
            local songUiPlaying = self.deps.karaokeSongPlaying ~= nil and self.deps.karaokeSongPlaying() == true or false
            local cmds, suffix = stand_out_bounty.stepKaraoke(karaoke, nowSrv, now, songUiPlaying)
            if self.deps.sendKaraoke ~= nil and #cmds > 0 then
                self.lastAction = now
                for _, c in cmds do
                    pcall(self.deps.sendKaraoke, c[1], c[2], c[3], c[4])
                end
            end
            self.statusText = title .. " | " .. (suffix or "Karaoke...")
            return
        end

        -- 0.45) ROHAN'S DRAWING CONTEST: отправляем эталонные штрихи из DrawingOpen (128 точек каждый -> 100% точность),
        -- затем отправляем DrawingSubmit и нажимаем кнопку SUBMIT в UI
        if inRohan then
            self:_releasePrompt()
            if self.deps.stopFighting ~= nil then
                pcall(self.deps.stopFighting)
            end
            if rohan ~= nil then
                local suffix = nil
                if self.deps.sendIncident ~= nil then
                    local move
                    move, suffix = stand_out_bounty.nextRohanMove(rohan, now, self.deps.makeV2)
                    if move ~= nil then
                        self.lastAction = now
                        pcall(self.deps.sendIncident, move)
                    end
                end
                local function clickSubmitBtn()
                    if ui.rohanSubmitBtn == nil then
                        return false
                    end
                    local clicked = false
                    if self.deps.clickUiButton ~= nil then
                        local okC, resC = pcall(self.deps.clickUiButton, ui.rohanSubmitBtn)
                        clicked = okC and resC == true
                    end
                    if not clicked and self.deps.activateButton ~= nil then
                        pcall(self.deps.activateButton, ui.rohanSubmitBtn)
                        clicked = true
                    end
                    return clicked
                end
                if rohan.submitStage == 1 and rohan.submittedAt ~= nil and now - rohan.submittedAt >= 0.45 then
                    if clickSubmitBtn() then
                        self.lastAction = now
                    end
                    rohan.submitStage = 2
                elseif (rohan.submitStage or 0) >= 2 and ui.rohanSubmitBtn ~= nil and now - self.lastAction >= 1.2 then
                    if clickSubmitBtn() then
                        self.lastAction = now
                    end
                end
                self.statusText = title .. " | " .. (suffix or "Rohan: рисую...")
            else
                self.statusText = title .. " | Rohan: жду пакет..."
            end
            return
        end

        -- 0.5) Активная головоломка инцидента (Cheap Jewelry: замки Rails / сборка ожерелья Assembly + кнопка TAKE HOWLER RECORD)
        if inInspection then
            self:_releasePrompt()
            if self.deps.stopFighting ~= nil then
                pcall(self.deps.stopFighting)
            end
            -- Если появилась финальная кнопка действия ("TAKE HOWLER RECORD") — сразу жмём её!
            if ui.jewelryActionBtn ~= nil then
                if now - self.lastAction >= 0.6 then
                    self.lastAction = now
                    local clicked = false
                    if self.deps.clickUiButton ~= nil then
                        local okC, resC = pcall(self.deps.clickUiButton, ui.jewelryActionBtn)
                        clicked = okC and resC == true
                    end
                    if not clicked and self.deps.activateButton ~= nil then
                        self.deps.activateButton(ui.jewelryActionBtn)
                    end
                end
                self.statusText = title .. " | забираю улику"
                return
            end
            local function closeInspection(puz)
                local closed = false
                if ui.jewelryCloseBtn ~= nil and self.deps.clickUiButton ~= nil then
                    local okC, resC = pcall(self.deps.clickUiButton, ui.jewelryCloseBtn)
                    closed = okC and resC == true
                end
                if not closed and self.deps.pressKey ~= nil then
                    pcall(self.deps.pressKey, "B")
                end
                if not closed and ui.jewelryCloseBtn ~= nil and self.deps.activateButton ~= nil then
                    pcall(self.deps.activateButton, ui.jewelryCloseBtn)
                end
                if puz ~= nil and puz.closeTries ~= nil and puz.closeTries >= 1 and self.deps.sendIncident ~= nil then
                    pcall(self.deps.sendIncident, {
                        Action = "ClosePuzzle",
                        Id = puz.id,
                        Token = puz.token,
                    })
                end
                if puz ~= nil then
                    puz.closeTries = (puz.closeTries or 0) + 1
                end
            end
            if puzzle ~= nil and self.deps.sendIncident ~= nil then
                -- Stand Out принимает 1 действие за открытие и инкрементит Version на сервере без обратного Puzzle-пакета,
                -- поэтому: отправляем 1 ход с актуальным (Token, Version), ждём ~0.9s (на последнем ходе Assembly — 1.8s
                -- для появления TAKE HOWLER RECORD), и если сервер не прислал новый Puzzle — закрываем окно (CLOSE/B),
                -- чтобы промпт сразу переоткрыл его со свежим (Token, Version+1, обновлёнными Values/Placed)!
                if (puzzle.sentCount or 0) == 0 then
                    if now - self.lastAction >= 0.35 then
                        local move = stand_out_bounty.nextPuzzleMove(puzzle)
                        if move ~= nil then
                            puzzle.sentCount = 1
                            puzzle.sentAt = now
                            puzzle.moreAfterSend = stand_out_bounty.puzzleMovesRemaining(puzzle) > 0
                            self.lastAction = now
                            pcall(self.deps.sendIncident, move)
                        elseif now - self.lastAction >= 1.5 then
                            self.lastAction = now
                            closeInspection(puzzle)
                        end
                    end
                    self.statusText = title .. (puzzle.kind == "Assembly" and " | собираю ожерелье" or " | решаю замок")
                    return
                else
                    local waitClose = (puzzle.kind == "Assembly" and not puzzle.moreAfterSend) and 1.8 or 0.9
                    if puzzle.sentAt ~= nil and now - puzzle.sentAt >= waitClose and now - self.lastAction >= 0.7 then
                        self.lastAction = now
                        closeInspection(puzzle)
                    end
                    self.statusText = title .. " | обновляю замок"
                    return
                end
            elseif ui.jewelryOpen then
                -- Окно было открыто до включения Auto Bounty (пакет Puzzle не перехвачен) — закрываем, чтобы переоткрыть самим
                if now - self.lastAction >= 1.0 then
                    self.lastAction = now
                    closeInspection(nil)
                end
            end
            self.statusText = title .. " | решаю замок"
            return
        end

        -- 0.55) Открыт диалог квестового NPC (D'Arby "1. Just deal.", Meryl Mei Qi, Dragona, Paco, Hospital Nurse и др.)
        -- Ставим ДО StandStorage/GoFish, чтобы после нажатия CHALLENGE сразу нажимать "1. Just deal."!
        -- Также закрываем одиночный благодарственный диалог ("1. Thank you." у медсестры после сдачи Пако),
        -- даже если трекер уже переключился на "Return to Petyr to claim your reward"
        local isTrailingThanks = ui.dialogueOptions ~= nil and #ui.dialogueOptions == 1
            and string.find(string.lower(ui.dialogueOptions[1].text or ""), "thank you", 1, true) ~= nil
        if ui.dialogueOptions ~= nil and #ui.dialogueOptions > 0
            and (stand_out_bounty.isNpcObjective(objLow) or inDarbyStorage or inDarbyGame or isTrailingThanks) then
            self:_releasePrompt()
            if self.deps.stopFighting ~= nil then
                pcall(self.deps.stopFighting)
            end
            local opt = stand_out_bounty.pickDialogueOption(ui.dialogueOptions, objLow)
            if opt ~= nil and now - self.lastAction >= 0.65 then
                self.lastAction = now
                if darbySt ~= nil and (inDarbyStorage or inDarbyGame or stand_out_bounty.isDarbyObjective(ui.trackerObjective, ui.trackerTitle)) then
                    -- Даём игре 8 с на анимацию рассадки за стол и раздачу карт, не трогая персонажа!
                    darbySt.busyUntil = math.max(darbySt.busyUntil or 0, now + 8.0)
                end
                -- В Stand Out диалоги нативно принимают цифры 1..4 без firesignal-багов потоков
                if opt.key ~= nil and self.deps.pressKey ~= nil then
                    pcall(self.deps.pressKey, opt.key)
                elseif opt.button ~= nil then
                    self.deps.activateButton(opt.button)
                end
            end
            self.statusText = title .. " | диалог NPC"
            return
        end

        -- 0.6) D'Arby's Rematch (Go Fish): запускаем FishStart(1) напрямую после паузы стола (без firesignal по CHALLENGE,
        -- который ронял клиентский диалог StandStorage!), и играем Go Fish через StandStorage RemoteEvent
        local isDarby = stand_out_bounty.isDarbyObjective(ui.trackerObjective, ui.trackerTitle) or ui.darbyBountyPrompt == true
        local readyToClaimNow = string.find(objLow, "claim your reward", 1, true) ~= nil
            or (string.find(objLow, "return to petyr", 1, true) ~= nil and not hasIncompleteSteps)
        if readyToClaimNow and (ui.standStorageOpen or (darbySt ~= nil and (darbySt.storageOpen or darbySt.tableCamera))) then
            -- После победы над D'Arby закрываем StandStorage, чтобы камера/персонаж разблокировались для полёта к Petyr
            if self.deps.sendStandStorage ~= nil and now - self.lastAction >= 0.6 then
                self.lastAction = now
                pcall(self.deps.sendStandStorage, "Close", nil)
                if darbySt ~= nil then
                    darbySt.storageOpen = false
                    darbySt.active = false
                    darbySt.busyUntil = 0
                end
            end
            self.statusText = title .. " | выхожу из D'Arby"
            return
        end
        if not readyToClaimNow and (inDarbyGame or (isDarby and (ui.standStorageOpen or darbyBusy or (darbySt ~= nil and darbySt.storageOpen)))) then
            self:_releasePrompt()
            if self.deps.stopFighting ~= nil then
                pcall(self.deps.stopFighting)
            end
            -- Если мы на экране StandStorage (партия ещё не идёт) — сначала жмём CHALLENGE настоящим кликом мыши
            -- (без firesignal!), чтобы открылся диалог "1. Just deal." и нормальный UI DarbyGoFish;
            -- если меню Calcite открыто или кнопки нет — фолбэк на прямой FishStart(1)
            if not inDarbyGame and ui.standStorageOpen then
                local waitCards = darbySt ~= nil and darbySt.readyAt ~= nil and now < darbySt.readyAt
                if waitCards then
                    self.statusText = title .. " | Go Fish: жду стол..."
                    return
                end
                if now - self.lastAction >= 2.5 then
                    self.lastAction = now
                    if darbySt ~= nil then
                        darbySt.busyUntil = math.max(darbySt.busyUntil or 0, now + 6.0)
                    end
                    local clicked = false
                    if ui.darbyChallengeBtn ~= nil and self.deps.clickUiButton ~= nil then
                        local okC, resC = pcall(self.deps.clickUiButton, ui.darbyChallengeBtn)
                        clicked = okC and resC == true
                    end
                    if not clicked and self.deps.sendStandStorage ~= nil then
                        pcall(self.deps.sendStandStorage, "FishStart", 1)
                    end
                end
                self.statusText = title .. " | жму CHALLENGE"
                return
            end
            -- Во время переходной сценки (после CHALLENGE / FishStart / диалога) ждём появления карт, не телепортируясь
            if not inDarbyGame and not ui.standStorageOpen and darbyBusy then
                self.statusText = title .. " | Go Fish: посадка за стол..."
                return
            end
            if darbySt ~= nil and self.deps.sendStandStorage ~= nil then
                if now - self.lastAction >= 0.4 then
                    local cmd, arg, suffix = stand_out_bounty.nextDarbyMove(darbySt, now, ui.standStorageOpen)
                    if cmd ~= nil then
                        self.lastAction = now
                        if cmd == "FishStart" then
                            darbySt.busyUntil = math.max(darbySt.busyUntil or 0, now + 8.0)
                        end
                        pcall(self.deps.sendStandStorage, cmd, arg)
                    end
                    self.statusText = title .. " | " .. (suffix or "Go Fish")
                    return
                end
            end
            self.statusText = title .. " | Go Fish"
            return
        end

        -- 1) Если есть наши баунти-мобы (например Hubert в MISSING FROG 1/2) — ВСЕГДА сначала убиваем их!
        local mobs = self.deps.myMobs()
        if mobs ~= nil and #mobs > 0 then
            self:_releasePrompt()
            local target = self.deps.fightMobs(now, mobs, meX, meY, meZ)
            if target ~= nil then
                self.statusText = title .. " | " .. (target.name or "Mob")
                return
            end
        else
            if self.deps.stopFighting ~= nil then
                pcall(self.deps.stopFighting)
            end
        end

        -- 2) Награда готова к сдаче ("Return to Petyr to claim your reward") — идём к Petyr только когда нет мобов
        local readyToClaim = string.find(objLow, "claim your reward", 1, true) ~= nil
            or (string.find(objLow, "return to petyr", 1, true) ~= nil and not hasIncompleteSteps)
        if readyToClaim then
            self:_releasePrompt()
            local px, py, pz = self.deps.petyrPosition()
            local dx, dy, dz = px - meX, py - meY, pz - meZ
            if dx * dx + dy * dy + dz * dz > 64 then
                self.deps.teleportTo(px, py + 2.0, pz)
                self.lastAction = now
                self.statusText = "Лечу сдавать Petyr"
                return
            end
            if now - self.lastAction >= 0.9 then
                self.lastAction = now
                self.deps.interactPetyr(nil)
            end
            self.statusText = "Сдаю награду Petyr"
            return
        end

        local tx, ty, tz = self.deps.trackerPosition()

        -- 2.5) Спец-шаги без кнопок (Trust Me on This One / Hey Ya!):
        --   • "Stand still on the gold square (no button needed)" / "Stay on the square..." -> встать СТРОГО В ЦЕНТР квадрата и не двигаться!
        --   • "Watch where the can goes" / "Watch the case land..." -> просто подождать 1-2 с до включения следующего промпта
        local isStandSquare = string.find(objLow, "stand still", 1, true) ~= nil
            or string.find(objLow, "gold square", 1, true) ~= nil
            or string.find(objLow, "stay on the square", 1, true) ~= nil
        if isStandSquare and tx ~= nil then
            self:_releasePrompt()
            local dx, dy, dz = tx - meX, ty - meY, tz - meZ
            if dx * dx + dz * dz > 2.25 or math.abs(dy) > 8 then
                self.deps.teleportTo(tx, ty + 3.0, tz)
                self.lastAction = now
            end
            self.statusText = title .. " | стою на квадрате"
            return
        end
        if string.match(objLow, "^%s*watch%s+") ~= nil or string.find(objLow, "listen to the voice", 1, true) ~= nil then
            self:_releasePrompt()
            self.statusText = title .. " | жду сценку"
            return
        end

        -- 3) Ищем активный промпт баунти (кэшируется в slow-pass, позиция читается живьём для бегающих Harvest)
        local prompt, px, py, pz = self.deps.myPrompt(tx, ty, tz)
        if prompt ~= nil and px ~= nil then
            local moving = stand_out_bounty.isMovingPrompt(prompt)
            local dx, dy, dz = px - meX, py - meY, pz - meZ
            local dist2 = dx * dx + dy * dy + dz * dz
            local canAdoptRawH = self.promptHolding == "__rawH" and isHoldKeyH(prompt)
            local isHoldingThis = (self.promptHolding == prompt) or canAdoptRawH

            if moving then
                -- Подвижный Harvest (скорость 30..39, MaxDist=7): постоянно держимся прямо рядом с ним, не отпуская [H]!
                self.deps.teleportTo(px, py + 2.0, pz)
                if dist2 > 49 then
                    self:_releasePrompt()
                    self.lastAction = now
                    self.statusText = title .. " | догоняю Harvest"
                    return
                end
            else
                local pname = tostring(prompt.Name or "")
                local isJewelryBox = string.find(pname, "BountyIncident_Box", 1, true) ~= nil
                    or string.find(pname, "BountyIncident_Gem", 1, true) ~= nil
                    or string.find(pname, "BountyIncident_Assembly", 1, true) ~= nil
                if isJewelryBox then
                    -- Встаём ПЕРЕД столом напротив нужного сундука и смотрим на него, чтобы появилась белая обводка!
                    local sx, sy, sz = stand_out_bounty.jewelryStandPos(prompt, px, py, pz)
                    local sdx, sdy, sdz = sx - meX, sy - meY, sz - meZ
                    local sdist2 = sdx * sdx + sdy * sdy + sdz * sdz
                    local maxSpotDist2 = isHoldingThis and 25 or 6.25
                    if sdist2 > maxSpotDist2 then
                        self:_releasePrompt()
                        self.deps.teleportTo(sx, sy, sz, px, py, pz)
                        self.lastAction = now
                        self.statusText = title .. " | подхожу к сундуку"
                        return
                    end
                else
                    -- Гистерезис дистанции: до начала удержания подлетаем ближе 6 ст,
                    -- а пока [H] уже зажат — не сбрасываем удержание из-за толчка об коллизию камня (до 10 ст)
                    local maxStaticDist2 = isHoldingThis and 100 or 36
                    if dist2 > maxStaticDist2 then
                        -- Статичный объект (Clean The Rock, Three Wishes, Stash): встаём СБОКУ на земле (не на макушке столба!)
                        self:_releasePrompt()
                        self.deps.teleportTo(px + 2.5, py + 1.5, pz)
                        self.lastAction = now
                        self.statusText = title .. " | лечу к объекту"
                        return
                    end
                end
            end

            -- Если уже держали [H] через __rawH и в процессе нашли реальный H-промпт — перехватываем без отпускания [H]!
            if canAdoptRawH then
                self.promptHolding = prompt
                self.rawHObjective = nil
                self.rawHPos = nil
            end

            local isCd = safeIsA(prompt, "ClickDetector")
            local holdDur = isCd and 0 or safeHoldDuration(prompt)
            -- Щедрый таймаут (минимум 8 с для кастомных шкал вроде Clean The Rock / Three Wishes):
            -- как только промпт завершится, он исчезнет и _releasePrompt отпустит [H] на следующем же кадре!
            local maxHold = isCd and 0.5 or math.max(holdDur + 3.0, 8.0)

            if self.promptHolding == prompt then
                if now - self.promptSince >= maxHold then
                    self:_releasePrompt()
                    self.lastAction = now
                end
            elseif now - self.lastAction >= 0.25 then
                self:_releasePrompt()
                if self.deps.holdPromptBegin ~= nil then
                    self.promptHolding = prompt
                    self.promptSince = now
                    pcall(self.deps.holdPromptBegin, prompt, holdDur)
                elseif self.deps.triggerPrompt ~= nil then
                    self.lastAction = now
                    pcall(self.deps.triggerPrompt, prompt)
                end
            end
            self.statusText = title .. (moving and " | ловлю Harvest" or " | держу [H]")
            return
        end

        -- Если реальный промпт только что пропал (завершился) — сразу отпускаем [H] и даём серверу обновить трекер
        if self.promptHolding ~= nil and self.promptHolding ~= "__rawH" then
            self:_releasePrompt()
            self.lastAction = now
        end

        -- 4) Нет промпта и нет мобов: летим к VisibleBountyTrackerPosition (встаём чуть сбоку, не на столбе!)
        -- А если уже стоим рядом с точкой цели (<= 10 ст) и объект подсвечен кастомным [H]-триггером без ProximityPrompt — зажимаем [H]
        if tx ~= nil then
            local dx, dy, dz = tx - meX, ty - meY, tz - meZ
            local dist2 = dx * dx + dy * dy + dz * dz
            if dist2 > 100 then
                self:_releasePrompt()
                if now - self.lastAction >= stand_out_bounty.travel_retry then
                    self.lastAction = now
                    if ty > 45 then
                        -- Высокие точки (напр. "Locate Berity" на кране Y=129.6): встаём в центр, чтобы не слететь с узкой балки!
                        self.deps.teleportTo(tx, ty + 2.5, tz)
                    else
                        self.deps.teleportTo(tx + 2.5, ty + 1.5, tz, tx, ty, tz)
                    end
                end
                self.statusText = title .. " | лечу к цели"
            else
                -- Стоим вплотную к точке трекера (напр. Three Wishes / Clean The Rock с кастомным H-интерактом)
                if self.promptHolding == "__rawH" then
                    local stepDone = (self.rawHObjective ~= nil and ui.trackerObjective ~= self.rawHObjective)
                    if not stepDone and self.rawHPos ~= nil then
                        local rdx = tx - self.rawHPos[1]
                        local rdy = ty - self.rawHPos[2]
                        local rdz = tz - self.rawHPos[3]
                        if rdx * rdx + rdy * rdy + rdz * rdz > 16 then
                            stepDone = true
                        end
                    end
                    if stepDone then
                        self:_releasePrompt()
                        self.lastAction = now - 0.5
                    elseif now - self.promptSince >= 8.0 then
                        self:_releasePrompt()
                        self.lastAction = now
                    end
                elseif now - self.lastAction >= 0.8 and self.deps.holdPromptBegin ~= nil then
                    self:_releasePrompt()
                    self.promptHolding = "__rawH"
                    self.promptSince = now
                    self.rawHObjective = ui.trackerObjective
                    self.rawHPos = { tx, ty, tz }
                    pcall(self.deps.holdPromptBegin, "__rawH", 8.0)
                end
                self.statusText = title .. " | взаимодействие [H]"
            end
        else
            self:_releasePrompt()
            self.statusText = title
        end
        return
    end

    self:_releasePrompt()

    -- Баунти НЕ активно (или меняем инцидент на боевой): идём к Petyr, открываем доску и запускаем баунти!
    if not ui.selectOpen then
        local px, py, pz = self.deps.petyrPosition()
        local dx, dy, dz = px - meX, py - meY, pz - meZ
        if dx * dx + dy * dy + dz * dz > 64 then
            self.deps.teleportTo(px, py + 2.0, pz)
            self.statusText = "Лечу к Petyr"
            self.lastAction = now
            self.state = "opening"
            return
        end

        if self.state ~= "opening" or now - self.lastAction >= stand_out_bounty.open_retry then
            self.state = "opening"
            self.lastAction = now
            -- Если уже открыт диалог Petyr "wanna start bounty" -> жмём "1. yes", чтобы он сам открыл доску без наложения
            if ui.yesBtn ~= nil then
                self.deps.activateButton(ui.yesBtn)
            else
                self.deps.interactPetyr(ui.openEvent)
            end
            self.statusText = "Открываю Petyr"
        end
        return
    end

    -- Доска Petyr открыта!
    if now - self.lastAction < stand_out_bounty.step_delay then
        return
    end

    local desired = self:_desiredTier(opts)
    local cur = ui.currentTier

    -- Шаг 1: дойти до нужного (максимально доступного) тира
    if self.state == "opening" or self.state == "idle" then
        self.state = "seeking_tier"
        self.lastTierSeen = nil
        self.tierStuckCount = 0
    end

    if self.state == "seeking_tier" then
        if cur ~= nil and cur < desired and ui.nextBtn ~= nil then
            if self.lastTierSeen == cur then
                self.tierStuckCount += 1
            else
                self.lastTierSeen = cur
                self.tierStuckCount = 0
            end

            -- Если два клика по Next не увеличили тир — значит это максимальный открытый тир!
            if self.tierStuckCount < 2 then
                self.lastAction = now
                self.deps.activateButton(ui.nextBtn)
                self.statusText = string.format("Тир %d -> %d", cur, desired)
                return
            end
        elseif cur ~= nil and cur > desired and ui.prevBtn ~= nil then
            if self.lastTierSeen == cur then
                self.tierStuckCount += 1
            else
                self.lastTierSeen = cur
                self.tierStuckCount = 0
            end
            if self.tierStuckCount < 2 then
                self.lastAction = now
                self.deps.activateButton(ui.prevBtn)
                self.statusText = string.format("Тир %d -> %d", cur, desired)
                return
            end
        end

        self.state = "picking"
    end

    -- Шаг 2: выбрать лучший баунти на этом тире
    -- В Stand Out завершённый баунти помечается COMPLETE сразу для всех тиров до обновления ротации,
    -- поэтому вниз по тирам не спускаемся — ждём обновления доски на максимальном доступном тире.
    if self.state == "picking" then
        local chosen = stand_out_bounty.pickBounty(ui.bounties, opts.skipIncidents ~= false)
        if chosen == nil then
            local timer = (type(ui.rotationText) == "string" and ui.rotationText ~= "")
                and (string.match(ui.rotationText, "REFRESH IN%s*[%d:]+") or ui.rotationText) or ""
            self.statusText = timer ~= "" and ("Все пройдены (" .. timer .. ")") or "Все баунти пройдены (жду обнову)"
            self.lastAction = now + 3.0
            return
        end

        self.lastAction = now
        self.deps.activateButton(chosen.button)
        self.state = "starting"
        self.since = now
        self.statusText = string.format("Tier %s: %s", tostring(cur or "?"), chosen.title)
        return
    end

    -- Шаг 3: нажать Begin
    if self.state == "starting" then
        if ui.beginBtn ~= nil then
            self.lastAction = now
            self.deps.activateButton(ui.beginBtn)
        end
        if now - self.since >= stand_out_bounty.begin_wait then
            -- Не запустилось (например, не хватило уровня на этот тир) — пробуем тир ниже
            if (opts.tier == nil or opts.tier == "Max") and cur ~= nil and cur > 1 then
                self.fallbackTier = cur - 1
                self.state = "seeking_tier"
                self.lastTierSeen = nil
                self.tierStuckCount = 0
            else
                self.state = "picking"
            end
        end
    end
end

return stand_out_bounty
end

__modules["stand_out_howler"] = function(require)
-- Stand Out Howler's Cases: автосбор всех 10 кейсов Howler (case_01..case_10) на карте.
-- Факты игры из Modules.HowlerCases / standout_probe_howler2.lua:
--   • 10 кейсов: case_01..case_10 (1000 монет + 15% опыта за каждый, Howler Jacket + Howler Pants за все 10)
--   • Прогресс игрока: LocalPlayer.Data.Stats.HowlerCasesOpened (StringValue, список через запятую)
--   • Ремоут: ReplicatedStorage.Remotes.HowlerCases:
--       S->C: ("Reveal", id, CFrame, Size) / ("Hide", id) — спавнит модель Case в Workspace.LocalProps (attr HowlerCaseId)
--       C->S: ("Hold", id) -> пауза HoldDuration (0.8s) -> ("Open", id)
--   • RevealRange = 200, PromptRange = 8.
-- Чистая логика поверх deps, проверяется tests/stand_out_howler_test.lua.
local stand_out_howler = {}

stand_out_howler.ids = {
    "case_01", "case_02", "case_03", "case_04", "case_05",
    "case_06", "case_07", "case_08", "case_09", "case_10",
}
stand_out_howler.total = 10
stand_out_howler.hold_duration = 0.92
stand_out_howler.settle = 0.22
stand_out_howler.confirm_wait = 0.45
stand_out_howler.sweep_step = 0.28
stand_out_howler.above = 3.0
stand_out_howler.visited_radius = 155 -- строго меньше RevealRange=200 с запасом, чтобы не было слепых дыр между клетками

-- Подтверждённые координаты всех 10 кейсов (обновляются и дополняются из calcite_so_howler_spots.txt)
stand_out_howler.known_spots = {
    case_01 = { x = -233.61, y = 16.91, z = 1042.95 },
    case_02 = { x = -1344.33, y = 17.57, z = 2184.88 },
    case_03 = { x = -1846.06, y = 16.78, z = 1206.74 },
    case_04 = { x = 2378.16, y = 26.38, z = 1324.87 },
    case_05 = { x = -2248.65, y = 15.38, z = 823.66 },
    case_06 = { x = 179.50, y = 18.19, z = 1045.34 },
    case_07 = { x = -777.55, y = 34.19, z = 2595.42 },
    case_08 = { x = -854.96, y = 17.63, z = 1424.96 },
    case_09 = { x = 185.34, y = 18.19, z = 1717.10 },
    case_10 = { x = -791.88, y = 17.26, z = 697.64 },
}

local Collector = {}
Collector.__index = Collector

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Парсинг/сохранение посещённых 3D-зон (calcite_so_howler_visited2.txt): "x,y,z" на строку
function stand_out_howler.parseVisitedCache(raw)
    local out = {}
    if type(raw) ~= "string" or raw == "" then
        return out
    end
    for line in string.gmatch(raw, "[^\r\n]+") do
        local sx, sy, sz = string.match(line, "^%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*$")
        local x, y, z = tonumber(sx), tonumber(sy), tonumber(sz)
        if finite(x) and finite(y) and finite(z) then
            table.insert(out, { x = x, y = y, z = z })
        else
            local x2, z2 = string.match(line, "^%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*$")
            local nx, nz = tonumber(x2), tonumber(z2)
            if finite(nx) and finite(nz) then
                table.insert(out, { x = nx, y = 45, z = nz })
            end
        end
    end
    return out
end

function stand_out_howler.formatVisitedCache(list)
    if type(list) ~= "table" then
        return ""
    end
    local lines = {}
    for _, v in list do
        if type(v) == "table" and finite(v.x) and finite(v.z) then
            table.insert(lines, string.format("%.0f,%.0f,%.0f", v.x, v.y or 45, v.z))
        end
    end
    return table.concat(lines, "\n")
end

-- Сериализация/парсинг кэша координат кейсов (calcite_so_howler_spots.txt): "case_01=-123.4,19.5,456.7"
function stand_out_howler.parseSpotsCache(raw)
    local out = {}
    if type(raw) ~= "string" or raw == "" then
        return out
    end
    for line in string.gmatch(raw, "[^\r\n]+") do
        local id, sx, sy, sz = string.match(line, "^%s*(case_%d%d)%s*=%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*$")
        local x, y, z = tonumber(sx), tonumber(sy), tonumber(sz)
        if id ~= nil and finite(x) and finite(y) and finite(z) then
            out[id] = { x = x, y = y, z = z }
        end
    end
    return out
end

function stand_out_howler.formatSpotsCache(spots)
    if type(spots) ~= "table" then
        return ""
    end
    local lines = {}
    for _, id in stand_out_howler.ids do
        local p = spots[id]
        if type(p) == "table" and finite(p.x) and finite(p.y) and finite(p.z) then
            table.insert(lines, string.format("%s=%.2f,%.2f,%.2f", id, p.x, p.y, p.z))
        end
    end
    return table.concat(lines, "\n")
end

local function safeAttr(obj, name)
    if obj == nil or obj.GetAttribute == nil then
        return nil
    end
    local ok, val = pcall(function()
        return obj:GetAttribute(name)
    end)
    if ok then
        return val
    end
    return nil
end

-- Парсит Data.Stats.HowlerCasesOpened ("case_03,case_10") -> (map, count).
function stand_out_howler.decodeOpened(raw)
    local opened = {}
    local count = 0
    if type(raw) ~= "string" or raw == "" then
        return opened, 0
    end
    for tok in string.gmatch(raw, "[^,%s;]+") do
        if string.match(tok, "^case_%d%d$") and not opened[tok] then
            opened[tok] = true
            count += 1
        end
    end
    return opened, count
end

-- Возвращает список ещё не открытых case_01..case_10.
function stand_out_howler.unopenedIds(raw)
    local opened = stand_out_howler.decodeOpened(raw)
    local out = {}
    for _, id in stand_out_howler.ids do
        if not opened[id] then
            table.insert(out, id)
        end
    end
    return out
end

-- Собирает точки всех именованных локаций из Workspace.Game.Areas / StrengthSpawns / StoryLocations / Spawns,
-- чтобы сначала мгновенно проверить все острова, бухты, горы и здания игры.
function stand_out_howler.scanAreaPoints(workspace)
    local pts = {}
    if workspace == nil then
        return pts
    end
    local gf = workspace:FindFirstChild("Game")
    if gf == nil then
        return pts
    end
    for _, folderName in { "Areas", "StrengthSpawns", "StoryLocations", "Spawns", "WorldEventSites" } do
        local folder = gf:FindFirstChild(folderName)
        if folder ~= nil and folder.GetChildren ~= nil then
            for _, child in folder:GetChildren() do
                local pos = nil
                pcall(function()
                    if child:IsA("BasePart") then
                        pos = child.Position
                    elseif child:IsA("Model") then
                        local pp = child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart", true)
                        if pp ~= nil then pos = pp.Position end
                    end
                end)
                if pos ~= nil and finite(pos.X) and finite(pos.Y) and finite(pos.Z) then
                    table.insert(pts, { x = pos.X, y = math.max(pos.Y + 8, 22), z = pos.Z })
                end
            end
        end
    end
    return pts
end

-- Сетка облёта всей карты без слепых дыр (шаг 250 при RevealRange=200 => диагональ полуклетки 176.8 < 200!):
--   1) Именованные локации (Workspace.Game.Areas, StrengthSpawns, StoryLocations...)
--   2) Плотная сетка основного острова (X:-2550..+550, Z:350..2950, шаг 250, Y=28) — 0% слепых зон
--   3) Высотный слой для гор / крыш / Key West (X:-2950..+450, Z:450..3800, шаг 260, Y=170)
--   4) Широкий архипелаг и дальний океан (X:-3450..+2400, Z:-1200..+3850, шаг 260, Y=30)
function stand_out_howler.buildSweepPoints(extraPts)
    local pts = {}
    local function addGrid(x0, x1, z0, z1, step, y)
        local row = 0
        for z = z0, z1, step do
            row += 1
            if row % 2 == 1 then
                for x = x0, x1, step do
                    table.insert(pts, { x = x, y = y, z = z })
                end
            else
                for x = x1, x0, -step do
                    table.insert(pts, { x = x, y = y, z = z })
                end
            end
        end
    end

    -- 1) Сначала все именованные зоны игры (Workspace.Game.Areas, StrengthSpawns, StoryLocations...)
    if type(extraPts) == "table" then
        for _, p in extraPts do
            if type(p) == "table" and finite(p.x) and finite(p.y) and finite(p.z) then
                table.insert(pts, { x = p.x, y = p.y, z = p.z })
            end
        end
    end

    -- 2) Ключевые удалённые/высокие ориентиры (яхта, Key West, острова)
    for _, landmark in {
        { x = -2779, y = 58, z = 3645 },
        { x = -2851, y = 118, z = 3692 },
        { x = -1133, y = 26, z = 2567 },
        { x = 165, y = 24, z = 3474 },
        { x = -1773, y = 24, z = 2946 },
        { x = 949, y = 24, z = 2984 },
        { x = -607, y = 24, z = -34 },
    } do
        table.insert(pts, landmark)
    end

    -- 3) Плотная сетка по основному острову без слепых дыр (шаг 250 -> 177 ст до угла < RevealRange 200)
    addGrid(-2550, 550, 350, 2950, 250, 28)

    -- 4) Высотный слой (горы, небоскрёбы, высокие крыши, Key West)
    addGrid(-2950, 450, 450, 3800, 260, 175)

    -- 5) Широкий океан и дальние острова (запад/восток/юг/север)
    addGrid(-3450, 2400, -1200, 3850, 260, 30)

    return pts
end

-- Ищет уже раскрытые кейсы в Workspace.LocalProps (attr HowlerCaseId).
function stand_out_howler.scanLocalProps(workspace)
    local out = {}
    if workspace == nil then
        return out
    end
    local lp = workspace:FindFirstChild("LocalProps")
    if lp == nil or lp.GetChildren == nil then
        return out
    end
    for _, child in lp:GetChildren() do
        local id = safeAttr(child, "HowlerCaseId")
        if type(id) == "string" and string.match(id, "^case_%d%d$") then
            local part = child.FindFirstChild ~= nil and child:FindFirstChild("PromptAnchor") or nil
            if part == nil then
                part = child.PrimaryPart
            end
            if part == nil and child.FindFirstChildWhichIsA ~= nil then
                part = child:FindFirstChildWhichIsA("BasePart", true)
            end
            local prompt = child.FindFirstChildWhichIsA ~= nil and child:FindFirstChildWhichIsA("ProximityPrompt", true) or nil
            if part ~= nil and part.Position ~= nil then
                local p = part.Position
                if finite(p.X) and finite(p.Y) and finite(p.Z) then
                    out[id] = { id = id, x = p.X, y = p.Y, z = p.Z, prompt = prompt }
                end
            end
        end
    end
    return out
end

-- deps:
--   readOpened() -> string
--   teleportTo(x, y, z)
--   sendHowler(cmd, arg)       ("Hold" | "Open" | "Ready", id)
--   scanLocal() -> { [id] = { id, x, y, z, prompt } }  (optional)
--   scanAreas() -> { { x, y, z }, ... }                (optional)
--   firePrompt(prompt)         (optional)
--   loadSpots() -> string      (optional, читает calcite_so_howler_spots.txt)
--   saveSpots(text)            (optional, сохраняет calcite_so_howler_spots.txt)
--   loadVisited() -> string    (optional, читает calcite_so_howler_visited.txt)
--   saveVisited(text)          (optional, сохраняет calcite_so_howler_visited.txt)
--   notify(title, text)        (optional)
function stand_out_howler.new(deps)
    local initialSpots = {}
    for id, pos in stand_out_howler.known_spots do
        initialSpots[id] = { x = pos.x, y = pos.y, z = pos.z }
    end
    if deps ~= nil and type(deps.loadSpots) == "function" then
        local ok, raw = pcall(deps.loadSpots)
        if ok and type(raw) == "string" then
            for id, pos in stand_out_howler.parseSpotsCache(raw) do
                initialSpots[id] = pos
            end
        end
    end
    local initialVisited = {}
    if deps ~= nil and type(deps.loadVisited) == "function" then
        local okV, rawV = pcall(deps.loadVisited)
        if okV and type(rawV) == "string" then
            initialVisited = stand_out_howler.parseVisitedCache(rawV)
        end
    end
    return setmetatable({
        deps = deps,
        running = false,
        phase = "idle",       -- "idle" | "remote_hold" | "remote_confirm" | "sweep" | "open_settle" | "open_hold" | "open_confirm"
        since = 0,
        startPos = nil,
        revealed = initialSpots,      -- [id] = { x, y, z } (вшитые + файл + живые Reveal)
        visitedZones = initialVisited, -- { { x, z }, ... } сохранённые проверенные зоны
        visitedDirty = false,
        failedOpen = {},      -- [id] = tries
        targetId = nil,
        targetPos = nil,
        targetPrompt = nil,
        remoteWorks = nil,    -- nil = unknown, true = works without distance, false = needs proximity sweep
        sweepPts = nil,
        sweepIdx = 0,
        statusText = "",
    }, Collector)
end

function Collector:_flushVisited()
    if self.visitedDirty and self.deps ~= nil and type(self.deps.saveVisited) == "function" then
        self.visitedDirty = false
        pcall(self.deps.saveVisited, stand_out_howler.formatVisitedCache(self.visitedZones))
    end
end

function Collector:_isVisited(x, y, z)
    local r2 = stand_out_howler.visited_radius * stand_out_howler.visited_radius
    local cy = y or 45
    for _, v in self.visitedZones do
        local dx, dy, dz = x - v.x, cy - (v.y or 45), z - v.z
        if dx * dx + dy * dy + dz * dz < r2 then
            return true
        end
    end
    return false
end

function Collector:_markVisited(x, y, z)
    if not finite(x) or not finite(z) then
        return
    end
    local cy = finite(y) and y or 45
    if not self:_isVisited(x, cy, z) then
        table.insert(self.visitedZones, { x = x, y = cy, z = z })
        self.visitedDirty = true
    end
end

function Collector:onReveal(id, x, y, z)
    if type(id) == "string" and finite(x) and finite(y) and finite(z) then
        local prev = self.revealed[id]
        local changed = prev == nil
            or math.abs(prev.x - x) > 0.5
            or math.abs(prev.y - y) > 0.5
            or math.abs(prev.z - z) > 0.5
        self.revealed[id] = { x = x, y = y, z = z }
        if changed and self.deps ~= nil and type(self.deps.saveSpots) == "function" then
            pcall(self.deps.saveSpots, stand_out_howler.formatSpotsCache(self.revealed))
        end
    end
end

function Collector:stop(silent)
    self:_flushVisited()
    local wasRunning = self.running
    self.running = false
    self.phase = "idle"
    self.targetId = nil
    self.targetPos = nil
    self.targetPrompt = nil
    if wasRunning and self.startPos ~= nil and self.deps.teleportTo ~= nil then
        local sp = self.startPos
        self.startPos = nil
        pcall(self.deps.teleportTo, sp.x, sp.y, sp.z)
    else
        self.startPos = nil
    end
    local _, cnt = stand_out_howler.decodeOpened(self.deps.readOpened())
    self.statusText = string.format("Кейсы: %d/%d", cnt, stand_out_howler.total)
    if wasRunning and not silent and self.deps.notify ~= nil then
        pcall(self.deps.notify, "Howler's Cases", string.format("Сбор остановлен (%d/%d).", cnt, stand_out_howler.total))
    end
end

function Collector:toggle(now, meX, meY, meZ)
    if self.running then
        self:stop(false)
        return false
    end
    local raw = self.deps.readOpened()
    local _, cnt = stand_out_howler.decodeOpened(raw)
    if cnt >= stand_out_howler.total then
        self.statusText = string.format("Кейсы: %d/%d (все собраны!)", cnt, stand_out_howler.total)
        if self.deps.notify ~= nil then
            pcall(self.deps.notify, "Howler's Cases", "Все 10 кейсов Howler уже собраны!")
        end
        return false
    end
    if meX ~= nil and meY ~= nil and meZ ~= nil then
        self.startPos = { x = meX, y = meY, z = meZ }
    else
        self.startPos = nil
    end
    self.running = true
    self.failedOpen = {}
    self.remoteWorks = nil
    -- Оставляем только ещё НЕ посещённые 3D-точки (Areas + плотная сетка + высоты + дальний океан)
    local areaPts = (self.deps ~= nil and type(self.deps.scanAreas) == "function") and self.deps.scanAreas() or nil
    local allPts = stand_out_howler.buildSweepPoints(areaPts)
    local freshPts = {}
    for _, pt in allPts do
        if not self:_isVisited(pt.x, pt.y, pt.z) then
            table.insert(freshPts, pt)
        end
    end
    if #freshPts == 0 then
        self.visitedZones = {}
        self.visitedDirty = true
        self:_flushVisited()
        freshPts = allPts
    end
    self.sweepPts = freshPts
    self.sweepIdx = 0
    if meX ~= nil and meY ~= nil and meZ ~= nil then
        self:_markVisited(meX, meY, meZ)
    end
    self.targetId = nil
    self.targetPos = nil
    self.targetPrompt = nil
    self.phase = "idle"
    self.since = now
    self.statusText = string.format("Кейсы: %d/%d | старт...", cnt, stand_out_howler.total)
    if self.deps.notify ~= nil then
        pcall(self.deps.notify, "Howler's Cases", string.format("Запущен сбор кейсов (%d/%d)...", cnt, stand_out_howler.total))
    end
    return true
end

function Collector:_findRevealedUnopened(opened)
    local localCases = self.deps.scanLocal ~= nil and self.deps.scanLocal() or nil
    if type(localCases) == "table" then
        for id, info in localCases do
            self:onReveal(id, info.x, info.y, info.z)
            if self.revealed[id] ~= nil then
                self.revealed[id].prompt = info.prompt
            end
        end
    end
    for _, id in stand_out_howler.ids do
        if not opened[id] and self.revealed[id] ~= nil and (self.failedOpen[id] or 0) < 2 then
            return id, self.revealed[id]
        end
    end
    return nil, nil
end

function Collector:_finish(cnt, msg)
    self:_flushVisited()
    local sp = self.startPos
    self.running = false
    self.phase = "idle"
    self.targetId = nil
    self.targetPos = nil
    self.targetPrompt = nil
    self.startPos = nil
    if sp ~= nil and self.deps.teleportTo ~= nil then
        pcall(self.deps.teleportTo, sp.x, sp.y, sp.z)
    end
    self.statusText = string.format("Кейсы: %d/%d", cnt, stand_out_howler.total)
    if self.deps.notify ~= nil then
        pcall(self.deps.notify, "Howler's Cases", msg)
    end
end

function Collector:update(now, meX, meY, meZ)
    local raw = self.deps.readOpened()
    local opened, cnt = stand_out_howler.decodeOpened(raw)

    if not self.running then
        self.statusText = string.format("Кейсы: %d/%d", cnt, stand_out_howler.total)
        return false
    end

    if meX == nil or meY == nil or meZ == nil then
        return true
    end
    if self.startPos == nil then
        self.startPos = { x = meX, y = meY, z = meZ }
    end

    if cnt >= stand_out_howler.total then
        self:_finish(cnt, string.format("Готово! Собраны все %d/%d кейсов Howler!", cnt, stand_out_howler.total))
        return false
    end

    -- 1) Этап проверки / прямого открытия по ремоуту (если сервер не требует близости)
    if self.phase == "remote_hold" then
        if opened[self.targetId] then
            self.remoteWorks = true
            self.phase = "idle"
            self.targetId = nil
        elseif now - self.since >= stand_out_howler.hold_duration then
            self.deps.sendHowler("Open", self.targetId)
            self.phase = "remote_confirm"
            self.since = now
        end
        self.statusText = string.format("Кейсы: %d/%d | %s", cnt, stand_out_howler.total, tostring(self.targetId or ""))
        return true
    elseif self.phase == "remote_confirm" then
        if opened[self.targetId] then
            self.remoteWorks = true
            self.phase = "idle"
            self.targetId = nil
        elseif now - self.since >= stand_out_howler.confirm_wait then
            -- Сервер требует физически быть у кейса -> переходим на быстрый облёт карты
            self.remoteWorks = false
            self.targetId = nil
            self.phase = "sweep"
            self.since = now - stand_out_howler.sweep_step
        end
        return true
    end

    -- 2) Этап открытия физически найденного кейса (телепорт к кейсу -> Hold -> 0.92s -> Open)
    if self.phase == "open_settle" then
        if opened[self.targetId] then
            self.phase = "sweep"
            self.targetId = nil
            return true
        end
        local tp = self.targetPos
        self.deps.teleportTo(tp.x, tp.y + stand_out_howler.above, tp.z)
        if now - self.since >= stand_out_howler.settle then
            self.deps.sendHowler("Hold", self.targetId)
            self.phase = "open_hold"
            self.since = now
        end
        self.statusText = string.format("Кейсы: %d/%d | открываю %s", cnt, stand_out_howler.total, tostring(self.targetId))
        return true
    elseif self.phase == "open_hold" then
        if opened[self.targetId] then
            self.phase = "sweep"
            self.targetId = nil
            return true
        end
        local tp = self.targetPos
        self.deps.teleportTo(tp.x, tp.y + stand_out_howler.above, tp.z)
        if now - self.since >= stand_out_howler.hold_duration then
            self.deps.sendHowler("Open", self.targetId)
            if self.targetPrompt ~= nil and self.deps.firePrompt ~= nil then
                pcall(self.deps.firePrompt, self.targetPrompt)
            end
            self.phase = "open_confirm"
            self.since = now
        end
        self.statusText = string.format("Кейсы: %d/%d | открываю %s", cnt, stand_out_howler.total, tostring(self.targetId))
        return true
    elseif self.phase == "open_confirm" then
        if opened[self.targetId] then
            self.targetId = nil
            self.targetPos = nil
            self.targetPrompt = nil
            self.phase = "sweep"
            self.since = now - stand_out_howler.sweep_step
            return true
        end
        local tp = self.targetPos
        self.deps.teleportTo(tp.x, tp.y + stand_out_howler.above, tp.z)
        if now - self.since >= stand_out_howler.confirm_wait then
            self.failedOpen[self.targetId] = (self.failedOpen[self.targetId] or 0) + 1
            self.targetId = nil
            self.targetPos = nil
            self.targetPrompt = nil
            self.phase = "sweep"
            self.since = now - stand_out_howler.sweep_step
        end
        return true
    end

    -- 3) Сначала проверяем, не раскрылся ли уже какой-то неоткрытый кейс (OnClientEvent Reveal / LocalProps)
    local revId, revInfo = self:_findRevealedUnopened(opened)
    if revId ~= nil then
        self.targetId = revId
        self.targetPos = { x = revInfo.x, y = revInfo.y, z = revInfo.z }
        self.targetPrompt = revInfo.prompt
        self.phase = "open_settle"
        self.since = now
        self:_markVisited(revInfo.x, revInfo.y, revInfo.z)
        self.deps.teleportTo(revInfo.x, revInfo.y + stand_out_howler.above, revInfo.z)
        self.statusText = string.format("Кейсы: %d/%d | лечу к %s", cnt, stand_out_howler.total, revId)
        return true
    end

    -- 4) Если прямой ремоут ещё не проверен или работает — пробуем следующий неоткрытый кейс по ремоуту
    if self.remoteWorks ~= false then
        local rem = stand_out_howler.unopenedIds(raw)
        if #rem > 0 then
            self.targetId = rem[1]
            self.deps.sendHowler("Hold", self.targetId)
            self.phase = "remote_hold"
            self.since = now
            self.statusText = string.format("Кейсы: %d/%d | %s", cnt, stand_out_howler.total, self.targetId)
            return true
        end
    end

    -- 5) Облёт сетки карты, пропуская уже посещённые зоны (радиус visited_radius = 230 ст)
    self.phase = "sweep"
    if now - self.since >= stand_out_howler.sweep_step then
        local pt = nil
        while true do
            self.sweepIdx += 1
            local cand = self.sweepPts[self.sweepIdx]
            if cand == nil then
                break
            end
            if not self:_isVisited(cand.x, cand.y, cand.z) then
                pt = cand
                break
            end
        end
        if pt == nil then
            self:_finish(cnt, string.format("Облёт завершён: собрано %d/%d кейсов Howler.", cnt, stand_out_howler.total))
            return false
        end
        self.since = now
        self:_markVisited(pt.x, pt.y, pt.z)
        if #self.visitedZones % 5 == 0 then
            self:_flushVisited()
        end
        self.deps.teleportTo(pt.x, pt.y, pt.z)
    end
    local totalPts = self.sweepPts ~= nil and #self.sweepPts or 1
    self.statusText = string.format("Кейсы: %d/%d | поиск %d/%d", cnt, stand_out_howler.total, math.min(self.sweepIdx, totalPts), totalPts)
    return true
end

return stand_out_howler
end

__modules["stand_out_mobs"] = function(require)
-- Stand Out Mob Farming: сканер враждебных мобов, расчёт позиции (Behind/Below/Over/Front),
-- Auto Summon (E), Auto Skill (1..9 с проверкой кулдауна и SkillActive) и M1-фолбэк.
-- Факты игры из tools/standout_probe_mobs.lua:
--   • мобы лежат в Workspace.Game.Players (не реальные игроки), атрибут FightableNPC = true,
--     имя типа в атрибуте Config (Seal, DIO, ...), боссы помечены BossNPC = true / CommandBoss = true
--   • состояние стенда: Character:GetAttribute("Summoned") == true, NoSummon == true
--   • активный скилл: Player.Data.SkillActive (BoolValue) — пока true, не жмём другие скиллы/M1
--   • кулдауны скиллов: PlayerGui.MainHUD.Skills.<Skill>.Cooldown.Size.X.Scale > 0.02
-- Чистая логика поверх deps, проверяется tests/stand_out_mobs_test.lua.
local stand_out_mobs = {}

stand_out_mobs.methods = { "Behind", "Below", "Over", "Front" }
stand_out_mobs.skill_keys = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }

stand_out_mobs.summon_cooldown = 1.2
stand_out_mobs.summon_settle = 0.25
stand_out_mobs.skill_interval = 0.25
stand_out_mobs.skill_retry = 0.85
stand_out_mobs.heavy_cooldown = 1.6
stand_out_mobs.m1_interval = 0.18
stand_out_mobs.post_skill_m1_delay = 0.16

local Farmer = {}
Farmer.__index = Farmer

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function safeAttr(obj, name)
    if obj == nil or obj.GetAttribute == nil then
        return nil
    end
    local ok, val = pcall(function()
        return obj:GetAttribute(name)
    end)
    if ok then
        return val
    end
    return nil
end

local function mobConfigName(model)
    local cfg = safeAttr(model, "Config")
    if type(cfg) == "string" and cfg ~= "" and cfg ~= "Default" then
        return cfg
    end
    local raw = model.Name or "Mob"
    local stripped = string.match(raw, "^(.-)_%d+$")
    return stripped or raw
end

local function safeIsA(obj, cls)
    if obj == nil or obj.IsA == nil then
        return false
    end
    local ok, res = pcall(function()
        return obj:IsA(cls)
    end)
    return ok and res == true
end

local function isAliveMob(entry)
    if entry == nil or entry.model == nil or entry.model.Parent == nil then
        return false
    end
    local hum = entry.humanoid
    if hum == nil or hum.Parent == nil then
        return false
    end
    local hp = hum.Health
    if not finite(hp) or hp <= 0 then
        return false
    end
    local root = entry.root
    if root == nil or root.Parent == nil or root.CFrame == nil then
        return false
    end
    return true
end

local function tryAddMob(out, model, playerNames, requireNoDialogue)
    if not safeIsA(model, "Model") then
        return
    end
    if playerNames ~= nil and playerNames[model.Name] then
        return
    end
    if safeAttr(model, "Stand") == true then
        return
    end
    if safeAttr(model, "FightableNPC") ~= true then
        return
    end
    if requireNoDialogue then
        if safeAttr(model, "DialogueOverride") ~= nil then
            return
        end
        if model.FindFirstChildWhichIsA ~= nil and model:FindFirstChildWhichIsA("ClickDetector", true) ~= nil then
            return
        end
    end

    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum == nil or not finite(hum.Health) or hum.Health <= 0 then
        return
    end
    local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
    if root == nil or (root.CFrame == nil and not safeIsA(root, "BasePart")) then
        return
    end

    table.insert(out, {
        model = model,
        humanoid = hum,
        root = root,
        name = mobConfigName(model),
        rawName = model.Name or "",
        isBoss = safeAttr(model, "BossNPC") == true or safeAttr(model, "CommandBoss") == true,
    })
end

-- Сканирует живых враждебных мобов (FightableNPC = true) в Workspace.Game.Players (+ боевые NPC без диалога).
function stand_out_mobs.scan(workspace, playerNames)
    local out = {}
    if workspace == nil then
        return out
    end
    local gameFolder = workspace:FindFirstChild("Game")
    if gameFolder == nil then
        return out
    end

    local playersFolder = gameFolder:FindFirstChild("Players")
    if playersFolder ~= nil and playersFolder.GetChildren ~= nil then
        for _, child in playersFolder:GetChildren() do
            tryAddMob(out, child, playerNames, false)
        end
    end

    local npcsFolder = gameFolder:FindFirstChild("NPCs")
    if npcsFolder ~= nil and npcsFolder.GetChildren ~= nil then
        for _, child in npcsFolder:GetChildren() do
            tryAddMob(out, child, playerNames, true)
        end
    end

    return out
end

-- Проверяет, подходит ли моб под фильтр (Все / Без боссов / Только боссы + опциональное имя).
function stand_out_mobs.matches(entry, opts)
    if entry == nil or opts == nil then
        return false
    end
    local filter = opts.filter or "All"
    if filter == "NoBosses" and entry.isBoss then
        return false
    elseif filter == "BossesOnly" and not entry.isBoss then
        return false
    end

    local query = opts.nameFilter
    if type(query) == "string" then
        local trimmed = string.lower(string.match(query, "^%s*(.-)%s*$") or "")
        if trimmed ~= "" then
            local n1 = string.lower(entry.name or "")
            local n2 = string.lower(entry.rawName or "")
            if string.find(n1, trimmed, 1, true) == nil and string.find(n2, trimmed, 1, true) == nil then
                return false
            end
        end
    end

    return true
end

-- Читает из PlayerGui.MainHUD.Skills какие слоты 1..9 сейчас на кулдауне.
-- Возвращает таблицу { [slotNumber] = true } для слотов на кулдауне.
-- ВАЖНО: Key может быть ImageLabel (без свойства Text), поэтому доступ к свойствам GUI только через safeIsA / pcall.
function stand_out_mobs.guiCooldowns(playerGui)
    local onCd = {}
    if playerGui == nil then
        return onCd
    end

    pcall(function()
        local mainHud = playerGui:FindFirstChild("MainHUD")
        local skills = mainHud and mainHud:FindFirstChild("Skills")
        if skills == nil or skills.GetChildren == nil then
            return
        end

        local frames = {}
        for _, child in skills:GetChildren() do
            if child.Name ~= "Template" and child.Name ~= "TemplateTip" and child.Name ~= "Ability" then
                if safeIsA(child, "GuiObject") or child.ClassName == "Frame" then
                    local cd = child.FindFirstChild ~= nil and child:FindFirstChild("Cooldown") or nil
                    if cd ~= nil and child.Visible ~= false then
                        table.insert(frames, child)
                    end
                end
            end
        end

        table.sort(frames, function(a, b)
            local la = a.LayoutOrder or 0
            local lb = b.LayoutOrder or 0
            if la ~= lb then
                return la < lb
            end
            return (a.Name or "") < (b.Name or "")
        end)

        for idx, frame in frames do
            local slot = idx
            local keyObj = frame:FindFirstChild("Key")
            if keyObj ~= nil then
                local txt = nil
                if safeIsA(keyObj, "TextLabel") or safeIsA(keyObj, "TextButton") then
                    txt = keyObj.Text
                elseif keyObj.GetDescendants ~= nil then
                    for _, d in keyObj:GetDescendants() do
                        if safeIsA(d, "TextLabel") or safeIsA(d, "TextButton") then
                            if type(d.Text) == "string" and string.match(d.Text, "^%s*[1-9]%s*$") then
                                txt = d.Text
                                break
                            end
                        end
                    end
                end
                if type(txt) == "string" then
                    local parsed = tonumber(string.match(txt, "[1-9]"))
                    if parsed ~= nil then
                        slot = parsed
                    end
                end
            end

            local cd = frame:FindFirstChild("Cooldown")
            if cd ~= nil and (safeIsA(cd, "GuiObject") or cd.ClassName == "Frame") then
                local sz = cd.Size
                if sz ~= nil and sz.X ~= nil and finite(sz.X.Scale) and sz.X.Scale > 0.02 then
                    onCd[slot] = true
                end
            end
        end
    end)

    return onCd
end

-- Расчёт позиции персонажа и точки взгляда относительно моба.
-- mobPos = { X, Y, Z }, mobLook = { X, Y, Z } (LookVector корня моба).
-- Возвращает px, py, pz, lookX, lookY, lookZ.
function stand_out_mobs.goalPose(mobPos, mobLook, method, distance)
    local d = tonumber(distance) or 6
    if d < 1 then d = 1 end

    local lx = mobLook and mobLook.X or 0
    local lz = mobLook and mobLook.Z or -1
    local horiz = math.sqrt(lx * lx + lz * lz)
    if horiz > 1e-4 then
        lx = lx / horiz
        lz = lz / horiz
    else
        lx, lz = 0, -1
    end

    local mx, my, mz = mobPos.X, mobPos.Y, mobPos.Z
    local m = method or "Behind"

    if m == "Front" then
        return mx + lx * d, my, mz + lz * d, mx, my, mz
    elseif m == "Over" then
        return mx - lx * 0.05, my + d, mz - lz * 0.05, mx, my, mz
    elseif m == "Below" then
        return mx - lx * 0.05, my - d, mz - lz * 0.05, mx, my, mz
    end

    -- Behind (по умолчанию)
    return mx - lx * d, my, mz - lz * d, mx, my, mz
end

-- deps:
--   setPose(px, py, pz, lookX, lookY, lookZ)
--   setNoclip(on)
--   pressKey(keyName)            "E", "1".."9"
--   clickM1()
--   isSummoned() -> boolean
--   canSummon() -> boolean       true если есть стенд и NoSummon ~= true
--   isSkillActive() -> boolean
--   isStunned() -> boolean
--   guiCooldowns() -> { [1..9] = true }  (optional)
function stand_out_mobs.new(deps)
    return setmetatable({
        deps = deps,
        target = nil,
        kills = 0,
        lastMobPos = nil,
        wasBelow = false,
        lastSummonAt = -99,
        lastSkillAt = -99,
        lastRAt = -99,
        lastM1At = -99,
        nextSkillIdx = 1,
        triedAt = {},
        statusText = "",
    }, Farmer)
end

function Farmer:_exitBelow()
    if self.wasBelow then
        self.wasBelow = false
        if self.lastMobPos ~= nil and self.deps.setPose ~= nil then
            local p = self.lastMobPos
            self.deps.setPose(p.X, p.Y + 3, p.Z, p.X, p.Y + 3, p.Z - 1)
        end
        if self.deps.setNoclip ~= nil then
            self.deps.setNoclip(false)
        end
    end
end

function Farmer:stop()
    self:_exitBelow()
    self.target = nil
    self.lastMobPos = nil
    self.statusText = ""
end

local function pickNearest(entries, opts, meX, meY, meZ)
    if entries == nil then
        return nil
    end
    local best, bestDist = nil, math.huge
    for _, entry in entries do
        if not isAliveMob(entry) or not stand_out_mobs.matches(entry, opts) then
            continue
        end
        local p = entry.root.Position or entry.root.CFrame.Position
        if p == nil then
            continue
        end
        local dx, dy, dz = p.X - meX, p.Y - meY, p.Z - meZ
        local dist = dx * dx + dy * dy + dz * dz
        if dist < bestDist then
            bestDist = dist
            best = entry
        end
    end
    return best
end

function Farmer:update(now, entries, opts, meX, meY, meZ)
    if meX == nil or meY == nil or meZ == nil then
        self:stop()
        return nil
    end

    -- Проверяем текущую цель: умерла или перестала подходить под фильтр
    local target = self.target
    if target ~= nil then
        if not isAliveMob(target) then
            self.kills += 1
            self.target = nil
            target = nil
        elseif not stand_out_mobs.matches(target, opts) then
            self.target = nil
            target = nil
        end
    end

    if target == nil then
        target = pickNearest(entries, opts, meX, meY, meZ)
        self.target = target
    end

    if target == nil then
        self:_exitBelow()
        self.statusText = ""
        return nil
    end

    local cf = target.root.CFrame
    local mobPos = target.root.Position or cf.Position
    local mobLook = cf.LookVector
    self.lastMobPos = { X = mobPos.X, Y = mobPos.Y, Z = mobPos.Z }

    local method = opts.method or "Behind"
    if method == "Below" then
        if not self.wasBelow then
            self.wasBelow = true
        end
        if self.deps.setNoclip ~= nil then
            self.deps.setNoclip(true)
        end
    elseif self.wasBelow then
        self:_exitBelow()
    end

    local px, py, pz, lx, ly, lz = stand_out_mobs.goalPose(mobPos, mobLook, method, opts.distance)
    self.deps.setPose(px, py, pz, lx, ly, lz)

    local hp = math.floor((target.humanoid.Health or 0) + 0.5)
    local maxHp = math.floor((target.humanoid.MaxHealth or 0) + 0.5)
    self.statusText = string.format("%s (%d/%d)", target.name, hp, maxHp)

    -- Если в стане или скилл уже активен (например, барраж) — просто держим позицию и не перебиваем
    if self.deps.isStunned ~= nil and self.deps.isStunned() then
        return target
    end
    if self.deps.isSkillActive ~= nil and self.deps.isSkillActive() then
        return target
    end

    -- 1. Auto Summon (E)
    if opts.autoSummon and self.deps.canSummon ~= nil and self.deps.canSummon() then
        if self.deps.isSummoned ~= nil and not self.deps.isSummoned() then
            if now - self.lastSummonAt >= stand_out_mobs.summon_cooldown then
                self.lastSummonAt = now
                self.deps.pressKey("E")
            end
            return target
        end
    end

    if now - self.lastSummonAt < stand_out_mobs.summon_settle then
        return target
    end

    -- 2. Auto Skill (1..9)
    local firedSkill = false
    if opts.autoSkill and opts.skills ~= nil and now - self.lastSkillAt >= stand_out_mobs.skill_interval then
        local onCd = (self.deps.guiCooldowns ~= nil and self.deps.guiCooldowns()) or {}
        local total = #stand_out_mobs.skill_keys
        for offset = 0, total - 1 do
            local idx = ((self.nextSkillIdx - 1 + offset) % total) + 1
            local keyStr = stand_out_mobs.skill_keys[idx]
            if opts.skills[keyStr] == true and onCd[idx] ~= true then
                local prev = self.triedAt[idx]
                if prev == nil or now - prev >= stand_out_mobs.skill_retry then
                    self.triedAt[idx] = now
                    self.lastSkillAt = now
                    self.nextSkillIdx = (idx % total) + 1
                    self.deps.pressKey(keyStr)
                    firedSkill = true
                    break
                end
            end
        end
    end

    -- 2.5. Auto Heavy (R) по кулдауну
    if not firedSkill and opts.autoR and now - self.lastSkillAt >= stand_out_mobs.skill_interval
        and now - self.lastRAt >= stand_out_mobs.heavy_cooldown then
        self.lastRAt = now
        self.lastSkillAt = now
        self.deps.pressKey("R")
        firedSkill = true
    end

    -- 3. M1 fallback когда скиллы на кулдауне / отключены
    if not firedSkill and opts.autoM1 then
        if now - self.lastSkillAt >= stand_out_mobs.post_skill_m1_delay and now - self.lastM1At >= stand_out_mobs.m1_interval then
            self.lastM1At = now
            self.deps.clickM1()
        end
    end

    return target
end

return stand_out_mobs
end

__modules["stand_out_pickup"] = function(require)
-- Stand Out Auto Pick Up: сканер мировых предметов, закопанных припасов и морского мусора (Sea Trash).
-- Факты игры из tools/standout_probe_items.lua и tools/standout_probe_seatrash.lua:
--   • Workspace.Game.SpawnedItems / WorldEventDrops -> DroppedItem (attr ItemName)
--     внутри ProximityPrompt "WorldItemPickup" (HoldDuration=0, MaxActivationDistance=10)
--   • Workspace.Game.Gardening.Foraging -> BuriedSupplies (attr GardenSupplyItem, GardenSupplyAvailable)
--     внутри ProximityPrompt "GardenGather" (HoldDuration=1.2, MaxActivationDistance=9)
--   • Workspace.Game.Map.ScrapPlatform (attr GardenOceanScrap=true, Destroyed~=true)
--     внутри DebrisPiece (attr GardenGatherable="Steel"/...) — разбивается ударом R, даёт +Dalas/ресурсы
-- Чистая логика поверх переданных зависимостей, проверяется tests/stand_out_pickup_test.lua.
local stand_out_pickup = {}

stand_out_pickup.above = 3.0       -- студов над предметом при телепорте (в пределах MaxActivationDistance 9..10)
stand_out_pickup.settle = 0.15     -- пауза после телепорта, чтобы сервер увидел персонажа рядом
stand_out_pickup.extra_hold = 0.12 -- запас к HoldDuration промпта
stand_out_pickup.give_up = 1.5     -- сколько ждать исчезновения предмета после подбора
stand_out_pickup.skip_for = 10.0   -- на сколько секунд пропустить предмет, который не подобрался
stand_out_pickup.hop_delay = 3.0   -- сколько секунд карта должна быть пустой перед сменой сервера
stand_out_pickup.hop_retry = 12.0  -- пауза между повторными попытками телепорта, если сервер оказался полон
stand_out_pickup.trash_dist = 4.5  -- студов перед DebrisPiece при разбитии морского мусора на R
stand_out_pickup.trash_above = 1.8 -- студов над DebrisPiece (держит персонажа выше поверхности моря Y=5.47)
stand_out_pickup.trash_r_cd = 1.4  -- пауза между нажатиями R по одной куче Sea Trash
stand_out_pickup.trash_give_up = 6.5 -- через сколько секунд пропустить неразбиваемую кучу Sea Trash

local Picker = {}
Picker.__index = Picker

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function safeAttr(obj, name)
    if obj == nil or obj.GetAttribute == nil then
        return nil
    end
    local ok, val = pcall(function()
        return obj:GetAttribute(name)
    end)
    if ok then
        return val
    end
    return nil
end

local function firstBasePart(root)
    if root == nil then
        return nil
    end
    if root.IsA ~= nil and root:IsA("BasePart") then
        return root
    end
    if root.IsA ~= nil and root:IsA("Model") and root.PrimaryPart ~= nil then
        return root.PrimaryPart
    end
    if root.GetDescendants ~= nil then
        for _, desc in root:GetDescendants() do
            if desc.IsA ~= nil and desc:IsA("BasePart") then
                return desc
            end
        end
    end
    return nil
end

local function findEnabledPrompt(container)
    if container == nil then
        return nil
    end
    if container.IsA ~= nil and container:IsA("ProximityPrompt") then
        return container
    end
    if container.GetDescendants == nil then
        return nil
    end
    for _, desc in container:GetDescendants() do
        if desc.IsA ~= nil and desc:IsA("ProximityPrompt") then
            local reach = desc.MaxActivationDistance
            if desc.Enabled == true and finite(reach) and reach > 0 then
                return desc
            end
        end
    end
    return nil
end

-- Координаты точки предмета: приоритет у родителя промпта (Handle/Attachment), иначе первый BasePart модели.
function stand_out_pickup.entryPosition(entry)
    if entry == nil or entry.model == nil or entry.model.Parent == nil then
        return nil, nil, nil
    end
    if entry.kind == "seatrash" then
        local part = entry.part
        if part ~= nil and part.Parent ~= nil and part.Position ~= nil then
            local p = part.Position
            if finite(p.X) and finite(p.Y) and finite(p.Z) then
                return p.X, p.Y, p.Z
            end
        end
        local fb = firstBasePart(entry.debris or entry.model)
        if fb ~= nil and fb.Position ~= nil then
            local p = fb.Position
            if finite(p.X) and finite(p.Y) and finite(p.Z) then
                return p.X, p.Y, p.Z
            end
        end
        return nil, nil, nil
    end

    local prompt = entry.prompt
    if prompt == nil or prompt.Parent == nil then
        return nil, nil, nil
    end

    local holder = prompt.Parent
    if holder.IsA ~= nil and holder:IsA("Attachment") and holder.WorldPosition ~= nil then
        local p = holder.WorldPosition
        if finite(p.X) and finite(p.Y) and finite(p.Z) then
            return p.X, p.Y, p.Z
        end
    elseif holder.IsA ~= nil and holder:IsA("BasePart") and holder.Position ~= nil then
        local p = holder.Position
        if finite(p.X) and finite(p.Y) and finite(p.Z) then
            return p.X, p.Y, p.Z
        end
    end

    local part = entry.part
    if part ~= nil and part.Parent ~= nil and part.Position ~= nil then
        local p = part.Position
        if finite(p.X) and finite(p.Y) and finite(p.Z) then
            return p.X, p.Y, p.Z
        end
    end

    return nil, nil, nil
end

local function promptWorking(entry)
    if entry == nil or entry.model == nil or entry.model.Parent == nil then
        return false
    end
    if entry.kind == "seatrash" then
        if safeAttr(entry.model, "Destroyed") == true then
            return false
        end
        if entry.debris ~= nil and entry.debris.Parent == nil then
            return false
        end
        return true
    end
    local prompt = entry.prompt
    if prompt == nil or prompt.Parent == nil then
        return false
    end
    local reach = prompt.MaxActivationDistance
    if prompt.Enabled ~= true or not finite(reach) or reach <= 0 then
        return false
    end
    if entry.kind == "buried" then
        local avail = safeAttr(entry.model, "GardenSupplyAvailable")
        if avail == false then
            return false
        end
    end
    return true
end

local function scanSeaTrash(out, mapFolder)
    if mapFolder == nil or mapFolder.GetChildren == nil then
        return
    end
    for _, child in mapFolder:GetChildren() do
        if safeAttr(child, "GardenOceanScrap") == true and safeAttr(child, "Destroyed") ~= true then
            local debris = child.FindFirstChild ~= nil and child:FindFirstChild("DebrisPiece") or nil
            if debris == nil and child.GetChildren ~= nil then
                for _, sub in child:GetChildren() do
                    if safeAttr(sub, "GardenGatherable") ~= nil then
                        debris = sub
                        break
                    end
                end
            end
            local part = firstBasePart(debris) or firstBasePart(child)
            if part ~= nil then
                local mat = debris ~= nil and safeAttr(debris, "GardenGatherable") or nil
                local label = (type(mat) == "string" and mat ~= "") and ("Sea Trash (" .. mat .. ")") or "Sea Trash"
                table.insert(out, {
                    kind = "seatrash",
                    name = label,
                    model = child,
                    debris = debris,
                    part = part,
                    prompt = nil,
                })
            end
        end
    end
end

local function scanFolder(out, folder, kind, attrName, depth)
    if folder == nil or folder.GetChildren == nil or (depth or 0) > 3 then
        return
    end
    for _, child in folder:GetChildren() do
        -- WorldEventDrops может содержать вложенные Folder (напр. MoneyTransport_<guid>) с несколькими дропами внутри
        if child.IsA ~= nil and child:IsA("Folder") then
            scanFolder(out, child, kind, attrName, (depth or 0) + 1)
            continue
        end
        if kind == "buried" and safeAttr(child, "GardenSupplyAvailable") == false then
            continue
        end
        local prompt = findEnabledPrompt(child)
        if prompt == nil then
            continue
        end
        local part = firstBasePart(child)
        local name = safeAttr(child, attrName)
        if type(name) ~= "string" or name == "" then
            if type(prompt.ObjectText) == "string" and prompt.ObjectText ~= "" then
                name = prompt.ObjectText
            else
                name = child.Name or "Item"
            end
        end
        table.insert(out, {
            kind = kind,
            name = name,
            model = child,
            prompt = prompt,
            part = part,
        })
    end
end

-- Собирает список доступных к подбору предметов на карте Stand Out.
function stand_out_pickup.scan(workspace, opts)
    local found = {}
    if workspace == nil or opts == nil then
        return found
    end
    local gameFolder = workspace:FindFirstChild("Game")
    if gameFolder == nil then
        return found
    end

    if opts.worldItems then
        scanFolder(found, gameFolder:FindFirstChild("SpawnedItems"), "item", "ItemName")
        scanFolder(found, gameFolder:FindFirstChild("WorldEventDrops"), "item", "ItemName")
    end

    if opts.buried then
        local gardening = gameFolder:FindFirstChild("Gardening")
        local foraging = gardening and gardening:FindFirstChild("Foraging") or nil
        scanFolder(found, foraging, "buried", "GardenSupplyItem")
    end

    if opts.seaTrash then
        scanSeaTrash(found, gameFolder:FindFirstChild("Map"))
    end

    return found
end

-- Выбирает подходящий открытый сервер из списка Roblox Games API (предпочитает малолюдные и непосещённые).
function stand_out_pickup.pickServer(servers, currentJobId, visited)
    if type(servers) ~= "table" then
        return nil
    end

    local function findBest(ignoreVisited)
        local bestId, bestPlaying = nil, math.huge
        for _, srv in servers do
            if type(srv) ~= "table" then
                continue
            end
            local id = srv.id
            local playing = tonumber(srv.playing)
            local maxP = tonumber(srv.maxPlayers)
            if type(id) == "string" and id ~= "" and id ~= currentJobId
                and playing ~= nil and maxP ~= nil and playing < maxP then
                if ignoreVisited or visited == nil or not visited[id] then
                    -- Предпочитаем серверы с меньшим числом игроков (больше нетронутых предметов)
                    local score = playing > 0 and playing or (maxP + 1)
                    if score < bestPlaying then
                        bestPlaying = score
                        bestId = id
                    end
                end
            end
        end
        return bestId
    end

    return findBest(false) or findBest(true)
end

-- deps:
--   teleportTo(x, y, z)
--   firePrompt(prompt)    (optional)
--   holdBegin(prompt)
--   holdEnd(prompt)
--   serverHop()           (optional, вызывается когда на сервере нет предметов и включено hopWhenEmpty)
--   positionOf(entry) -> x, y, z or nil  (optional, defaults to stand_out_pickup.entryPosition)
function stand_out_pickup.new(deps)
    return setmetatable({
        deps = deps,
        state = "idle",      -- "idle" | "arriving" | "holding" | "waiting" | "breaking"
        target = nil,
        since = 0,
        lastRAt = -99,
        lastSummonAt = -99,
        skipped = {},        -- prompt or model -> timestamp
        taken = 0,
        returnPos = nil,     -- { x, y, z } сохранённая точка до начала серии подборов
        lastTargetName = "",
        emptySince = nil,    -- когда карта стала пустой (для отсчёта hop_delay)
        lastHopTry = -99,
    }, Picker)
end

function Picker:stop()
    if self.state == "holding" and self.target ~= nil and self.target.prompt ~= nil and self.deps.holdEnd ~= nil then
        pcall(self.deps.holdEnd, self.target.prompt)
    end
    self.state = "idle"
    self.target = nil
    self.lastRAt = -99
    self.lastSummonAt = -99
    self.returnPos = nil
    self.lastTargetName = ""
    self.emptySince = nil
    self.lastHopTry = -99
end

local function positionForTrash(deps, tx, ty, tz)
    local px, py, pz = tx, ty + stand_out_pickup.trash_above, tz + stand_out_pickup.trash_dist
    if deps.faceAt ~= nil then
        deps.faceAt(px, py, pz, tx, ty, tz)
    else
        deps.teleportTo(px, py, pz)
    end
end

function Picker:update(now, entries, opts, meX, meY, meZ)
    if meX == nil or meY == nil or meZ == nil then
        self:stop()
        return nil
    end

    local posOf = self.deps.positionOf or stand_out_pickup.entryPosition
    local target = self.target
    local tx, ty, tz = nil, nil, nil
    if target ~= nil then
        tx, ty, tz = posOf(target)
    end
    local gone = target ~= nil and (tx == nil or not promptWorking(target))

    -- Пользователь отключил категорию текущего предмета — отпускаем его без подсчёта
    if target ~= nil and not gone then
        local allowed = (target.kind == "item" and opts.worldItems)
            or (target.kind == "buried" and opts.buried)
            or (target.kind == "seatrash" and opts.seaTrash)
        if not allowed then
            if self.state == "holding" and target.prompt ~= nil and self.deps.holdEnd ~= nil then
                pcall(self.deps.holdEnd, target.prompt)
            end
            self.state = "idle"
            self.target = nil
            self.lastTargetName = ""
            target = nil
        end
    end

    if self.state == "arriving" then
        if gone then
            self.state = "idle"
            self.target = nil
            self.lastTargetName = ""
        elseif target.kind == "seatrash" then
            positionForTrash(self.deps, tx, ty, tz)
            if now - self.since >= stand_out_pickup.settle then
                self.state = "breaking"
                self.since = now
                self.lastRAt = -99
            end
        else
            -- Держим персонажа точно у предмета во время паузы settle
            self.deps.teleportTo(tx, ty + stand_out_pickup.above, tz)
            if now - self.since >= stand_out_pickup.settle then
                local hold = target.prompt.HoldDuration
                if not finite(hold) or hold < 0 then
                    hold = 0
                end
                if hold <= 0.05 and self.deps.firePrompt ~= nil then
                    pcall(self.deps.firePrompt, target.prompt)
                end
                if self.deps.holdBegin ~= nil then
                    pcall(self.deps.holdBegin, target.prompt)
                end
                self.state = "holding"
                self.since = now
            end
        end
    elseif self.state == "breaking" then
        if gone then
            self.taken += 1
            self.state = "idle"
            self.target = nil
            self.lastTargetName = ""
        elseif now - self.since >= stand_out_pickup.trash_give_up then
            self.skipped[target.model] = now
            self.state = "idle"
            self.target = nil
            self.lastTargetName = ""
        else
            positionForTrash(self.deps, tx, ty, tz)
            local needSummon = self.deps.canSummon ~= nil and self.deps.canSummon()
                and self.deps.isSummoned ~= nil and not self.deps.isSummoned()
            if needSummon then
                if now - self.lastSummonAt >= 1.2 and self.deps.pressKey ~= nil then
                    self.lastSummonAt = now
                    pcall(self.deps.pressKey, "E")
                end
            elseif now - self.lastSummonAt >= 0.3 and now - self.lastRAt >= stand_out_pickup.trash_r_cd then
                self.lastRAt = now
                if self.deps.pressKey ~= nil then
                    pcall(self.deps.pressKey, "R")
                end
            end
        end
    elseif self.state == "holding" then
        local hold = target.prompt.HoldDuration
        if not finite(hold) or hold < 0 then
            hold = 0
        end

        if gone then
            if self.deps.holdEnd ~= nil then
                pcall(self.deps.holdEnd, target.prompt)
            end
            self.taken += 1
            self.state = "idle"
            self.target = nil
            self.lastTargetName = ""
        else
            -- Держим у предмета пока идёт HoldDuration (например 1.2s на BuriedSupplies)
            self.deps.teleportTo(tx, ty + stand_out_pickup.above, tz)
            if now - self.since >= hold + stand_out_pickup.extra_hold then
                if self.deps.holdEnd ~= nil then
                    pcall(self.deps.holdEnd, target.prompt)
                end
                if hold > 0.05 and self.deps.firePrompt ~= nil then
                    pcall(self.deps.firePrompt, target.prompt)
                end
                self.state = "waiting"
                self.since = now
            end
        end
    elseif self.state == "waiting" then
        if gone then
            self.taken += 1
            self.state = "idle"
            self.target = nil
            self.lastTargetName = ""
        elseif now - self.since >= stand_out_pickup.give_up then
            self.skipped[target.prompt] = now
            self.state = "idle"
            self.target = nil
            self.lastTargetName = ""
        end
    end

    if self.state ~= "idle" then
        return self.target
    end

    -- Ищем ближайший доступный предмет
    local best, bestDist = nil, math.huge
    local bestX, bestY, bestZ = 0, 0, 0
    if entries ~= nil then
        for _, entry in entries do
            local allowed = (entry.kind == "item" and opts.worldItems)
                or (entry.kind == "buried" and opts.buried)
                or (entry.kind == "seatrash" and opts.seaTrash)
            if not allowed or not promptWorking(entry) then
                continue
            end
            local skipKey = entry.prompt or entry.model
            local skippedAt = self.skipped[skipKey]
            if skippedAt ~= nil and now - skippedAt < stand_out_pickup.skip_for then
                continue
            end
            local ex, ey, ez = posOf(entry)
            if ex == nil then
                continue
            end
            local dx, dy, dz = ex - meX, ey - meY, ez - meZ
            local dist = dx * dx + dy * dy + dz * dz
            if dist < bestDist then
                bestDist = dist
                best = entry
                bestX, bestY, bestZ = ex, ey, ez
            end
        end
    end

    if best == nil then
        -- Все предметы собраны — возвращаемся в исходную точку, если включено
        if self.returnPos ~= nil then
            local rp = self.returnPos
            self.returnPos = nil
            if opts.returnBack then
                self.deps.teleportTo(rp.x, rp.y, rp.z)
            end
        end
        if opts.hopWhenEmpty and (opts.worldItems or opts.buried or opts.seaTrash) then
            if self.emptySince == nil then
                self.emptySince = now
            end
            local waitLeft = stand_out_pickup.hop_delay - (now - self.emptySince)
            if waitLeft > 0 then
                self.lastTargetName = string.format("Пусто -> хоп %dс", math.ceil(waitLeft))
            else
                self.lastTargetName = "Смена сервера..."
                if self.deps.serverHop ~= nil and now - self.lastHopTry >= stand_out_pickup.hop_retry then
                    self.lastHopTry = now
                    pcall(self.deps.serverHop)
                end
            end
        else
            if self.emptySince ~= nil then
                self.emptySince = nil
                self.lastTargetName = ""
            end
        end
        return nil
    end

    self.emptySince = nil
    if self.returnPos == nil then
        self.returnPos = { x = meX, y = meY, z = meZ }
    end

    self.target = best
    self.lastTargetName = best.name or ""
    self.state = "arriving"
    self.since = now
    if best.kind == "seatrash" then
        positionForTrash(self.deps, bestX, bestY, bestZ)
    else
        self.deps.teleportTo(bestX, bestY + stand_out_pickup.above, bestZ)
    end
    return best
end

return stand_out_pickup
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
    local function pickFont(preferred, fallback)
        local f = Enum and Enum.Font
        if f == nil then return nil end
        local ok, val = pcall(function() return f[preferred] end)
        if ok and val ~= nil then return val end
        local okF, valF = pcall(function() return f[fallback] end)
        return okF and valF or nil
    end
    local fontRegular = pickFont("BuilderSansMedium", "GothamMedium") or pickFont("BuilderSans", "Gotham")
    local fontMedium = pickFont("BuilderSansBold", "GothamBold") or fontRegular
    local semiBoldFace, boldFace = nil, nil
    if env.Font ~= nil and Enum ~= nil and Enum.FontWeight ~= nil then
        local okS, fS = pcall(function()
            return env.Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.SemiBold)
        end)
        if okS and fS ~= nil then semiBoldFace = fS end
        local okB, fB = pcall(function()
            return env.Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
        end)
        if okB and fB ~= nil then boldFace = fB end
    end
    local function typography(object, size, medium)
        if object.Name == "__IconFont" then return end
        object.TextScaled = false
        object.TextSize = size
        local face = if medium then (boldFace or semiBoldFace) else semiBoldFace
        if face ~= nil then
            pcall(function() object.FontFace = face end)
            if medium then
                pcall(function() object:SetAttribute("CalciteBoldHeader", true) end)
            end
        else
            object.Font = if medium then fontMedium else fontRegular
        end
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

    local function centerPickers(label)
        if label == nil then return end
        local layout = label:FindFirstChildOfClass("UIListLayout")
        if layout ~= nil and Enum ~= nil and Enum.VerticalAlignment ~= nil then
            layout.VerticalAlignment = Enum.VerticalAlignment.Center
        end
    end

    for _, toggle in Library.Toggles do
        local holder = toggle.Holder
        if not holder then continue end
        local label = caption(holder)
        height(holder,32)
        if label then
            label.TextWrapped = true
            centerPickers(label)
        end
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
                    centerPickers(element.TextLabel)
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

local function pickFont(fontEnum, preferred, fallback)
    if fontEnum == nil then return nil end
    local ok, val = pcall(function() return fontEnum[preferred] end)
    if ok and val ~= nil then return val end
    local okF, valF = pcall(function() return fontEnum[fallback] end)
    return okF and valF or nil
end

local function makeBuilderFace(env, weightName)
    local FontCtor = env and env.Font
    local EnumObj = env and env.Enum
    if FontCtor ~= nil and EnumObj ~= nil and EnumObj.FontWeight ~= nil then
        local ok, face = pcall(function()
            return FontCtor.new("rbxasset://fonts/families/BuilderSans.json", EnumObj.FontWeight[weightName])
        end)
        if ok and face ~= nil then
            return face
        end
    end
    return nil
end

function style.configure(deps)
    local Library, env = deps.Library, deps.env
    local info = {
        Title = "Calcite", Footer = "", NotifySide = "Right", ShowCustomCursor = false,
        CornerRadius = 10, EnableCompacting = false, EnableSidebarResize = false,
        GlobalSearch = true, TabButtonsStyle = { Gap = 5, Padding = 10, CornerRadius = 6, Indicator = false },
    }
    if env and env.UDim2 and env.Enum and env.Enum.Font then
        info.Size = env.UDim2.fromOffset(1040, 740)
        info.Font = pickFont(env.Enum.Font, "BuilderSans", "Gotham")
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
    local uiFont = pickFont(Enum and Enum.Font, "BuilderSansMedium", "GothamMedium") or pickFont(Enum and Enum.Font, "BuilderSans", "Gotham")
    local semiBoldFace = makeBuilderFace(env, "SemiBold")
    local function applySemiBold(obj)
        if obj == nil or obj.Name == "__IconFont" then return end
        if semiBoldFace ~= nil then
            pcall(function() obj.FontFace = semiBoldFace end)
        elseif uiFont ~= nil then
            pcall(function() obj.Font = uiFont end)
        end
    end
    if semiBoldFace ~= nil and Library.Scheme then
        Library.Scheme.Font = semiBoldFace
    end
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
        local lbl = new("TextLabel", {
            BackgroundTransparency = 1, Position = UDim2.fromOffset(x, y), Size = UDim2.new(1, -width, 0, size + 6),
            Font = uiFont, Text = value, TextSize = size, TextTransparency = muted and 0.35 or 0,
            TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 6,
        }, parent, { TextColor3 = "FontColor" })
        applySemiBold(lbl)
        return lbl
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
        if entry.Label then
            entry.Label.TextSize = 18
            applySemiBold(entry.Label)
        end
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
            ClearTextOnFocus = false, Font = uiFont, TextSize = 16, Text = "", ZIndex = bar.ZIndex + 3,
        }, holder, { BackgroundColor3 = "MainColor", TextColor3 = "FontColor" })
        applySemiBold(input)
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
    -- Проходим по всем текстовым элементам окна (включая заголовок, футер, табы, уведомления),
    -- чтобы везде стоял ровный BuilderSans SemiBold без пропущенных Regular-лейблов (не трогая иконки __IconFont)
    if semiBoldFace ~= nil then
        for _, obj in main:GetDescendants() do
            if (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) and obj.Name ~= "__IconFont" then
                if not obj:GetAttribute("CalciteBoldHeader") then
                    pcall(function() obj.FontFace = semiBoldFace end)
                end
            end
        end
    end
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
