//=============================================================================
// SimpleSSR.h
// 简化版 Screen Space Reflections 实现
//=============================================================================

#pragma once

#ifdef ENGINE_DX12_RENDERER

#include <d3d12.h>
#include <cstdint>

// 前向声明
struct GBufferData;
struct ConstantBuffer;

//-----------------------------------------------------------------------------
// 配置
//-----------------------------------------------------------------------------

namespace SSRConfig
{
    // 追踪参数
    constexpr uint32_t MAX_TRACE_STEPS = 64;
    constexpr float MAX_TRACE_DISTANCE = 500.0f;  // 世界单位
    constexpr float THICKNESS = 0.5f;
    
    // Hi-Z参数
    constexpr uint32_t HIZ_MIP_COUNT = 7;
    
    // 滤波参数
    constexpr uint32_t SPATIAL_FILTER_RADIUS = 4;
    constexpr float TEMPORAL_BLEND = 0.1f;
    
    // 效果参数
    constexpr float REFLECTION_INTENSITY = 0.5f;
    constexpr float EDGE_FADE_START = 0.8f;
    
    // 性能选项
    constexpr bool USE_HALF_RES = false;  // 半分辨率追踪
    constexpr bool USE_HIZ = true;        // 使用Hi-Z加速
}

//-----------------------------------------------------------------------------
// GPU常量结构
//-----------------------------------------------------------------------------

struct SSRConstants
{
    float4x4 ViewMatrix;
    float4x4 ProjMatrix;
    float4x4 InvProjMatrix;
    float4x4 InvViewProjMatrix;
    float4x4 PrevViewProjMatrix;
    
    float3 CameraPosition;
    float MaxTraceDistance;
    
    float3 CameraForward;
    float Thickness;
    
    uint32_t ScreenWidth;
    uint32_t ScreenHeight;
    uint32_t MaxTraceSteps;
    uint32_t FrameIndex;
    
    float TemporalBlend;
    float ReflectionIntensity;
    float2 Padding;
};

//-----------------------------------------------------------------------------
// Hi-Z常量
//-----------------------------------------------------------------------------

struct HiZConstants
{
    uint32_t SrcWidth;
    uint32_t SrcHeight;
    uint32_t DstWidth;
    uint32_t DstHeight;
    uint32_t MipLevel;
    float3 Padding;
};

//-----------------------------------------------------------------------------
// 主类
//-----------------------------------------------------------------------------

class SimpleSSR
{
public:
    SimpleSSR() = default;
    ~SimpleSSR();
    
    // 初始化
    void Initialize(
        ID3D12Device* device,
        ID3D12DescriptorHeap* descriptorHeap,
        uint32_t descriptorOffset,  // 在堆中的起始偏移
        uint32_t screenWidth,
        uint32_t screenHeight
    );
    
    void Shutdown();
    
    // 每帧执行
    void Execute(
        ID3D12GraphicsCommandList* cmdList,
        ConstantBuffer* constantBuffer,
        const SSRConstants& constants,
        GBufferData* gBuffer,
        ID3D12Resource* prevFrameColor  // 上一帧颜色用于采样反射
    );
    
    // 窗口大小改变时调用
    void Resize(uint32_t newWidth, uint32_t newHeight);
    
    // Getters
    ID3D12Resource* GetReflectionOutput() const { return m_reflectionOutput; }
    ID3D12Resource* GetHiZBuffer() const { return m_hiZBuffer; }
    bool IsInitialized() const { return m_initialized; }
    
    // 调试
    void SetDebugMode(int mode) { m_debugMode = mode; }
    int GetDebugMode() const { return m_debugMode; }
    
private:
    // Pass实现
    void Pass_GenerateHiZ(ID3D12GraphicsCommandList* cmdList, ID3D12Resource* depthBuffer);
    void Pass_SSRTrace(ID3D12GraphicsCommandList* cmdList, const SSRConstants& constants);
    void Pass_SpatialFilter(ID3D12GraphicsCommandList* cmdList);
    void Pass_TemporalAccumulation(ID3D12GraphicsCommandList* cmdList, const SSRConstants& constants);
    
    // 资源创建
    void CreateResources();
    void CreateHiZResources();
    void CreateSSRResources();
    void CreateRootSignatures();
    void CreatePipelineStates();
    
    // 辅助函数
    void CreateTexture2D(
        ID3D12Resource** outResource,
        uint32_t width,
        uint32_t height,
        DXGI_FORMAT format,
        D3D12_RESOURCE_FLAGS flags,
        D3D12_RESOURCE_STATES initialState,
        const wchar_t* debugName
    );
    
    void TransitionResource(
        ID3D12GraphicsCommandList* cmdList,
        ID3D12Resource* resource,
        D3D12_RESOURCE_STATES before,
        D3D12_RESOURCE_STATES after
    );
    
    D3D12_CPU_DESCRIPTOR_HANDLE GetCPUHandle(uint32_t offset);
    D3D12_GPU_DESCRIPTOR_HANDLE GetGPUHandle(uint32_t offset);
    
private:
    ID3D12Device* m_device = nullptr;
    ID3D12DescriptorHeap* m_descriptorHeap = nullptr;
    uint32_t m_descriptorOffset = 0;
    UINT m_descriptorSize = 0;
    
    uint32_t m_screenWidth = 0;
    uint32_t m_screenHeight = 0;
    bool m_initialized = false;
    
    // 执行时临时引用
    ConstantBuffer* m_constantBuffer = nullptr;
    GBufferData* m_gBuffer = nullptr;
    ID3D12Resource* m_prevFrameColor = nullptr;
    
    //=========================================================================
    // GPU资源
    //=========================================================================
    
    // Hi-Z Buffer（带Mipmap的深度）
    ID3D12Resource* m_hiZBuffer = nullptr;
    
    // SSR追踪结果
    ID3D12Resource* m_ssrTraceResult = nullptr;    // RGBA16F: RGB=反射色, A=置信度
    
    // 滤波后结果
    ID3D12Resource* m_ssrFiltered = nullptr;       // RGBA16F
    
    // 最终输出
    ID3D12Resource* m_reflectionOutput = nullptr;  // RGBA16F
    
    // 时间累积历史（双缓冲）
    ID3D12Resource* m_historyA = nullptr;
    ID3D12Resource* m_historyB = nullptr;
    bool m_useHistoryB = false;
    
    //=========================================================================
    // Root Signatures
    //=========================================================================
    
    ID3D12RootSignature* m_hiZRootSignature = nullptr;
    ID3D12RootSignature* m_ssrRootSignature = nullptr;
    
    //=========================================================================
    // Pipeline States
    //=========================================================================
    
    ID3D12PipelineState* m_pso_HiZGenerate = nullptr;
    ID3D12PipelineState* m_pso_SSRTrace = nullptr;
    ID3D12PipelineState* m_pso_SpatialFilter = nullptr;
    ID3D12PipelineState* m_pso_TemporalAccum = nullptr;
    
    //=========================================================================
    // Descriptor偏移（相对于m_descriptorOffset）
    //=========================================================================
    
    enum DescriptorOffsets
    {
        DESC_HIZ_SRV = 0,
        DESC_HIZ_UAV_BASE,  // HIZ_MIP_COUNT个UAV
        DESC_SSR_TRACE_UAV = DESC_HIZ_UAV_BASE + SSRConfig::HIZ_MIP_COUNT,
        DESC_SSR_FILTERED_UAV,
        DESC_OUTPUT_UAV,
        DESC_HISTORY_A_SRV,
        DESC_HISTORY_A_UAV,
        DESC_HISTORY_B_SRV,
        DESC_HISTORY_B_UAV,
        DESC_TOTAL_COUNT
    };
    
    // 调试
    int m_debugMode = 0;  // 0=正常, 1=只显示反射, 2=显示置信度, 3=显示追踪距离
};

#endif // ENGINE_DX12_RENDERER
