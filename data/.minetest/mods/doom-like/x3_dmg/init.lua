-- /home/estudiante/.var/app/org.luanti.luanti/.minetest/games/ffa_skywars/mods/X3_dmg/init.lua

-- Determina el color (HEX) según la cantidad de daño provocado
local function get_damage_color(damage)
    if damage < 10 then
        return "#00FF00" -- Verde
    elseif damage < 30 then
        return "#FFFF00" -- Amarillo
    elseif damage < 100 then
        return "#FF8800" -- Naranja
    elseif damage < 1000 then
        return "#FF0000" -- Rojo
    else
        return "#A000FF" -- Morado
    end
end

-- Función global para crear la partícula combinada de daño sin deformación
function x3_dmg_show(pos, damage)
    if not pos or not damage or damage <= 0 then return end

    local dmgstr = tostring(math.floor(damage))
    local num_digits = #dmgstr

    local digit_w = 32
    local digit_h = 32
    local digits_total_w = digit_w * num_digits

    -- Usamos un lienzo cuadrado basado en el ancho total para evitar que Minetest lo aplaste
    local canvas_size = math.max(digits_total_w, digit_h)
    local offset_y = math.floor((canvas_size - digit_h) / 2)
    local start_x = math.floor((canvas_size - digits_total_w) / 2)

    -- Genera el lienzo cuadrado
    local texture = "[combine:" .. canvas_size .. "x" .. canvas_size
    for i = 1, num_digits do
        local digit = dmgstr:sub(i, i)
        local pos_x = start_x + (i - 1) * digit_w
        texture = texture .. ":" .. pos_x .. "," .. offset_y .. "=" .. digit .. ".png"
    end

    -- Aplica el color según el daño
    local color = get_damage_color(damage)
    texture = texture .. "^[colorize:" .. color .. ":200"

    -- Posición de aparición sobre la entidad
    local angle = math.random() * math.pi * 2
    local offset_dist = 0.8

    local spawn_pos = {
        x = pos.x + math.cos(angle) * offset_dist,
        y = pos.y + 1.8,
        z = pos.z + math.sin(angle) * offset_dist
    }

    -- Ajusta el tamaño de la partícula según el lienzo para mantener la escala visual constante
    local scale_factor = canvas_size / 32
    local particle_size = 2.2 * scale_factor

    minetest.add_particle({
        pos = spawn_pos,
        velocity = {
            x = (math.random() - 0.5) * 0.4,
            y = 1.2,
            z = (math.random() - 0.5) * 0.4
        },
        acceleration = {x = 0, y = -1.5, z = 0},
        expirationtime = 2.0,
        size = particle_size,
        collisiondetection = false,
        vertical = false,
        texture = texture,
        glow = 14
    })
end

-- 1. DETECTAR DAÑO RECIBIDO POR JUGADORES
minetest.register_on_player_hpchange(function(player, hp_change, reason)
    if hp_change < 0 then
        x3_dmg_show(player:get_pos(), math.abs(hp_change))
    end
    return hp_change
end, true)

-- 2. DETECTAR DAÑO ASESTADO A MOBS / ENTIDADES
minetest.register_on_mods_loaded(function()
    for name, def in pairs(minetest.registered_entities) do
        local old_on_punch = def.on_punch
        def.on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
            local pos = self.object and self.object:get_pos()
            local dmg = damage or 0

            if dmg == 0 and tool_capabilities and tool_capabilities.damage_groups then
                dmg = tool_capabilities.damage_groups.fleshy or 1
            end

            if pos and dmg > 0 then
                x3_dmg_show(pos, dmg)
            end

            if old_on_punch then
                return old_on_punch(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
            end
        end
    end
end)
