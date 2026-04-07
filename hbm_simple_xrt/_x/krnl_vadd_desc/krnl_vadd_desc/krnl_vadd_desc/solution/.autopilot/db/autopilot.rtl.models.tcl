set SynModuleInfo {
  {SRCNAME krnl_vadd_desc_Pipeline_data_transfer_loop MODELNAME krnl_vadd_desc_Pipeline_data_transfer_loop RTLNAME krnl_vadd_desc_krnl_vadd_desc_Pipeline_data_transfer_loop
    SUBMODULES {
      {MODELNAME krnl_vadd_desc_flow_control_loop_pipe_sequential_init RTLNAME krnl_vadd_desc_flow_control_loop_pipe_sequential_init BINDTYPE interface TYPE internal_upc_flow_control INSTNAME krnl_vadd_desc_flow_control_loop_pipe_sequential_init_U}
    }
  }
  {SRCNAME krnl_vadd_desc MODELNAME krnl_vadd_desc RTLNAME krnl_vadd_desc IS_TOP 1
    SUBMODULES {
      {MODELNAME krnl_vadd_desc_gmem_desc_m_axi RTLNAME krnl_vadd_desc_gmem_desc_m_axi BINDTYPE interface TYPE adapter IMPL m_axi}
      {MODELNAME krnl_vadd_desc_gmem0_m_axi RTLNAME krnl_vadd_desc_gmem0_m_axi BINDTYPE interface TYPE adapter IMPL m_axi}
      {MODELNAME krnl_vadd_desc_gmem2_m_axi RTLNAME krnl_vadd_desc_gmem2_m_axi BINDTYPE interface TYPE adapter IMPL m_axi}
      {MODELNAME krnl_vadd_desc_control_s_axi RTLNAME krnl_vadd_desc_control_s_axi BINDTYPE interface TYPE interface_s_axilite}
    }
  }
}
