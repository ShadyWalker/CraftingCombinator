local entities = require "therustyknife.crafting_combinator.entities"
local FML = require "therustyknife.FML"
local config = require "config"
local recipe_selector = require "script.recipe_selector"
local gui = require "script.gui"


FML.global.on_init(function()
	global.combinators.crafting = global.combinators.crafting or {}
end)


local _M = entities.Combinator:extend()


FML.global.on_load(function() _M.tab = global.combinators.crafting end)


function _M.update_assemblers(surface, position)
	local found = surface.find_entities_filtered{
		area = FML.surface.area_around(position, config.CC_SEARCH_DISTANCE),
		name = config.CC_NAME,
	}
	
	for _, entity in pairs(found) do
		entities.util.find_in_global(entity):find_assembler()
	end
end


function _M:on_create()
	self.settings = FML.table.deep_copy(config.CC_DEFAULT_SETTINGS)
	
	self.chests = {
		passive = self.entity.surface.create_entity{
			name = config.OVERFLOW_P_NAME,
			position = self.entity.position,
			force = self.entity.force,
		},
		active = self.entity.surface.create_entity{
			name = config.OVERFLOW_A_NAME,
			position = self.entity.position,
			force = self.entity.force,
		},
		normal = self.entity.surface.create_entity{
			name = config.OVERFLOW_N_NAME,
			position = self.entity.position,
			force = self.entity.force,
		},
	}
	
	for _, chest in pairs(self.chests) do chest.destructible = false; end
	
	self.inventories = {
		passive = self.chests.passive.get_inventory(defines.inventory.chest),
		active = self.chests.active.get_inventory(defines.inventory.chest),
		normal = self.chests.normal.get_inventory(defines.inventory.chest),
		assembler = {},
	}
	
	self:find_assembler()
end

function _M:update()
	local params = {}
	
	if self.assembler and self.assembler.valid then
		if self.settings.set_recipes then
			local recipe = recipe_selector.get_recipe(self.control_behavior, self.items_to_ignore)
			
			if self.assembler.recipe and ((not recipe) or recipe ~= self.assembler.recipe) then
				-- figure out the correct place to put the items
				local target = self:get_target(self.settings.item_destination)
				
				-- move items from the assembler to the overflow chests
				for _, inventory in pairs{self.inventories.assembler.input, self.inventories.assembler.output} do
					for i = 1, #inventory do
						local stack = inventory[i]
						if stack.valid_for_read then target.insert(stack); end
					end
				end
				
				-- compensate for half-finished recipes that had already consumed their ingredients
				if self.assembler.crafting_progress > 0 then
					for _, ing in pairs(self.assembler.recipe.ingredients) do
						if ing.type == "item" then
							target.insert{name = ing.name, count = ing.amount}
						end
					end
				end
				
				-- empty inserters' hands into the overflow
				if self.settings.empty_inserters then
					for _, inserter in pairs(self.assembler.surface.find_entities_filtered{
						area = FML.surface.area_around(self.assembler.position, config.CC_INSERTER_SEARCH_DISTANCE),
						type = "inserter",
					}) do
						if inserter.drop_target == self.assembler then
							local stack = inserter.held_stack
							if stack.valid_for_read then
								target.insert(stack)
								stack.count = 0
							end
						end
					end
				end
			end
			
			-- move the modules that will get discarded by this recipe change into the overflow
			if recipe and recipe ~= self.assembler.recipe then
				local target = self:get_target(self.settings.module_destination)
				local inventory = self.inventories.assembler.modules

				for i = 1, #inventory do
					local stack = inventory[i]
					if stack.valid_for_read then
						local limitations = game.item_prototypes[stack.name]
						if limitations and not FML.table.contains(limitations, recipe.name) then target.insert(stack); end
					end
				end
			end
			
			self.assembler.recipe = recipe
		end
		
		if self.settings.read_recipes and self.assembler.recipe then
			for type, type_tab in pairs{
				item = game.item_prototypes,
				fluid = game.fluid_prototypes,
				virtual = game.virtual_signal_prototypes,
			} do
				local prototype = type_tab[self.assembler.recipe.name]
				if prototype then
					table.insert(params, {
							signal = {type = type, name = prototype.name},
							count = 1,
							index = 1,
						})
					self.items_to_ignore = {[prototype.name] = 1}
					break
				end
			end
		else
			self.items_to_ignore = nil
		end
	end
	
	self.control_behavior.parameters = {enabled = true, parameters = params}
end

function _M:destroy(player)
	-- if the player mined this, move items from overflow to her inventory, otherwise spill them on the ground --TODO: find a better way to handle the second case
	for _, inventory in pairs{self.inventories.passive, self.inventories.active, self.inventories.normal} do
		for i = 1, #inventory do
			local stack = inventory[i]
			if stack.valid_for_read then
				local remaining = stack.count
				if player then remaining = remaining - player.insert(stack); end
				
				if remaining > 0 then
					stack.count = remaining
					self.entity.surface.spill_item_stack(self.entity.position, stack, true)
				end
			end
		end
	end
	
	if self.gui then self.gui.destroy(); end
	
	for _, chest in pairs(self.chests) do chest.destroy() end
	
	self.super.destroy(self)
end

function _M:on_opened(player)
	gui.crafting_combinator_settings(self, player)
end

function _M:find_assembler()
	self.assembler = self.entity.surface.find_entities_filtered{
		area = FML.surface.area_around(FML.surface.move_position(self.entity.position, self.entity.direction, config.CC_ASSEMBLER_DISTANCE), config.CC_ASSEMBLER_OFFSET),
		type = "assembling-machine",
	}[1]
	
	if self.assembler then
		self.inventories.assembler = {
			output = self.assembler.get_inventory(defines.inventory.assembling_machine_output),
			input = self.assembler.get_inventory(defines.inventory.assembling_machine_input),
			modules = self.assembler.get_inventory(defines.inventory.assembling_machine_modules),
		}
	else
		self.inventories.assembler = {}
	end
end

local empty_target = {insert = function() end} -- when no chest is selected as overflow output

function _M:get_target(mode)
	if mode == "active" then return self.chests.active
	elseif mode == "passive" then return self.chests.passive
	elseif mode == "normal" then return self.chests.normal
	else return empty_target
	end
end


return _M