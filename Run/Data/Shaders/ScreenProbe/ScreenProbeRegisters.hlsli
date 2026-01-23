//=============================================================================
// ScreenProbeRegisters.hlsli
// Bindless 风格寄存器定义 - UAV 和 SRV 分别连续排列
//
// 重要：此文件必须与 RenderCommon.h 中的描述符索引完全匹配！
//=============================================================================

#ifndef SCREENPROBE_REGISTERS_HLSLI
#define SCREENPROBE_REGISTERS_HLSLI

//=============================================================================
// 外部资源 (来自其他 Pass)
//=============================================================================

// GBuffer (t200-t203)
#define REG_GBUFFER_ALBEDO      t214
#define REG_GBUFFER_NORMAL      t215
#define REG_GBUFFER_MATERIAL    t216
#define REG_GBUFFER_MOTION      t217
// Depth (t218)
#define REG_DEPTH_BUFFER        t218

//=============================================================================
// Voxel Scene 资源 (从 375 开始)
//=============================================================================

// UAVs (375-377)
#define REG_GLOBAL_SDF_UAV      u375
#define REG_VOXEL_LIGHTING_UAV  u376
#define REG_VISIBILITY_UAV      u377

// SRVs (378-382)
#define REG_GLOBAL_SDF_SRV      t378
#define REG_VOXEL_LIGHTING_SRV  t379   // Texture3D
#define REG_INSTANCE_INFO_SRV   t380   // Buffer
#define REG_SURFACE_ATLAS_SRV   t381   // Texture2DArray
#define REG_CARD_METADATA_SRV   t382   // StructuredBuffer

//=============================================================================
// Surface Radiosity 资源 (从 384 开始)
// UAVs: 384-391, SRVs: 392-399
//=============================================================================

// UAVs 连续 (384-391)
#define REG_RAD_TRACE_RESULT_UAV   u384
#define REG_RAD_HISTORY_UAV        u385
#define REG_RAD_FILTERED_UAV       u386
#define REG_RAD_SH_R_UAV           u387
#define REG_RAD_SH_G_UAV           u388
#define REG_RAD_SH_B_UAV           u389
#define REG_RAD_PROBE_DEPTH_UAV    u390
#define REG_RAD_PROBE_NORMAL_UAV   u391

// SRVs 连续 (392-399)
#define REG_RAD_TRACE_RESULT_SRV   t392
#define REG_RAD_HISTORY_SRV        t393
#define REG_RAD_FILTERED_SRV       t394
#define REG_RAD_SH_R_SRV           t395
#define REG_RAD_SH_G_SRV           t396
#define REG_RAD_SH_B_SRV           t397
#define REG_RAD_PROBE_DEPTH_SRV    t398
#define REG_RAD_PROBE_NORMAL_SRV   t399

//=============================================================================
// Screen Probe 资源 (从 400 开始)
// UAVs: 400-414, SRVs: 415-429
// UAVs 连续 (401-414)
#define REG_PROBE_BUFFER_UAV              u401
#define REG_BRDF_PDF_UAV                  u402
#define REG_LIGHTING_PDF_UAV              u403
#define REG_PREV_RADIANCE_UAV             u404
#define REG_SAMPLE_DIR_UAV                u405
#define REG_MESH_TRACE_UAV                u406
#define REG_VOXEL_TRACE_UAV               u407
#define REG_PROBE_RAD_UAV                 u408
#define REG_PROBE_RAD_HIST_UAV            u409
#define REG_PROBE_RAD_FILT_UAV            u410
#define REG_OCT_SH_R_UAV                  u411
#define REG_OCT_SH_G_UAV                  u412
#define REG_OCT_SH_B_UAV                  u413
#define REG_INDIRECT_LIGHT_UAV            u414
#define REG_PROBE_RAD_HIST_B_UAV          u415

// SRVs 连续 (414-428)
#define REG_PROBE_BUFFER_SRV              t416
#define REG_BRDF_PDF_SRV                  t417
#define REG_LIGHTING_PDF_SRV              t418
#define REG_PREV_RADIANCE_SRV             t419
#define REG_PREV_DEPTH_SRV                t420
#define REG_SAMPLE_DIR_SRV                t421
#define REG_MESH_TRACE_SRV                t422
#define REG_VOXEL_TRACE_SRV               t423
#define REG_PROBE_RAD_SRV                 t424
#define REG_PROBE_RAD_HIST_SRV            t425
#define REG_PROBE_RAD_FILT_SRV            t426
#define REG_OCT_SH_R_SRV                  t427
#define REG_OCT_SH_G_SRV                  t428
#define REG_OCT_SH_B_SRV                  t429
#define REG_INDIRECT_LIGHT_SRV            t430
#define REG_PROBE_RAD_HIST_B_SRV          t431

#endif // SCREENPROBE_REGISTERS_HLSLI
