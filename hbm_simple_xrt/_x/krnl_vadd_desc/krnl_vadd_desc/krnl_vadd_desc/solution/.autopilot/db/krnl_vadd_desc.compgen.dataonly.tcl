# This script segment is generated automatically by AutoPilot

set axilite_register_dict [dict create]
set port_control {
desc_mem { 
	dir I
	width 64
	depth 1
	mode ap_none
	offset 16
	offset_end 27
}
data_mem0 { 
	dir I
	width 64
	depth 1
	mode ap_none
	offset 28
	offset_end 39
}
data_mem1 { 
	dir I
	width 64
	depth 1
	mode ap_none
	offset 40
	offset_end 51
}
data_mem2 { 
	dir I
	width 64
	depth 1
	mode ap_none
	offset 52
	offset_end 63
}
first_desc_addr { 
	dir I
	width 64
	depth 1
	mode ap_none
	offset 64
	offset_end 75
}
max_descriptors { 
	dir I
	width 32
	depth 1
	mode ap_none
	offset 76
	offset_end 83
}
ap_start { }
ap_done { }
ap_ready { }
ap_continue { }
ap_idle { }
interrupt {
}
}
dict set axilite_register_dict control $port_control


