#ifndef SURFACE_RADIOSITY_REGISTERS_HLSLI
#define SURFACE_RADIOSITY_REGISTERS_HLSLI

// Surface Radiosity UAVs (u0-u7) — Descriptor Table maps to slots 384-391
#define REG_RAD_TRACE_RESULT_UAV   u0
#define REG_RAD_HISTORY_UAV        u1
#define REG_RAD_FILTERED_UAV       u2
#define REG_RAD_SH_R_UAV           u3
#define REG_RAD_SH_G_UAV           u4
#define REG_RAD_SH_B_UAV           u5
#define REG_RAD_PROBE_DEPTH_UAV    u6
#define REG_RAD_PROBE_NORMAL_UAV   u7

// Surface Radiosity SRVs (t20-t27) — Descriptor Table maps to slots 392-399
#define REG_RAD_TRACE_RESULT_SRV   t20
#define REG_RAD_HISTORY_SRV        t21
#define REG_RAD_FILTERED_SRV       t22
#define REG_RAD_SH_R_SRV           t23
#define REG_RAD_SH_G_SRV           t24
#define REG_RAD_SH_B_SRV           t25
#define REG_RAD_PROBE_DEPTH_SRV    t26
#define REG_RAD_PROBE_NORMAL_SRV   t27

#endif // SURFACE_RADIOSITY_REGISTERS_HLSLI
