std = "lua51+luajit"
max_line_length = 110
globals = {
	"sharp_inventory",
	core = { other_fields = true, fields = { show_formspec = { read_only = false } } },
	mcl_vars = {
		other_fields = true,
		fields = {
			gui_slots = { read_only = false },
			gui_nonbg = { read_only = false },
			gui_bg_img = { read_only = false },
		},
	},
	mcl_formspec = {
		other_fields = true,
		fields = {
			label_color = { read_only = false },
			get_itemslot_bg = { read_only = false },
			get_itemslot_bg_v4 = { read_only = false },
		},
	},
	mcl_player = {
		other_fields = true,
		fields = { set_inventory_formspec = { read_only = false } },
	},
}
read_globals = {
	"vector",
	"ItemStack",
	"mcl_inventory",
	"mcl_redstone",
	"sharp_map", -- optional, looked up at runtime (creative.lua)
}
