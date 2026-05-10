local runService = game:GetService("RunService")
local players    = game:GetService("Players")
local workspace  = game:GetService("Workspace")

local localPlayer  = players.LocalPlayer
local camera       = workspace.CurrentCamera
local viewportSize = camera.ViewportSize

local container = Instance.new("Folder",
	gethui and gethui() or game:GetService("CoreGui")
)
container.Name = "ESP_Container"

local espUpdateHz = 45
local MIN_UPDATE_HZ = 5
local MAX_UPDATE_HZ = 240

local floor  = math.floor
local round  = math.round
local sin    = math.sin
local cos    = math.cos
local clear  = table.clear
local unpack = table.unpack
local find   = table.find
local create = table.create

local fromMatrix          = CFrame.fromMatrix
local wtvp                = camera.WorldToViewportPoint
local isA                 = workspace.IsA
local getPivot            = workspace.GetPivot
local findFirstChild      = workspace.FindFirstChild
local findFirstChildOfClass = workspace.FindFirstChildOfClass
local getChildren         = workspace.GetChildren
local pointToObjectSpace  = CFrame.identity.PointToObjectSpace
local lerpColor           = Color3.new().Lerp

local min2 = Vector2.zero.Min
local max2 = Vector2.zero.Max
local lerp2 = Vector2.zero.Lerp

local min3 = Vector3.zero.Min
local max3 = Vector3.zero.Max

local HEALTH_BAR_OFFSET         = Vector2.new(5, 0)
local HEALTH_TEXT_OFFSET        = Vector2.new(3, 0)
local HEALTH_BAR_OUTLINE_OFFSET = Vector2.new(0, 1)
local NAME_OFFSET               = Vector2.new(0, 2)
local DISTANCE_OFFSET           = Vector2.new(0, 2)

local VERTICES = {
	Vector3.new(-1, -1, -1),
	Vector3.new(-1,  1, -1),
	Vector3.new(-1,  1,  1),
	Vector3.new(-1, -1,  1),
	Vector3.new( 1, -1, -1),
	Vector3.new( 1,  1, -1),
	Vector3.new( 1,  1,  1),
	Vector3.new( 1, -1,  1),
}
local VERTEX_COUNT = #VERTICES

local espObjects      = {}
local chamObjects     = {}
local instanceObjects = {}

local function fastRemove(list, obj)
	for i = 1, #list do
		if list[i] == obj then
			list[i] = list[#list]
			list[#list] = nil
			return
		end
	end
end

camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
	viewportSize = camera.ViewportSize
end)

local function isBodyPart(name: string)
	return name == "Head" or name:find("Torso") or name:find("Leg") or name:find("Arm")
end

local function getBoundingBox(parts)
	local min, max
	for i = 1, #parts do
		local part = parts[i]
		local cframe, size = part.CFrame, part.Size
		min = min3(min or cframe.Position, (cframe - size * 0.5).Position)
		max = max3(max or cframe.Position, (cframe + size * 0.5).Position)
	end
	local center = (min + max) * 0.5
	local front  = Vector3.new(center.X, center.Y, max.Z)
	return CFrame.new(center, front), max - min
end

local function worldToScreen(world: Vector3)
	local screen, inBounds = wtvp(camera, world)
	return Vector2.new(screen.X, screen.Y), inBounds, screen.Z
end

local function calculateCorners(cframe: CFrame, size: Vector3)
	local half    = size * 0.5
	local corners = create(VERTEX_COUNT)
	local minX, minY = viewportSize.X, viewportSize.Y
	local maxX, maxY = 0, 0
	for i = 1, VERTEX_COUNT do
		local worldPos = (cframe + half * VERTICES[i]).Position
		local screen, inBounds = worldToScreen(worldPos)
		corners[i] = screen
		if inBounds then
			local x, y = screen.X, screen.Y
			if x < minX then minX = x end
			if y < minY then minY = y end
			if x > maxX then maxX = x end
			if y > maxY then maxY = y end
		end
	end
	local tlX, tlY = floor(minX), floor(minY)
	local brX, brY = floor(maxX), floor(maxY)
	local topLeft     = Vector2.new(tlX, tlY)
	local bottomRight = Vector2.new(brX, brY)
	return {
		corners     = corners,
		topLeft     = topLeft,
		topRight    = Vector2.new(bottomRight.X, topLeft.Y),
		bottomLeft  = Vector2.new(topLeft.X, bottomRight.Y),
		bottomRight = bottomRight,
	}
end

local function rotateVector(vector: Vector2, radians: number)
	local x, y = vector.X, vector.Y
	local c, s = cos(radians), sin(radians)
	return Vector2.new(x * c - y * s, x * s + y * c)
end

local function solveTwoBoneIK(rootPos: Vector3, targetPos: Vector3, upperLen: number, lowerLen: number, bendDir: Vector3)
	local rootToTarget = targetPos - rootPos
	local dist = rootToTarget.Magnitude
	if dist < 1e-4 then
		local mid = (rootPos + targetPos) * 0.5
		return mid
	end

	local dir = rootToTarget / dist

	dist = math.clamp(dist, math.abs(upperLen - lowerLen) + 1e-4, upperLen + lowerLen - 1e-4)

	local bendProj = bendDir - dir * bendDir:Dot(dir)
	if bendProj.Magnitude < 1e-4 then
		bendProj = Vector3.new(0, 1, 0) - dir * dir:Dot(Vector3.new(0, 1, 0))
		if bendProj.Magnitude < 1e-4 then
			bendProj = dir:Cross(Vector3.new(1, 0, 0))
			if bendProj.Magnitude < 1e-4 then
				bendProj = dir:Cross(Vector3.new(0, 0, 1))
			end
		end
	end
	bendProj = bendProj.Unit

	local z = (dist * dist + upperLen * upperLen - lowerLen * lowerLen) / (2 * dist)
	local x2 = upperLen * upperLen - z * z
	local x = x2 > 0 and math.sqrt(x2) or 0

	local elbowWorld = rootPos + dir * z + bendProj * x
	return elbowWorld
end

local function getR6SkeletonJoints(character)
	local torso = character:FindFirstChild("Torso")
	if not torso then
		return nil
	end

	local head = character:FindFirstChild("Head")
	local lArm = character:FindFirstChild("Left Arm")
	local rArm = character:FindFirstChild("Right Arm")
	local lLeg = character:FindFirstChild("Left Leg")
	local rLeg = character:FindFirstChild("Right Leg")

	local torsoCF   = torso.CFrame
	local torsoSize = torso.Size

	local torsoCenter = torsoCF.Position
	local torsoTop    = torsoCenter + torsoCF.UpVector * (torsoSize.Y * 0.5)
	local torsoBottom = torsoCenter - torsoCF.UpVector * (torsoSize.Y * 0.5)

	local headPos = head and head.Position or nil
	local neckPos = torsoTop

	local shoulderOffsetX = torsoSize.X * 0.5
	local shoulderHeight  = torsoSize.Y * 0.25
	local hipOffsetX      = torsoSize.X * 0.25

	local leftShoulder  = torsoCenter - torsoCF.RightVector * shoulderOffsetX + torsoCF.UpVector * shoulderHeight
	local rightShoulder = torsoCenter + torsoCF.RightVector * shoulderOffsetX + torsoCF.UpVector * shoulderHeight

	local leftHip  = torsoBottom - torsoCF.RightVector * hipOffsetX
    local rightHip = torsoBottom + torsoCF.RightVector * hipOffsetX
    local hipCenter = (leftHip + rightHip) * 0.5
    
    local spineBottom = hipCenter + torsoCF.UpVector * (torsoSize.Y * 0.25)

	local leftClavicle  = leftShoulder
	local rightClavicle = rightShoulder

	local lArmCF, rArmCF, lLegCF, rLegCF
	local lArmLen, rArmLen, lLegLen, rLegLen
	if lArm then
		lArmCF  = lArm.CFrame
		lArmLen = lArm.Size.Y
	end
	if rArm then
		rArmCF  = rArm.CFrame
		rArmLen = rArm.Size.Y
	end
	if lLeg then
		lLegCF  = lLeg.CFrame
		lLegLen = lLeg.Size.Y
	end
	if rLeg then
		rLegCF  = rLeg.CFrame
		rLegLen = rLeg.Size.Y
	end

	local leftHand, rightHand, leftFoot, rightFoot
	if lArmCF and lArmLen then
		leftHand = lArmCF.Position - lArmCF.UpVector * (lArmLen * 0.5)
	end
	if rArmCF and rArmLen then
		rightHand = rArmCF.Position - rArmCF.UpVector * (rArmLen * 0.5)
	end
	if lLegCF and lLegLen then
		leftFoot = lLegCF.Position - lLegCF.UpVector * (lLegLen * 0.5)
	end
	if rLegCF and rLegLen then
		rightFoot = rLegCF.Position - rLegCF.UpVector * (rLegLen * 0.5)
	end

	local bendArms = -torsoCF.LookVector
	local bendLegs =  torsoCF.LookVector

	local function fakeJoint(rootPos, tipPos, strength, bendDir)
		if not (rootPos and tipPos and bendDir) then return nil end
		local mid = (rootPos + tipPos) * 0.5
		return mid + bendDir.Unit * strength
	end

	local leftElbow, rightElbow, leftKnee, rightKnee
	if leftShoulder and leftHand and lArmLen then
		leftElbow = fakeJoint(leftShoulder, leftHand, lArmLen * 0.10, bendArms)
	end
	if rightShoulder and rightHand and rArmLen then
		rightElbow = fakeJoint(rightShoulder, rightHand, rArmLen * 0.10, bendArms)
	end
	if leftHip and leftFoot and lLegLen then
		leftKnee = fakeJoint(leftHip, leftFoot, lLegLen * 0.08, bendLegs)
	end
	if rightHip and rightFoot and rLegLen then
		rightKnee = fakeJoint(rightHip, rightFoot, rLegLen * 0.08, bendLegs)
	end

  

    return {
        head        = headPos,
        neck        = neckPos,
        spineBottom = spineBottom,

        leftClavicle  = leftClavicle,
        rightClavicle = rightClavicle,

        leftShoulder  = leftShoulder,
        leftElbow     = leftElbow,
        leftHand      = leftHand,

        rightShoulder = rightShoulder,
        rightElbow    = rightElbow,
        rightHand     = rightHand,

        hipCenter = hipCenter,

        leftHip   = leftHip,
        leftKnee  = leftKnee,
        leftFoot  = leftFoot,

        rightHip  = rightHip,
        rightKnee = rightKnee,
        rightFoot = rightFoot,
    }
end





local function parseColor(self, color, isOutline)
	if color == "Team Color" or (self.interface.sharedSettings.useTeamColor and not isOutline) then
		return self.interface.getTeamColor(self.player) or Color3.new(1, 1, 1)
	end
	return color
end

local EspObject = {}
EspObject.__index = EspObject

function EspObject.new(player, interface)
	local self = setmetatable({}, EspObject)
	self.player    = assert(player)
	self.interface = assert(interface)
	self:Construct()
	return self
end

function EspObject:_create(class, properties)
	local drawing = Drawing.new(class)
	for property, value in next, properties do
		pcall(function()
			drawing[property] = value
		end)
	end
	self.bin[#self.bin + 1] = drawing
	return drawing
end

function EspObject:Construct()
	self.charCache  = {}
	self.childCount = 0
	self.bin        = {}
	self.drawings = {
		box3d = {
			{
				self:_create("Line", { Thickness = 1, Visible = false }),
				self:_create("Line", { Thickness = 1, Visible = false }),
				self:_create("Line", { Thickness = 1, Visible = false }),
			},
			{
				self:_create("Line", { Thickness = 1, Visible = false }),
				self:_create("Line", { Thickness = 1, Visible = false }),
				self:_create("Line", { Thickness = 1, Visible = false }),
			},
			{
				self:_create("Line", { Thickness = 1, Visible = false }),
				self:_create("Line", { Thickness = 1, Visible = false }),
				self:_create("Line", { Thickness = 1, Visible = false }),
			},
			{
				self:_create("Line", { Thickness = 1, Visible = false }),
				self:_create("Line", { Thickness = 1, Visible = false }),
				self:_create("Line", { Thickness = 1, Visible = false }),
			},
		},
		visible = {
			tracerOutline    = self:_create("Line",   { Thickness = 3, Visible = false }),
			tracer           = self:_create("Line",   { Thickness = 1, Visible = false }),
			boxFill          = self:_create("Square", { Filled = true, Visible = false }),
			boxOutline       = self:_create("Square", { Thickness = 3, Visible = false }),
			box              = self:_create("Square", { Thickness = 1, Visible = false }),
			healthBarOutline = self:_create("Line",   { Thickness = 3, Visible = false }),
			healthBar        = self:_create("Line",   { Thickness = 1, Visible = false }),
			healthText       = self:_create("Text",   { Center = true, Visible = false }),
			name             = self:_create("Text",   { Text = self.player.DisplayName, Center = true, Visible = false }),
			distance         = self:_create("Text",   { Center = true, Visible = false }),
			weapon           = self:_create("Text",   { Center = true, Visible = false }),
		},
		hidden = {
			arrowOutline = self:_create("Triangle", { Thickness = 3, Visible = false }),
			arrow        = self:_create("Triangle", { Filled = true, Visible = false }),
		},
        skeleton = {
            spine         = self:_create("Line", { Thickness = 1, Visible = false }),
            neck          = self:_create("Line", { Thickness = 1, Visible = false }),
        
            leftClavicle  = self:_create("Line", { Thickness = 1, Visible = false }),
            rightClavicle = self:_create("Line", { Thickness = 1, Visible = false }),
        
            hipLeft       = self:_create("Line", { Thickness = 1, Visible = false }),
            hipRight      = self:_create("Line", { Thickness = 1, Visible = false }),
        
            leftUpperArm  = self:_create("Line", { Thickness = 1, Visible = false }),
            leftLowerArm  = self:_create("Line", { Thickness = 1, Visible = false }),
            rightUpperArm = self:_create("Line", { Thickness = 1, Visible = false }),
            rightLowerArm = self:_create("Line", { Thickness = 1, Visible = false }),
        
            leftUpperLeg  = self:_create("Line", { Thickness = 1, Visible = false }),
            leftLowerLeg  = self:_create("Line", { Thickness = 1, Visible = false }),
            rightUpperLeg = self:_create("Line", { Thickness = 1, Visible = false }),
            rightLowerLeg = self:_create("Line", { Thickness = 1, Visible = false }),
        }
        

	}
	espObjects[#espObjects + 1] = self
end

function EspObject:Destruct()
	fastRemove(espObjects, self)
	for i = 1, #self.bin do
		self.bin[i]:Remove()
	end
	clear(self)
end

function EspObject:Update(dt)
	local interface = self.interface
	local options = interface.teamSettings[interface.isFriendly(self.player) and "friendly" or "enemy"]
	self.options = options

	local hasOnScreenVisuals =
		options.box
		or options.boxOutline
		or options.boxFill
		or options.healthBar
		or options.healthText
		or options.name
		or options.distance
		or options.weapon
		or options.tracer
		or options.box3d
		or options.skeleton

	local hasOffscreenArrow =
		options.offScreenArrow
		or options.offScreenArrowOutline

	self.hasOnScreenVisuals = hasOnScreenVisuals
	self.hasOffscreenArrow  = hasOffscreenArrow

	if not (options.enabled and (hasOnScreenVisuals or hasOffscreenArrow)) then
		self.enabled        = false
		self.onScreen       = false
		self.corners        = nil
		self.direction      = nil
		self.charCache      = {}
		self.skeletonJoints = nil
		return
	end

	local character = interface.getCharacter(self.player)
	self.character = character
	if not character then
		self.enabled        = false
		self.onScreen       = false
		self.corners        = nil
		self.direction      = nil
		self.charCache      = {}
		self.skeletonJoints = nil
		return
	end

	if options.healthBar or options.healthText then
		self.health, self.maxHealth = interface.getHealth(self.player)
	else
		self.health, self.maxHealth = nil, nil
	end

	if options.weapon then
		self.weapon = interface.getWeapon(self.player)
	else
		self.weapon = nil
	end

	local wl = interface.whitelist
	if #wl > 0 and not find(wl, self.player.UserId) then
		self.enabled        = false
		self.onScreen       = false
		self.corners        = nil
		self.direction      = nil
		self.charCache      = {}
		self.skeletonJoints = nil
		return
	end

	self.enabled = true

	local head = findFirstChild(character, "Head")
	if not head then
		self.onScreen       = false
		self.corners        = nil
		self.direction      = nil
		self.charCache      = {}
		self.skeletonJoints = nil
		return
	end

	local _, onScreen, depth = worldToScreen(head.Position)
	self.onScreen = onScreen
	self.distance = depth

	local shared = interface.sharedSettings
	if shared.limitDistance and depth > shared.maxDistance then
		self.onScreen = false
	end

	if self.onScreen and hasOnScreenVisuals then
		local cache    = self.charCache
		local children = getChildren(character)
		if not cache[1] or self.childCount ~= #children then
			clear(cache)
			for i = 1, #children do
				local part = children[i]
				if isA(part, "BasePart") and isBodyPart(part.Name) then
					cache[#cache + 1] = part
				end
			end
			self.childCount = #children
		end

		if #cache > 0 then
			self.corners = calculateCorners(getBoundingBox(cache))
		else
			self.corners = nil
		end

		if self.options.skeleton then
			self.skeletonJoints = getR6SkeletonJoints(character)
		else
			self.skeletonJoints = nil
		end

		self.direction = nil

	elseif (not self.onScreen) and hasOffscreenArrow then
		self.corners        = nil
		self.skeletonJoints = nil
		local cframe = camera.CFrame
		local flat   = fromMatrix(cframe.Position, cframe.RightVector, Vector3.yAxis)
		local objectSpace = pointToObjectSpace(flat, head.Position)
		local dir = Vector2.new(objectSpace.X, objectSpace.Z)
		if dir.Magnitude > 0 then
			self.direction = dir.Unit
		else
			self.direction = nil
		end
	else
		self.corners        = nil
		self.direction      = nil
		self.charCache      = {}
		self.skeletonJoints = nil
	end
end

function EspObject:Render(dt)
	local interface = self.interface
	local options   = self.options or interface.teamSettings.enemy
	local enabled   = self.enabled or false
	local onScreen  = self.onScreen or false
	local visible   = self.drawings.visible
	local hidden    = self.drawings.hidden
	local box3d     = self.drawings.box3d
	local skeleton  = self.drawings.skeleton
	local corners   = self.corners
	local hasOnScreenVisuals = self.hasOnScreenVisuals
	local hasOffscreenArrow  = self.hasOffscreenArrow

	if not (enabled and (hasOnScreenVisuals or hasOffscreenArrow)) then
		visible.box.Visible           = false
		visible.boxOutline.Visible    = false
		visible.boxFill.Visible       = false
		visible.healthBar.Visible     = false
		visible.healthBarOutline.Visible = false
		visible.healthText.Visible    = false
		visible.name.Visible          = false
		visible.distance.Visible      = false
		visible.weapon.Visible        = false
		visible.tracer.Visible        = false
		visible.tracerOutline.Visible = false
		hidden.arrow.Visible          = false
		hidden.arrowOutline.Visible   = false
		for i = 1, #box3d do
			local face = box3d[i]
			face[1].Visible = false
			face[2].Visible = false
			face[3].Visible = false
		end
		if skeleton then
			for _, line in pairs(skeleton) do
				line.Visible = false
			end
		end
		return
	end

	if not (enabled and onScreen and corners and hasOnScreenVisuals) then
		visible.box.Visible           = false
		visible.boxOutline.Visible    = false
		visible.boxFill.Visible       = false
		visible.healthBar.Visible     = false
		visible.healthBarOutline.Visible = false
		visible.healthText.Visible    = false
		visible.name.Visible          = false
		visible.distance.Visible      = false
		visible.weapon.Visible        = false
		visible.tracer.Visible        = false
		visible.tracerOutline.Visible = false
		if skeleton then
			for _, line in pairs(skeleton) do
				line.Visible = false
			end
		end
	end

	local shared = interface.sharedSettings
	local topLeft, topRight, bottomLeft, bottomRight
	if corners then
		topLeft     = corners.topLeft
		topRight    = corners.topRight
		bottomLeft  = corners.bottomLeft
		bottomRight = corners.bottomRight
	end

	local boxColor, boxColorAlpha, boxOutlineColor, boxOutlineAlpha
	local boxFillColor, boxFillAlpha
	local healthRatio = 0

	if options.box or options.boxOutline or options.boxFill or options.box3d then
		if options.boxColor then
			boxColor      = parseColor(self, options.boxColor[1])
			boxColorAlpha = options.boxColor[2]
		end
		if options.boxOutlineColor then
			boxOutlineColor = parseColor(self, options.boxOutlineColor[1], true)
			boxOutlineAlpha = options.boxOutlineColor[2]
		end
		if options.boxFillColor then
			boxFillColor  = parseColor(self, options.boxFillColor[1])
			boxFillAlpha  = options.boxFillColor[2]
		end
	end

	if (options.healthBar or options.healthText) and self.maxHealth and self.maxHealth > 0 then
		healthRatio = self.health / self.maxHealth
	end

	visible.box.Visible = enabled and onScreen and options.box and corners ~= nil
	visible.boxOutline.Visible = visible.box.Visible and options.boxOutline
	if visible.box.Visible then
		local box = visible.box
		box.Position     = topLeft
		box.Size         = bottomRight - topLeft
		box.Color        = boxColor
		box.Transparency = boxColorAlpha
		local boxOutline = visible.boxOutline
		boxOutline.Position     = box.Position
		boxOutline.Size         = box.Size
		boxOutline.Color        = boxOutlineColor
		boxOutline.Transparency = boxOutlineAlpha
	end

	visible.boxFill.Visible = enabled and onScreen and options.boxFill and corners ~= nil
	if visible.boxFill.Visible then
		local boxFill = visible.boxFill
		boxFill.Position     = topLeft
		boxFill.Size         = bottomRight - topLeft
		boxFill.Color        = boxFillColor
		boxFill.Transparency = boxFillAlpha
	end

	visible.healthBar.Visible        = enabled and onScreen and options.healthBar and corners ~= nil
	visible.healthBarOutline.Visible = visible.healthBar.Visible and options.healthBarOutline
	if visible.healthBar.Visible then
		local barFrom = topLeft - HEALTH_BAR_OFFSET
		local barTo   = bottomLeft - HEALTH_BAR_OFFSET
		local healthBar = visible.healthBar
		healthBar.To   = barTo
		healthBar.From = lerp2(barTo, barFrom, healthRatio)
		healthBar.Color = lerpColor(options.dyingColor, options.healthyColor, healthRatio)
		local healthBarOutline = visible.healthBarOutline
		healthBarOutline.To   = barTo + HEALTH_BAR_OUTLINE_OFFSET
		healthBarOutline.From = barFrom - HEALTH_BAR_OUTLINE_OFFSET
		healthBarOutline.Color        = parseColor(self, options.healthBarOutlineColor[1], true)
		healthBarOutline.Transparency = options.healthBarOutlineColor[2]
	end

	visible.healthText.Visible = enabled and onScreen and options.healthText and corners ~= nil
	if visible.healthText.Visible then
		local barFrom = topLeft - HEALTH_BAR_OFFSET
		local barTo   = bottomLeft - HEALTH_BAR_OFFSET
		local healthText = visible.healthText
		healthText.Text          = round(self.health) .. "hp"
		healthText.Size          = shared.textSize
		healthText.Font          = shared.textFont
		healthText.Color         = parseColor(self, options.healthTextColor[1])
		healthText.Transparency  = options.healthTextColor[2]
		healthText.Outline       = options.healthTextOutline
		healthText.OutlineColor  = parseColor(self, options.healthTextOutlineColor, true)
		healthText.Position      = lerp2(barTo, barFrom, healthRatio) - healthText.TextBounds * 0.5 - HEALTH_TEXT_OFFSET
	end

	visible.name.Visible = enabled and onScreen and options.name and corners ~= nil
	if visible.name.Visible then
		local name = visible.name
		name.Size          = shared.textSize
		name.Font          = shared.textFont
		name.Color         = parseColor(self, options.nameColor[1])
		name.Transparency  = options.nameColor[2]
		name.Outline       = options.nameOutline
		name.OutlineColor  = parseColor(self, options.nameOutlineColor, true)
		name.Position      = (topLeft + topRight) * 0.5 - Vector2.yAxis * name.TextBounds.Y - NAME_OFFSET
	end

	visible.distance.Visible = enabled and onScreen and self.distance and options.distance and corners ~= nil
	if visible.distance.Visible then
		local distance = visible.distance
		distance.Text          = round(self.distance) .. " studs"
		distance.Size          = shared.textSize
		distance.Font          = shared.textFont
		distance.Color         = parseColor(self, options.distanceColor[1])
		distance.Transparency  = options.distanceColor[2]
		distance.Outline       = options.distanceOutline
		distance.OutlineColor  = parseColor(self, options.distanceOutlineColor, true)
		distance.Position      = (bottomLeft + bottomRight) * 0.5 + DISTANCE_OFFSET
	end

	visible.weapon.Visible = enabled and onScreen and options.weapon and corners ~= nil and self.weapon ~= nil
	if visible.weapon.Visible then
		local weapon = visible.weapon
		weapon.Text          = self.weapon
		weapon.Size          = shared.textSize
		weapon.Font          = shared.textFont
		weapon.Color         = parseColor(self, options.weaponColor[1])
		weapon.Transparency  = options.weaponColor[2]
		weapon.Outline       = options.weaponOutline
		weapon.OutlineColor  = parseColor(self, options.weaponOutlineColor, true)
		local yOffset = Vector2.zero
		if visible.distance.Visible then
			yOffset = DISTANCE_OFFSET + Vector2.yAxis * visible.distance.TextBounds.Y
		end
		weapon.Position = (bottomLeft + bottomRight) * 0.5 + yOffset
	end

	visible.tracer.Visible        = enabled and onScreen and options.tracer and corners ~= nil
	visible.tracerOutline.Visible = visible.tracer.Visible and options.tracerOutline
	if visible.tracer.Visible then
		local tracer = visible.tracer
		tracer.Color        = parseColor(self, options.tracerColor[1])
		tracer.Transparency = options.tracerColor[2]
		tracer.To           = (bottomLeft + bottomRight) * 0.5
		tracer.From =
			options.tracerOrigin == "Middle" and viewportSize * 0.5 or
			options.tracerOrigin == "Top"    and viewportSize * Vector2.new(0.5, 0) or
			viewportSize * Vector2.new(0.5, 1)
		local tracerOutline = visible.tracerOutline
		tracerOutline.Color        = parseColor(self, options.tracerOutlineColor[1], true)
		tracerOutline.Transparency = options.tracerOutlineColor[2]
		tracerOutline.To           = tracer.To
		tracerOutline.From         = tracer.From
	end

	hidden.arrow.Visible        = enabled and (not onScreen) and hasOffscreenArrow and options.offScreenArrow and self.direction ~= nil
	hidden.arrowOutline.Visible = hidden.arrow.Visible and options.offScreenArrowOutline
	if hidden.arrow.Visible and self.direction then
        local arrow = hidden.arrow
        local dir   = self.direction
        local rawPos = viewportSize * 0.5 + dir * options.offScreenArrowRadius
        local clamped = min2(max2(rawPos, Vector2.one * 25), viewportSize - Vector2.one * 25)
    
        arrow.PointA = clamped
        arrow.PointB = clamped - rotateVector(dir,  0.45) * options.offScreenArrowSize
        arrow.PointC = clamped - rotateVector(dir, -0.45) * options.offScreenArrowSize
    
        arrow.Color = parseColor(self, options.offScreenArrowColor[1])
    
        local arrowOutline = hidden.arrowOutline
        arrowOutline.PointA = arrow.PointA
        arrowOutline.PointB = arrow.PointB
        arrowOutline.PointC = arrow.PointC
        arrowOutline.Color  = parseColor(self, options.offScreenArrowOutlineColor[1], true)
    
        local dist    = self.distance or 0
        local shared  = interface.sharedSettings
        local maxDist = shared.maxDistance or 300  
        if maxDist <= 0 then maxDist = 300 end

        local strength = 1 - math.clamp(dist / maxDist, 0, 1)
    
        local minMul = 0.25
        local mul = minMul + (1 - minMul) * strength
    
        local baseArrowAlpha   = options.offScreenArrowColor[2] or 1
        local baseOutlineAlpha = options.offScreenArrowOutlineColor[2] or 1
    
        arrow.Transparency        = baseArrowAlpha   * mul
        arrowOutline.Transparency = baseOutlineAlpha * mul
    end
    
    

	local box3dEnabled = enabled and onScreen and options.box3d and corners ~= nil
	local box3dColor, box3dAlpha
	if options.box3d and options.box3dColor then
		box3dColor = parseColor(self, options.box3dColor[1])
		box3dAlpha = options.box3dColor[2]
	end

	local c = corners and corners.corners or nil
	for i = 1, #box3d do
		local face = box3d[i]
		local l1, l2, l3 = face[1], face[2], face[3]
		l1.Visible = box3dEnabled
		l2.Visible = box3dEnabled
		l3.Visible = box3dEnabled
		if box3dEnabled and c then
			l1.Color        = box3dColor
			l2.Color        = box3dColor
			l3.Color        = box3dColor
			l1.Transparency = box3dAlpha
			l2.Transparency = box3dAlpha
			l3.Transparency = box3dAlpha
			local i1 = i
			local i2 = (i == 4) and 1 or (i + 1)
			local i3 = (i == 4) and 5 or (i + 5)
			local i4 = (i == 4) and 8 or (i + 4)
			l1.From = c[i1]
			l1.To   = c[i2]
			l2.From = c[i2]
			l2.To   = c[i3]
			l3.From = c[i3]
			l3.To   = c[i4]
		end
	end

	if skeleton and enabled and onScreen and options.skeleton and self.skeletonJoints then
		local j = self.skeletonJoints
		local color = parseColor(self, options.skeletonColor[1])
		local alpha = options.skeletonColor[2]

		local function drawBone(line, a: Vector3, b: Vector3)
			if not a or not b then
				line.Visible = false
				return
			end
			local sa, visA = worldToScreen(a)
			local sb, visB = worldToScreen(b)
			local vis = visA and visB
			line.Visible = vis
			if vis then
				line.From        = sa
				line.To          = sb
				line.Color       = color
				line.Transparency = alpha
			end
		end

        drawBone(skeleton.spine, j.spineBottom, j.neck)
        drawBone(skeleton.neck,  j.neck,        j.head)
        
        drawBone(skeleton.leftClavicle,  j.neck,        j.leftShoulder)
        drawBone(skeleton.rightClavicle, j.neck,        j.rightShoulder)
        
        drawBone(skeleton.hipLeft,  j.spineBottom, j.leftHip)
        drawBone(skeleton.hipRight, j.spineBottom, j.rightHip)
        
        drawBone(skeleton.leftUpperLeg,  j.leftHip,      j.leftKnee)
        drawBone(skeleton.leftLowerLeg,  j.leftKnee,     j.leftFoot)
        drawBone(skeleton.rightUpperLeg, j.rightHip,     j.rightKnee)
        drawBone(skeleton.rightLowerLeg, j.rightKnee,    j.rightFoot)
        
        drawBone(skeleton.leftUpperArm,  j.leftShoulder,  j.leftElbow)
        drawBone(skeleton.leftLowerArm,  j.leftElbow,     j.leftHand)
        drawBone(skeleton.rightUpperArm, j.rightShoulder, j.rightElbow)
        drawBone(skeleton.rightLowerArm, j.rightElbow,    j.rightHand)
    
        


	elseif skeleton then
		for _, line in pairs(skeleton) do
			line.Visible = false
		end
	end
end

local ChamObject = {}
ChamObject.__index = ChamObject

function ChamObject.new(player, interface)
	local self = setmetatable({}, ChamObject)
	self.player    = assert(player)
	self.interface = assert(interface)
	self:Construct()
	return self
end

function ChamObject:Construct()
	self.highlight = Instance.new("Highlight", container)
	chamObjects[#chamObjects + 1] = self
end

function ChamObject:Destruct()
	fastRemove(chamObjects, self)
	self.highlight:Destroy()
	clear(self)
end

function ChamObject:Update(dt)
	local highlight = self.highlight
	local interface = self.interface
	local options = interface.teamSettings[interface.isFriendly(self.player) and "friendly" or "enemy"]
	if not options.enabled then
		highlight.Enabled = false
		return
	end
	local character = interface.getCharacter(self.player)
	local wl        = interface.whitelist
	local enabled = options.enabled and character and not
	(#wl > 0 and not find(wl, self.player.UserId))
	highlight.Enabled = enabled and options.chams
	if highlight.Enabled then
		highlight.Adornee      = character
		highlight.FillColor    = parseColor(self, options.chamsFillColor[1])
		highlight.FillTransparency = options.chamsFillColor[2]
		highlight.OutlineColor = parseColor(self, options.chamsOutlineColor[1], true)
		highlight.OutlineTransparency = options.chamsOutlineColor[2]
		highlight.DepthMode    = options.chamsVisibleOnly and "Occluded" or "AlwaysOnTop"
	end
end

local InstanceObject = {}
InstanceObject.__index = InstanceObject

function InstanceObject.new(instance, options)
	local self = setmetatable({}, InstanceObject)
	self.instance = assert(instance)
	self.options  = assert(options)
	self:Construct()
	return self
end

function InstanceObject:Construct()
	local options = self.options
	options.enabled          = options.enabled == nil and true or options.enabled
	options.text             = options.text or "{name}"
	options.textColor        = options.textColor or { Color3.new(1, 1, 1), 1 }
	options.textOutline      = options.textOutline == nil and true or options.textOutline
	options.textOutlineColor = options.textOutlineColor or Color3.new()
	options.textSize         = options.textSize or 13
	options.textFont         = options.textFont or 2
	options.limitDistance    = options.limitDistance or false
	options.maxDistance      = options.maxDistance or 150
	local text = Drawing.new("Text")
	text.Center = true
	self.text   = text
	instanceObjects[#instanceObjects + 1] = self
end

function InstanceObject:Destruct()
	fastRemove(instanceObjects, self)
	self.text:Remove()
	clear(self)
end

function InstanceObject:Render(dt)
	local instance = self.instance
	if not instance or not instance.Parent then
		return self:Destruct()
	end

	local text    = self.text
	local options = self.options
	if not options.enabled then
		text.Visible = false
		return
	end

	local world = getPivot(instance).Position
	local position, visible, depth = worldToScreen(world)
	if options.limitDistance and depth > options.maxDistance then
		visible = false
	end

	text.Visible = visible
	if text.Visible then
		text.Position      = position
		text.Color         = options.textColor[1]
		text.Transparency  = options.textColor[2]
		text.Outline       = options.textOutline
		text.OutlineColor  = options.textOutlineColor
		text.Size          = options.textSize
		text.Font          = options.textFont
		text.Text = options.text
			:gsub("{name}", instance.Name)
			:gsub("{distance}", round(depth))
			:gsub("{position}", tostring(world))
	end
end

local accumulator = 0

runService.Heartbeat:Connect(function(dt)
	accumulator += dt
	local targetInterval = 1 / espUpdateHz
	if accumulator < targetInterval then
		return
	end
	accumulator = 0
	for i = 1, #espObjects do
		local obj = espObjects[i]
		obj:Update(targetInterval)
		obj:Render(targetInterval)
	end
	for i = 1, #chamObjects do
		chamObjects[i]:Update(targetInterval)
	end
	for i = 1, #instanceObjects do
		instanceObjects[i]:Render(targetInterval)
	end
end)

local EspInterface = {
	_hasLoaded   = false,
	_objectCache = {},
	whitelist = {},
	sharedSettings = {
		textSize      = 13,
		textFont      = 2,
		limitDistance = false,
		maxDistance   = 150,
		useTeamColor  = false,
	},
	teamSettings = {
		enemy = {
			enabled = false,
			box = false,
			boxColor = { Color3.new(1, 0, 0), 1 },
			boxOutline = true,
			boxOutlineColor = { Color3.new(), 1 },
			boxFill = false,
			boxFillColor = { Color3.new(1, 0, 0), 0.5 },
			healthBar = false,
			healthyColor = Color3.new(0, 1, 0),
			dyingColor   = Color3.new(1, 0, 0),
			healthBarOutline      = true,
			healthBarOutlineColor = { Color3.new(), 0.5 },
			healthText          = false,
			healthTextColor     = { Color3.new(1, 1, 1), 1 },
			healthTextOutline   = true,
			healthTextOutlineColor = Color3.new(),
			box3d     = false,
			box3dColor = { Color3.new(1, 0, 0), 1 },
			skeleton      = false,
			skeletonColor = { Color3.new(1, 1, 1), 1 },
			name          = false,
			nameColor     = { Color3.new(1, 1, 1), 1 },
			nameOutline   = true,
			nameOutlineColor = Color3.new(),
			weapon          = false,
			weaponColor     = { Color3.new(1, 1, 1), 1 },
			weaponOutline   = true,
			weaponOutlineColor = Color3.new(),
			distance          = false,
			distanceColor     = { Color3.new(1, 1, 1), 1 },
			distanceOutline   = true,
			distanceOutlineColor = Color3.new(),
			tracer        = false,
			tracerOrigin  = "Bottom",
			tracerColor   = { Color3.new(1, 0, 0), 1 },
			tracerOutline = true,
			tracerOutlineColor = { Color3.new(), 1 },
			offScreenArrow          = false,
            offScreenArrowColor     = { Color3.new(1, 1, 1), 0.6 }, -- was 1
            offScreenArrowSize      = 15,
            offScreenArrowRadius    = 150,
            offScreenArrowOutline   = true,
            offScreenArrowOutlineColor = { Color3.new(), 0.4 },    -- was 1
			chams            = false,
			chamsVisibleOnly = false,
			chamsFillColor   = { Color3.new(0.2, 0.2, 0.2), 0.5 },
			chamsOutlineColor = { Color3.new(1, 0, 0), 0 },
		},
		friendly = {
			enabled = false,
			box = false,
			boxColor = { Color3.new(0, 1, 0), 1 },
			boxOutline = true,
			boxOutlineColor = { Color3.new(), 1 },
			boxFill = false,
			boxFillColor = { Color3.new(0, 1, 0), 0.5 },
			healthBar = false,
			healthyColor = Color3.new(0, 1, 0),
			dyingColor   = Color3.new(1, 0, 0),
			healthBarOutline      = true,
			healthBarOutlineColor = { Color3.new(), 0.5 },
			healthText          = false,
			healthTextColor     = { Color3.new(1, 1, 1), 1 },
			healthTextOutline   = true,
			healthTextOutlineColor = Color3.new(),
			box3d     = false,
			box3dColor = { Color3.new(0, 1, 0), 1 },
			skeleton      = false,
			skeletonColor = { Color3.new(1, 1, 1), 1 },
			name          = false,
			nameColor     = { Color3.new(1, 1, 1), 1 },
			nameOutline   = true,
			nameOutlineColor = Color3.new(),
			weapon          = false,
			weaponColor     = { Color3.new(1, 1, 1), 1 },
			weaponOutline   = true,
			weaponOutlineColor = Color3.new(),
			distance          = false,
			distanceColor     = { Color3.new(1, 1, 1), 1 },
			distanceOutline   = true,
			distanceOutlineColor = Color3.new(),
			tracer        = false,
			tracerOrigin  = "Bottom",
			tracerColor   = { Color3.new(0, 1, 0), 1 },
			tracerOutline = true,
			tracerOutlineColor = { Color3.new(), 1 },
		    offScreenArrow          = false,
            offScreenArrowColor     = { Color3.new(1, 1, 1), 0.6 }, -- was 1
            offScreenArrowSize      = 15,
            offScreenArrowRadius    = 150,
            offScreenArrowOutline   = true,
            offScreenArrowOutlineColor = { Color3.new(), 0.4 },    -- was 1
			chams            = false,
			chamsVisibleOnly = false,
			chamsFillColor   = { Color3.new(0.2, 0.2, 0.2), 0.5 },
			chamsOutlineColor = { Color3.new(0, 1, 0), 0 },
		},
	},
}

function EspInterface.AddInstance(instance, options)
	local cache = EspInterface._objectCache
	if cache[instance] then
		warn("Instance handler already exists.")
	else
		local obj = InstanceObject.new(instance, options)
		cache[instance] = { obj }
	end
	return cache[instance][1]
end

function EspInterface.Load()
	assert(not EspInterface._hasLoaded)
	local function createObject(player)
		EspInterface._objectCache[player] = {
			EspObject.new(player, EspInterface),
			ChamObject.new(player, EspInterface),
		}
	end
	local function removeObject(player)
		local object = EspInterface._objectCache[player]
		if object then
			for i = 1, #object do
				object[i]:Destruct()
			end
			EspInterface._objectCache[player] = nil
		end
	end
	local plrs = players:GetPlayers()
	for i = 1, #plrs do
		local plr = plrs[i]
		if plr ~= localPlayer then
			createObject(plr)
		end
	end
	EspInterface.playerAdded   = players.PlayerAdded:Connect(createObject)
	EspInterface.playerRemoving = players.PlayerRemoving:Connect(removeObject)
	EspInterface._hasLoaded    = true
end

function EspInterface.Unload()
	assert(EspInterface._hasLoaded)
	for index, object in next, EspInterface._objectCache do
		for i = 1, #object do
			object[i]:Destruct()
		end
		EspInterface._objectCache[index] = nil
	end
	if EspInterface.playerAdded then
		EspInterface.playerAdded:Disconnect()
		EspInterface.playerAdded = nil
	end
	if EspInterface.playerRemoving then
		EspInterface.playerRemoving:Disconnect()
		EspInterface.playerRemoving = nil
	end
	EspInterface._hasLoaded = false
end

function EspInterface.SetUpdateRateHz(hz)
	hz = tonumber(hz)
	if not hz then return end
	if hz < MIN_UPDATE_HZ then
		hz = MIN_UPDATE_HZ
	elseif hz > MAX_UPDATE_HZ then
		hz = MAX_UPDATE_HZ
	end
	espUpdateHz = hz
end

function EspInterface.getWeapon(player)
	return "Unknown"
end

function EspInterface.isFriendly(player)
	return player.Team and player.Team == localPlayer.Team
end

function EspInterface.getTeamColor(player)
	return player.Team and player.Team.TeamColor and player.Team.TeamColor.Color
end

function EspInterface.getCharacter(player)
	return player.Character
end

function EspInterface.getHealth(player)
	local character = player and EspInterface.getCharacter(player)
	local humanoid = character and findFirstChildOfClass(character, "Humanoid")
	if humanoid then
		return humanoid.Health, humanoid.MaxHealth
	end
	return 100, 100
end

return EspInterface
