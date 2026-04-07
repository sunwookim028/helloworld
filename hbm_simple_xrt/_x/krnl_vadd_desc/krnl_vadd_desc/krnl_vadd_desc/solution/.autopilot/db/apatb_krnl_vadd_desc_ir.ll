; ModuleID = '/work/shared/users/phd/sk3463/projects/helloworld/hbm_simple_xrt/_x/krnl_vadd_desc/krnl_vadd_desc/krnl_vadd_desc/solution/.autopilot/db/a.g.ld.5.gdce.bc'
source_filename = "llvm-link"
target datalayout = "e-m:e-i64:64-i128:128-i256:256-i512:512-i1024:1024-i2048:2048-i4096:4096-n8:16:32:64-S128-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-v512:512-v1024:1024"
target triple = "fpga64-xilinx-none"

%"struct.ap_uint<512>" = type { %"struct.ap_int_base<512, false>" }
%"struct.ap_int_base<512, false>" = type { %"struct.ssdm_int<512, false>" }
%"struct.ssdm_int<512, false>" = type { i512 }

; Function Attrs: inaccessiblemem_or_argmemonly noinline willreturn
define void @apatb_krnl_vadd_desc_ir(%"struct.ap_uint<512>"* noalias nocapture nonnull readonly "maxi" %desc_mem, %"struct.ap_uint<512>"* noalias nocapture nonnull readonly "maxi" %data_mem0, %"struct.ap_uint<512>"* noalias nocapture nonnull readonly "maxi" %data_mem1, %"struct.ap_uint<512>"* noalias nocapture nonnull "maxi" %data_mem2, i64 %first_desc_addr, i32 %max_descriptors) local_unnamed_addr #0 {
entry:
  %desc_mem_copy = alloca i512, align 512
  %data_mem0_copy = alloca i512, align 512
  %data_mem1_copy = alloca i512, align 512
  %data_mem2_copy = alloca i512, align 512
  call fastcc void @copy_in(%"struct.ap_uint<512>"* nonnull %desc_mem, i512* nonnull align 512 %desc_mem_copy, %"struct.ap_uint<512>"* nonnull %data_mem0, i512* nonnull align 512 %data_mem0_copy, %"struct.ap_uint<512>"* nonnull %data_mem1, i512* nonnull align 512 %data_mem1_copy, %"struct.ap_uint<512>"* nonnull %data_mem2, i512* nonnull align 512 %data_mem2_copy)
  call void @apatb_krnl_vadd_desc_hw(i512* %desc_mem_copy, i512* %data_mem0_copy, i512* %data_mem1_copy, i512* %data_mem2_copy, i64 %first_desc_addr, i32 %max_descriptors)
  call void @copy_back(%"struct.ap_uint<512>"* %desc_mem, i512* %desc_mem_copy, %"struct.ap_uint<512>"* %data_mem0, i512* %data_mem0_copy, %"struct.ap_uint<512>"* %data_mem1, i512* %data_mem1_copy, %"struct.ap_uint<512>"* %data_mem2, i512* %data_mem2_copy)
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @copy_in(%"struct.ap_uint<512>"* noalias readonly "unpacked"="0", i512* noalias nocapture align 512 "unpacked"="1.0", %"struct.ap_uint<512>"* noalias readonly "unpacked"="2", i512* noalias nocapture align 512 "unpacked"="3.0", %"struct.ap_uint<512>"* noalias readonly "unpacked"="4", i512* noalias nocapture align 512 "unpacked"="5.0", %"struct.ap_uint<512>"* noalias readonly "unpacked"="6", i512* noalias nocapture align 512 "unpacked"="7.0") unnamed_addr #1 {
entry:
  call fastcc void @"onebyonecpy_hls.p0struct.ap_uint<512>.9"(i512* align 512 %1, %"struct.ap_uint<512>"* %0)
  call fastcc void @"onebyonecpy_hls.p0struct.ap_uint<512>.9"(i512* align 512 %3, %"struct.ap_uint<512>"* %2)
  call fastcc void @"onebyonecpy_hls.p0struct.ap_uint<512>.9"(i512* align 512 %5, %"struct.ap_uint<512>"* %4)
  call fastcc void @"onebyonecpy_hls.p0struct.ap_uint<512>.9"(i512* align 512 %7, %"struct.ap_uint<512>"* %6)
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @copy_out(%"struct.ap_uint<512>"* noalias "unpacked"="0", i512* noalias nocapture readonly align 512 "unpacked"="1.0", %"struct.ap_uint<512>"* noalias "unpacked"="2", i512* noalias nocapture readonly align 512 "unpacked"="3.0", %"struct.ap_uint<512>"* noalias "unpacked"="4", i512* noalias nocapture readonly align 512 "unpacked"="5.0", %"struct.ap_uint<512>"* noalias "unpacked"="6", i512* noalias nocapture readonly align 512 "unpacked"="7.0") unnamed_addr #2 {
entry:
  call fastcc void @"onebyonecpy_hls.p0struct.ap_uint<512>"(%"struct.ap_uint<512>"* %0, i512* align 512 %1)
  call fastcc void @"onebyonecpy_hls.p0struct.ap_uint<512>"(%"struct.ap_uint<512>"* %2, i512* align 512 %3)
  call fastcc void @"onebyonecpy_hls.p0struct.ap_uint<512>"(%"struct.ap_uint<512>"* %4, i512* align 512 %5)
  call fastcc void @"onebyonecpy_hls.p0struct.ap_uint<512>"(%"struct.ap_uint<512>"* %6, i512* align 512 %7)
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @"onebyonecpy_hls.p0struct.ap_uint<512>"(%"struct.ap_uint<512>"* noalias "unpacked"="0" %dst, i512* noalias nocapture readonly align 512 "unpacked"="1.0" %src) unnamed_addr #3 {
entry:
  %0 = icmp eq %"struct.ap_uint<512>"* %dst, null
  br i1 %0, label %ret, label %copy

copy:                                             ; preds = %entry
  %dst.0.0.04 = getelementptr %"struct.ap_uint<512>", %"struct.ap_uint<512>"* %dst, i64 0, i32 0, i32 0, i32 0
  %1 = load i512, i512* %src, align 512
  store i512 %1, i512* %dst.0.0.04, align 64
  br label %ret

ret:                                              ; preds = %copy, %entry
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @"onebyonecpy_hls.p0struct.ap_uint<512>.9"(i512* noalias nocapture align 512 "unpacked"="0.0" %dst, %"struct.ap_uint<512>"* noalias readonly "unpacked"="1" %src) unnamed_addr #3 {
entry:
  %0 = icmp eq %"struct.ap_uint<512>"* %src, null
  br i1 %0, label %ret, label %copy

copy:                                             ; preds = %entry
  %src.0.0.03 = getelementptr %"struct.ap_uint<512>", %"struct.ap_uint<512>"* %src, i64 0, i32 0, i32 0, i32 0
  %1 = load i512, i512* %src.0.0.03, align 64
  store i512 %1, i512* %dst, align 512
  br label %ret

ret:                                              ; preds = %copy, %entry
  ret void
}

declare void @apatb_krnl_vadd_desc_hw(i512*, i512*, i512*, i512*, i64, i32)

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @copy_back(%"struct.ap_uint<512>"* noalias "unpacked"="0", i512* noalias nocapture readonly align 512 "unpacked"="1.0", %"struct.ap_uint<512>"* noalias "unpacked"="2", i512* noalias nocapture readonly align 512 "unpacked"="3.0", %"struct.ap_uint<512>"* noalias "unpacked"="4", i512* noalias nocapture readonly align 512 "unpacked"="5.0", %"struct.ap_uint<512>"* noalias "unpacked"="6", i512* noalias nocapture readonly align 512 "unpacked"="7.0") unnamed_addr #2 {
entry:
  call fastcc void @"onebyonecpy_hls.p0struct.ap_uint<512>"(%"struct.ap_uint<512>"* %6, i512* align 512 %7)
  ret void
}

define void @krnl_vadd_desc_hw_stub_wrapper(i512*, i512*, i512*, i512*, i64, i32) #4 {
entry:
  %6 = alloca %"struct.ap_uint<512>"
  %7 = alloca %"struct.ap_uint<512>"
  %8 = alloca %"struct.ap_uint<512>"
  %9 = alloca %"struct.ap_uint<512>"
  call void @copy_out(%"struct.ap_uint<512>"* %6, i512* %0, %"struct.ap_uint<512>"* %7, i512* %1, %"struct.ap_uint<512>"* %8, i512* %2, %"struct.ap_uint<512>"* %9, i512* %3)
  call void @krnl_vadd_desc_hw_stub(%"struct.ap_uint<512>"* %6, %"struct.ap_uint<512>"* %7, %"struct.ap_uint<512>"* %8, %"struct.ap_uint<512>"* %9, i64 %4, i32 %5)
  call void @copy_in(%"struct.ap_uint<512>"* %6, i512* %0, %"struct.ap_uint<512>"* %7, i512* %1, %"struct.ap_uint<512>"* %8, i512* %2, %"struct.ap_uint<512>"* %9, i512* %3)
  ret void
}

declare void @krnl_vadd_desc_hw_stub(%"struct.ap_uint<512>"*, %"struct.ap_uint<512>"*, %"struct.ap_uint<512>"*, %"struct.ap_uint<512>"*, i64, i32)

attributes #0 = { inaccessiblemem_or_argmemonly noinline willreturn "fpga.wrapper.func"="wrapper" }
attributes #1 = { argmemonly noinline norecurse willreturn "fpga.wrapper.func"="copyin" }
attributes #2 = { argmemonly noinline norecurse willreturn "fpga.wrapper.func"="copyout" }
attributes #3 = { argmemonly noinline norecurse willreturn "fpga.wrapper.func"="onebyonecpy_hls" }
attributes #4 = { "fpga.wrapper.func"="stub" }

!llvm.dbg.cu = !{}
!llvm.ident = !{!0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0, !0}
!llvm.module.flags = !{!1, !2, !3}
!blackbox_cfg = !{!4}

!0 = !{!"clang version 7.0.0 "}
!1 = !{i32 2, !"Dwarf Version", i32 4}
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !{i32 1, !"wchar_size", i32 4}
!4 = !{}
