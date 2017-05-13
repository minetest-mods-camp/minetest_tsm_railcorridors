tsm_railcorridors = {}

-- Load node names
dofile(minetest.get_modpath(minetest.get_current_modname()).."/gameconfig.lua")

-- Settings
local setting

-- Probability function
-- TODO: Check if this is correct
local P = function (float)
	return math.floor(32767 * float)
end

-- Wahrscheinlichkeit für jeden Chunk, solche Gänge mit Schienen zu bekommen
-- Probability for every newly generated chunk to get corridors
local probability_railcaves_in_chunk = P(1/3)
setting = tonumber(minetest.setting_get("tsm_railcorridors_probability_railcaves_in_chunk"))
if setting then
	probability_railcaves_in_chunk = P(setting)
end

-- Innerhalb welcher Parameter soll sich die Pfadlänge bewegen? (Forks heben den Maximalwert auf)
-- Minimal and maximal value of path length (forks don't look up this value)
local way_min = 4;
local way_max = 7;
setting = tonumber(minetest.setting_get("tsm_railcorridors_way_min"))
if setting then
	way_min = setting
end
setting = tonumber(minetest.setting_get("tsm_railcorridors_way_max"))
if setting then
	way_max = setting
end

-- Wahrsch. für jeden geraden Teil eines Korridors, Fackeln zu bekommen
-- Probability for every horizontal part of a corridor to be with torches
local probability_torches_in_segment = P(0.5)
setting = tonumber(minetest.setting_get("tsm_railcorridors_probability_torches_in_segment"))
if setting then
	probability_torches_in_segment = P(setting)
end

-- Wahrsch. für jeden Teil eines Korridors, nach oben oder nach unten zu gehen
-- Probability for every part of a corridor to go up or down
local probability_up_or_down = P(0.2)
setting = tonumber(minetest.setting_get("tsm_railcorridors_probability_up_or_down"))
if setting then
	probability_up_or_down = P(setting)
end

-- Wahrscheinlichkeit für jeden Teil eines Korridors, sich zu verzweigen – vorsicht, wenn fast jeder Gang sich verzweigt, kann der Algorithums unlösbar werden und MT hängt sich auf
-- Probability for every part of a corridor to fork – caution, too high values may cause MT to hang on.
local probability_fork = P(0.04)
setting = tonumber(minetest.setting_get("tsm_railcorridors_probability_fork"))
if setting then
	probability_fork = P(setting)
end

-- Wahrscheinlichkeit für jeden geraden Teil eines Korridors eine Kiste zu enthalten
-- Probability for every part of a corridor to contain a chest
local probability_chest = P(0.05)
setting = tonumber(minetest.setting_get("tsm_railcorridors_probability_chest"))
if setting then
	probability_chest = P(setting)
end

-- Probability for a rail corridor system to be damaged
local probability_damage = P(0.55)
setting = tonumber(minetest.setting_get("tsm_railcorridors_probability_damage"))
if setting then
	probability_damage = P(setting)
end

-- Max. and min. heights between rail corridors are generated
local height_min = -31000
local height_max = -30
setting = tonumber(minetest.setting_get("tsm_railcorridors_height_min"))
if setting then
	height_min = setting
end
setting = tonumber(minetest.setting_get("tsm_railcorridors_height_max"))
if setting then
	height_max = setting
end

-- Chaos Mode: If enabled, rail corridors don't stop generating when hitting obstacles
local chaos_mode = minetest.setting_getbool("tsm_railcorridors_chaos") or false

-- Parameter Ende

-- random generator
local pr
local pr_initialized = false

local function InitRandomizer(seeed)
	pr = PseudoRandom(seeed)
	pr_initialized = true
end


-- Checks if the mapgen is allowed to carve through this structure and only sets
-- the node if it is allowed.
-- If check_above is true, don't build if the node above is attached (e.g. rail).
local function SetNodeIfCanBuild(pos, node, check_above)
	if check_above then
		local abovedef = minetest.registered_nodes[minetest.get_node({x=pos.x,y=pos.y+1,z=pos.z}).name]
		if abovedef.groups and abovedef.groups.attached_node then
			return false
		end
	end
	if minetest.registered_nodes[minetest.get_node(pos).name].is_ground_content then
		minetest.set_node(pos, node)
		return true
	else
		return false
	end
end

-- Tries to place a rail, taking the damage chance into account
local function PlaceRail(pos, damage_chance)
	if damage_chance ~= nil and damage_chance > 0 then
		local x = pr:next(0,100)
		if x <= damage_chance then
			return
		end
	end
	SetNodeIfCanBuild(pos, {name=tsm_railcorridors.nodes.rail})
end

-- Returns true if the node as point can be considered “ground”, that is, a solid material
-- in which mine shafts can be built into, e.g. stone, but not air or water
local function IsGround(pos)
	local nodename = minetest.get_node(pos).name
	local nodedef = minetest.registered_nodes[nodename]
	return nodename ~= "unknown" and nodename ~= "ignore" and nodedef.is_ground_content and nodedef.walkable and nodedef.liquidtype == "none"
end

-- Returns true if rails are allowed to be placed on top of this node
local function IsRailSurface(pos)
	local nodename = minetest.get_node(pos).name
	local nodedef = minetest.registered_nodes[nodename]
	return nodename ~= "unknown" and nodename ~= "ignore" and nodedef.walkable and (nodedef.node_box == nil or nodedef.node_box.type == "regular")
end

-- Checks if the node is empty space which requires to be filled by a platform
local function NeedsPlatform(pos)
	local node = minetest.get_node({x=pos.x,y=pos.y-1,z=pos.z})
	local node2 = minetest.get_node({x=pos.x,y=pos.y-2,z=pos.z})
	local nodedef = minetest.registered_nodes[node.name]
	return node.name ~= "ignore" and node.name ~= "unknown" and nodedef.is_ground_content and ((nodedef.walkable == false and node2.name ~= tsm_railcorridors.nodes.dirt) or (nodedef.groups and nodedef.groups.falling_node))
end

-- Create a cube filled with the specified nodes
-- Specialties:
-- * Avoids floating rails for non-solid nodes like air
-- Returns true if all nodes could be set
-- Returns false if setting one or more nodes failed
local function Cube(p, radius, node)
	local y_top = p.y+radius
	local nodedef = minetest.registered_nodes[node.name]
	local solid = nodedef.walkable and (nodedef.node_box == nil or nodedef.node_box.type == "regular")
	-- Check if all the nodes could be set
	local built_all = true
	for zi = p.z-radius, p.z+radius do
		for yi = y_top, p.y-radius, -1 do
			for xi = p.x-radius, p.x+radius do
				local ok = false
				if not solid and yi == y_top then
					local topdef = minetest.registered_nodes[minetest.get_node({x=xi,y=yi+1,z=zi}).name]
					if not (topdef.groups and topdef.groups.attached_node) then
						ok = true
					end
				else
					ok = true
				end
				local built = false
				if ok then
					built = SetNodeIfCanBuild({x=xi,y=yi,z=zi}, node)
				end
				if not built then
					built_all = false
				end
			end
		end
	end
	return built_all
end

local function Platform(p, radius, node)
	for zi = p.z-radius, p.z+radius do
		for xi = p.x-radius, p.x+radius do
			local np = NeedsPlatform({x=xi,y=p.y,z=zi})
			if np then
				minetest.set_node({x=xi,y=p.y-1,z=zi}, node)
			end
		end
	end
end

-- Random chest items
-- Zufälliger Kisteninhalt
local function rci()
	if(minetest.get_modpath("treasurer") ~= nil) then
		local treasures
		if pr:next(0,100) < 3 then
			treasures = treasurer.select_random_treasures(1,2,4)
		elseif pr:next(0,100) < 5 then
			if pr:next(0,100) < 50 then
				treasures = treasurer.select_random_treasures(1,2,4,"seed")
			else
				treasures = treasurer.select_random_treasures(1,2,4,"seed")
			end
		elseif pr:next(0,1000) < 5 then
			return "tnt:tnt "..pr:next(1,3)
		elseif pr:next(0,1000) < 3 then
			if pr:next(0,1000) < 800 then
				treasures = treasurer.select_random_treasures(1,3,6,"mineral")
			else
				treasures = treasurer.select_random_treasures(1,5,9,"mineral")
			end
		end

		if(treasures ~= nil) then
			if(#treasures>=1) then
				return treasures[1]:get_name()
			else
				return ""
			end
		else
			return ""
		end
	else
		if pr:next(0,1000) < 30 then
			return "farming:bread "..pr:next(1,3)
		elseif pr:next(0,1000) < 50 then
			if pr:next(0,1000) < 500 then
				return "farming:seed_cotton "..pr:next(1,5)
			else
				return "farming:seed_wheat "..pr:next(1,5)
			end
		elseif pr:next(0,1000) < 5 then
			return "tnt:tnt "..pr:next(1,3)
		elseif pr:next(0,1000) < 5 then
			return "default:pick_steel"
		elseif pr:next(0,1000) < 3 then
			local r = pr:next(0, 1000)
			if r < 400 then
				return "default:steel_ingot "..pr:next(1,5)
			elseif r < 700 then
				return "default:gold_ingot "..pr:next(1,3)
			elseif r < 900 then
				return "default:mese_crystal "..pr:next(1,3)
			else
				return "default:diamond "..pr:next(1,2)
			end
		elseif pr:next(0,1000) < 30 then
			return "default:torch "..pr:next(1,16)
		elseif pr:next(0,1000) < 20 then
			return "default:coal_lump "..pr:next(3,8)
		else
			return ""
		end
	end
end
-- chests
local function Place_Chest(pos)
	if SetNodeIfCanBuild(pos, {name=tsm_railcorridors.nodes.chest}) then
		local meta = minetest.get_meta(pos)
		local inv = meta:get_inventory()
		for i=1, inv:get_size("main") do
			inv:set_stack("main", i, ItemStack(rci()))
		end
	end
end
	
local function WoodBulk(pos, wood)
	SetNodeIfCanBuild({x=pos.x+1, y=pos.y, z=pos.z+1}, {name=wood})
	SetNodeIfCanBuild({x=pos.x-1, y=pos.y, z=pos.z+1}, {name=wood})
	SetNodeIfCanBuild({x=pos.x+1, y=pos.y, z=pos.z-1}, {name=wood})
	SetNodeIfCanBuild({x=pos.x-1, y=pos.y, z=pos.z-1}, {name=wood})
end

-- Gänge mit Schienen
-- Corridors with rails

local function corridor_part(start_point, segment_vector, segment_count, wood, post, is_final)
	local p = {x=start_point.x, y=start_point.y, z=start_point.z}
	local torches = pr:next() < probability_torches_in_segment
	local dir = {0, 0}
	local torchdir = {1, 1}
	local node_wood = {name=wood}
	local node_fence = {name=post}
	if segment_vector.x == 0 and segment_vector.z ~= 0 then
		dir = {1, 0}
		torchdir = {5, 4}
	elseif segment_vector.x ~= 0 and segment_vector.z == 0 then
		dir = {0, 1}
		torchdir = {3, 2}
	end
	for segmentindex = 0, segment_count-1 do
		local dug = Cube(p, 1, {name="air"})
		if not chaos_mode and segmentindex > 0 and not dug then return end
		-- Add wooden platform, if neccessary. To avoid floating rails
		if segment_vector.y == 0 then
			Platform({x=p.x, y=p.y-1, z=p.z}, 1, node_wood)
		end
		-- Diese komischen Holz-Konstruktionen
		-- These strange wood structs
		if segmentindex % 2 == 1 and segment_vector.y == 0 then
			local calc = {
				p.x+dir[1], p.z+dir[2], -- X and Z, added by direction
				p.x-dir[1], p.z-dir[2], -- subtracted
				p.x+dir[2], p.z+dir[1], -- orthogonal
				p.x-dir[2], p.z-dir[1], -- orthogonal, the other way
			}
			--[[ Shape:
				WWW
				P.P
				PrP
				pfp
			W = wood
			P = post (above floor level)
			p = post (in floor level, only placed if no floor)
			
			From previous generation (for reference):
			f = floor
			r = rail
			. = air
			]]

			-- Don't place those wood structs below open air
			if not (minetest.get_node({x=calc[1], y=p.y+2, z=calc[2]}).name == "air" and
				minetest.get_node({x=calc[3], y=p.y+2, z=calc[4]}).name == "air" and
				minetest.get_node({x=p.x, y=p.y+2, z=p.z}).name == "air") then

				-- Left post and planks
				local left_ok = true
				left_ok = SetNodeIfCanBuild({x=calc[1], y=p.y-1, z=calc[2]}, node_fence)
				if left_ok then left_ok = SetNodeIfCanBuild({x=calc[1], y=p.y  , z=calc[2]}, node_fence) end
				if left_ok then left_ok = SetNodeIfCanBuild({x=calc[1], y=p.y+1, z=calc[2]}, node_wood) end

				-- Right post and planks
				local right_ok = true
				right_ok = SetNodeIfCanBuild({x=calc[3], y=p.y-1, z=calc[4]}, node_fence)
				if right_ok then right_ok = SetNodeIfCanBuild({x=calc[3], y=p.y  , z=calc[4]}, node_fence) end
				if right_ok then right_ok = SetNodeIfCanBuild({x=calc[3], y=p.y+1, z=calc[4]}, node_wood) end

				-- Middle planks
				local top_planks_ok = false
				if left_ok and right_ok then top_planks_ok = SetNodeIfCanBuild({x=p.x, y=p.y+1, z=p.z}, node_wood) end

				if minetest.get_node({x=p.x,y=p.y-2,z=p.z}).name=="air" then
					if left_ok then SetNodeIfCanBuild({x=calc[1], y=p.y-2, z=calc[2]}, node_fence) end
					if right_ok then SetNodeIfCanBuild({x=calc[3], y=p.y-2, z=calc[4]}, node_fence) end
				end
				-- Torches on the middle planks
				if torches and top_planks_ok then
					-- Place torches at horizontal sides
					SetNodeIfCanBuild({x=calc[5], y=p.y+1, z=calc[6]}, {name=tsm_railcorridors.nodes.torch_wall, param2=torchdir[1]}, true)
					SetNodeIfCanBuild({x=calc[7], y=p.y+1, z=calc[8]}, {name=tsm_railcorridors.nodes.torch_wall, param2=torchdir[2]}, true)
				end
			elseif torches then
				-- Try to build torches instead of the wood structs
				local node = {name=tsm_railcorridors.nodes.torch_floor, param2=minetest.dir_to_wallmounted({x=0,y=-1,z=0})}

				-- Try two different height levels
				local pos1 = {x=calc[1], y=p.y-2, z=calc[2]}
				local pos2 = {x=calc[3], y=p.y-2, z=calc[4]}
				local nodedef1 = minetest.registered_nodes[minetest.get_node(pos1).name]
				local nodedef2 = minetest.registered_nodes[minetest.get_node(pos2).name]

				if nodedef1.walkable then
					pos1.y = pos1.y + 1
				end
				SetNodeIfCanBuild(pos1, node, true)

				if nodedef2.walkable then
					pos2.y = pos2.y + 1
				end
				SetNodeIfCanBuild(pos2, node, true)

			end
		end
		
		-- nächster Punkt durch Vektoraddition
		-- next way point
		p = vector.add(p, segment_vector)
	end

	-- End of the corridor; create the final piece
	if is_final then
		local dug = Cube(p, 1, {name="air"})
		if not chaos_mode and not dug then return false end
		Platform({x=p.x, y=p.y-1, z=p.z}, 1, node_wood)
	end
	return true
end

local function corridor_func(waypoint, coord, sign, up_or_down, up, wood, post, is_final, up_or_down_next, damage)
	local segamount = 3
	if up_or_down then
		segamount = 1
	end
	if sign then
		segamount = 0-segamount
	end
	local vek = {x=0,y=0,z=0};
	local start = table.copy(waypoint)
	if coord == "x" then
		vek.x=segamount
		if up_or_down and up == false then
			start.x=start.x+segamount
		end
	elseif coord == "z" then
		vek.z=segamount
		if up_or_down and up == false then
			start.z=start.z+segamount
		end
	end
	if up_or_down then
		if up then
			vek.y = 1
		else
			vek.y = -1
		end
	end
	local segcount = pr:next(4,6)
	if up_or_down and up == false then
		Cube(waypoint, 1, {name="air"})
	end
	local done = corridor_part(start, vek, segcount, wood, post, is_final)
	if not chaos_mode and not done then return false end
	local corridor_vek = {x=vek.x*segcount, y=vek.y*segcount, z=vek.z*segcount}

	-- nachträglich Schienen legen
	-- after this: rails
	segamount = 1
	if sign then
		segamount = 0-segamount
	end
	if coord == "x" then
		vek.x=segamount
	elseif coord == "z" then
		vek.z=segamount
	end
	if up_or_down then
		if up then
			vek.y = 1
		else
			vek.y = -1
		end
	end
	if not up_or_down then
		segcount = segcount * 3
	end
	local chestplace = -1
	if not up_or_down and pr:next() < probability_chest then
		chestplace = pr:next(1,segcount+1)
	end
	for i=1,segcount do
		local p = {x=waypoint.x+vek.x*i, y=waypoint.y+vek.y*i-1, z=waypoint.z+vek.z*i}
		if (minetest.get_node({x=p.x,y=p.y-1,z=p.z}).name=="air" and minetest.get_node({x=p.x,y=p.y-3,z=p.z}).name~=tsm_railcorridors.nodes.rail) then
			p.y = p.y - 1;
		end
		if IsRailSurface({x=p.x,y=p.y-1,z=p.z}) then
			PlaceRail(p, damage)
		end
		if i == chestplace then
			if minetest.get_node({x=p.x+vek.z,y=p.y-1,z=p.z-vek.x}).name == post then
				chestplace = chestplace + 1
			else
				Place_Chest({x=p.x+vek.z,y=p.y,z=p.z-vek.x})
			end
		end
	end
	
	local offset = table.copy(corridor_vek)
	local final_point = vector.add(waypoint, offset)
	if up_or_down then
		if up then
			offset.y = offset.y - 1
			final_point = vector.add(waypoint, offset)
		else
			offset[coord] = offset[coord] + segamount
			final_point = vector.add(waypoint, offset)
			if IsRailSurface({x=final_point.x,y=final_point.y-2,z=final_point.z}) then
				PlaceRail({x=final_point.x,y=final_point.y-1,z=final_point.z}, damage)
			end
		end
	end
	return final_point
end

local function start_corridor(waypoint, coord, sign, length, psra, wood, post, damage)
	local wp = waypoint
	local c = coord
	local s = sign
	local ud = false -- up or down
	local udn = false -- up or down is next
	local up
	for i=1,length do
		-- Up or down?
		if udn then
			ud = true
			-- Force direction near the height limits
			if wp.y >= height_max - 12 then
				up = false
			elseif wp.y <= height_min + 12 then
				up = true
			else
				-- Chose random direction in between
				up = pr:next(0, 2) < 1
			end
		else
			ud = false
		end
		-- Update up/down next
		if pr:next() < probability_up_or_down and i~=1 and not udn then
			udn = i < length
		elseif udn then
			udn = false
		end
		-- Make corridor / Korridor graben
		wp = corridor_func(wp,c,s, ud, up, wood, post, i == length, udn, damage)
		if wp == false then return end
		-- Verzweigung?
		-- Fork?
		if pr:next() < probability_fork then
			local p = {x=wp.x, y=wp.y, z=wp.z}
			start_corridor(wp, c, s, pr:next(way_min,way_max), psra, wood, post, damage)
			if c == "x" then c="z" else c="x" end
			start_corridor(wp, c, s, pr:next(way_min,way_max), psra, wood, post, damage)
			start_corridor(wp, c, not s, pr:next(way_min,way_max), psra, wood, post, damage)
			WoodBulk({x=p.x, y=p.y-1, z=p.z}, wood)
			WoodBulk({x=p.x, y=p.y,   z=p.z}, wood)
			WoodBulk({x=p.x, y=p.y+1, z=p.z}, wood)
			WoodBulk({x=p.x, y=p.y+2, z=p.z}, wood)
			return
		end
		-- coord und sign verändern
		-- randomly change sign and coord
		if c=="x" then
			c="z"
		elseif c=="z" then
			c="x"
	 	end;
		s = pr:next(0, 2) < 1
	end
end

local function place_corridors(main_cave_coords, psra)
	--[[ ALWAYS start building in the ground. Prevents corridors starting
	in mid-air or in liquids. ]]
	if not IsGround(main_cave_coords) then
		return
	end

	-- Determine if this corridor system is “damaged” (some rails removed) and to which extent
	local damage = 0
	if pr:next() < probability_damage then
		damage = pr:next(10, 50)
	end
	--[[ Starter cube: A big hollow dirt cube from which the corridors will extend.
	Corridor generation starts here. ]]
	if pr:next(0, 100) < 50 then
		Cube(main_cave_coords, 4, {name=tsm_railcorridors.nodes.dirt})
		Cube(main_cave_coords, 3, {name="air"})
		PlaceRail({x=main_cave_coords.x, y=main_cave_coords.y-3, z=main_cave_coords.z}, damage)
		main_cave_coords.y =main_cave_coords.y - 1
	else
		Cube(main_cave_coords, 3, {name=tsm_railcorridors.nodes.dirt})
		Cube(main_cave_coords, 2, {name="air"})
		PlaceRail({x=main_cave_coords.x, y=main_cave_coords.y-2, z=main_cave_coords.z}, damage)
	end
	local xs = pr:next(0, 2) < 1
	local zs = pr:next(0, 2) < 1;

	-- Select random wood type (found in gameconfig.lua)
	local rnd = pr:next(1,1000)

	local woodtype = 1
	local accumulated_chance = 0
	for w=1, #tsm_railcorridors.nodes.corridor_woods do
		local woodtable = tsm_railcorridors.nodes.corridor_woods[w]
		accumulated_chance = accumulated_chance + woodtable.chance
		if accumulated_chance > 1000 then
			minetest.log("warning", "[tsm_railcorridors] Warning: Wood chances add up to over 100%!")
			break
		end
		if rnd <= accumulated_chance then
			woodtype = w
			break
		end
	end
	local wood = tsm_railcorridors.nodes.corridor_woods[woodtype].wood
	local post = tsm_railcorridors.nodes.corridor_woods[woodtype].post
	start_corridor(main_cave_coords, "x", xs, pr:next(way_min,way_max), psra, wood, post, damage)
	start_corridor(main_cave_coords, "z", zs, pr:next(way_min,way_max), psra, wood, post, damage)
	-- Auch mal die andere Richtung?
	-- Try the other direction?
	if pr:next(0, 100) < 70 then
		start_corridor(main_cave_coords, "x", not xs, pr:next(way_min,way_max), psra, wood, post, damage)
	end
	if pr:next(0, 100) < 70 then
		start_corridor(main_cave_coords, "z", not zs, pr:next(way_min,way_max), psra, wood, post, damage)
	end
end

minetest.register_on_generated(function(minp, maxp, seed)	
	if not pr_initialized then
		InitRandomizer(seed)
	end
	if minp.y < height_max and maxp.y > height_min and pr:next() < probability_railcaves_in_chunk then
		-- Mittelpunkt berechnen
		-- Mid point of the chunk
		local y = math.floor(math.max(height_min, math.min(height_max, minp.y+(maxp.y-minp.y)/2)))
		local p = {x=minp.x+(maxp.x-minp.x)/2, y=y, z=minp.z+(maxp.z-minp.z)/2}
		-- Haupthöhle und alle weiteren
		-- Corridors; starting with main cave out of dirt
		place_corridors(p, pr)
	end
end)
