//=============================================================================
// SimpleSSR.cpp
// 简化版 Screen Space Reflections 实现
//=============================================================================

#ifdef ENGINE_DX12_RENDERER

#include "SimpleSSR.h"
#include "Engine/Renderer/ConstantBuffer.hpp"
#include "Engine/Renderer/GI/GBufferData.h"
#include "Engine/Core/FileUtils.hpp"
#include "ThirdParty/d3dx12/d3dx12.h"

//-----------------------------------------------------------------------------
// 生命周期
//-----------------------------------------------------------------------------

SimpleSSR::~SimpleSSR()
{
    Shutdown();
}

void SimpleSSR::Initialize(
    ID3D12Device* device,
    ID3D12DescriptorHeap* descriptorHeap,
    uint32_t descriptorOffset,
    uint32_t screenWidth,
    uint32_t screenHeight)
{
    if (m_initialized)
        return;
    
    m_device = device;
    m_descriptorHeap = descriptorHeap;
    m_descriptorOffset = descriptorOffset;
    m_screenWidth = screenWidth;
    m_screenHeight = screenHeight;
    m_descriptorSize = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    
    CreateResources();
    CreateRootSignatures();
    CreatePipelineStates();
    
    m_initialized = true;
}

void SimpleSSR::Shutdown()
{
    // 释放资源
    if (m_hiZBuffer) { m_hiZBuffer->Release(); m_hiZBuffer = nullptr; }
    if (m_ssrTraceResult) { m_ssrTraceResult->Release(); m_ssrTraceResult = nullptr; }
    if (m_ssrFiltered) { m_ssrFiltered->Release(); m_ssrFiltered = nullptr; }
    if (m_reflectionOutput) { m_reflectionOutput->Release(); m_reflectionOutput = nullptr; }
    if (m_historyA) { m_historyA->Release(); m_historyA = nullptr; }
    if (m_historyB) { m_historyB->Release(); m_historyB = nullptr; }
    
    // 释放PSO
    if (m_pso_HiZGenerate) { m_pso_HiZGenerate->Release(); m_pso_HiZGenerate = nullptr; }
    if (m_pso_SSRTrace) { m_pso_SSRTrace->Release(); m_pso_SSRTrace = nullptr; }
    if (m_pso_SpatialFilter) { m_pso_SpatialFilter->Release(); m_pso_SpatialFilter = nullptr; }
    if (m_pso_TemporalAccum) { m_pso_TemporalAccum->Release(); m_pso_TemporalAccum = nullptr; }
    
    // 释放Root Signature
    if (m_hiZRootSignature) { m_hiZRootSignature->Release(); m_hiZRootSignature = nullptr; }
    if (m_ssrRootSignature) { m_ssrRootSignature->Release(); m_ssrRootSignature = nullptr; }
    
    m_initialized = false;
}

void SimpleSSR::Resize(uint32_t newWidth, uint32_t newHeight)
{
    if (newWidth == m_screenWidth && newHeight == m_screenHeight)
        return;
    
    m_screenWidth = newWidth;
    m_screenHeight = newHeight;
    
    // 重新创建大小相关的资源
    if (m_hiZBuffer) { m_hiZBuffer->Release(); m_hiZBuffer = nullptr; }
    if (m_ssrTraceResult) { m_ssrTraceResult->Release(); m_ssrTraceResult = nullptr; }
    if (m_ssrFiltered) { m_ssrFiltered->Release(); m_ssrFiltered = nullptr; }
    if (m_reflectionOutput) { m_reflectionOutput->Release(); m_reflectionOutput = nullptr; }
    if (m_historyA) { m_historyA->Release(); m_historyA = nullptr; }
    if (m_historyB) { m_historyB->Release(); m_historyB = nullptr; }
    
    CreateResources();
}

//-----------------------------------------------------------------------------
// 资源创建
//-----------------------------------------------------------------------------

void SimpleSSR::CreateResources()
{
    CreateHiZResources();
    CreateSSRResources();
}

void SimpleSSR::CreateHiZResources()
{
    // Hi-Z Buffer：带Mipmap的深度纹理
    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = m_screenWidth;
    desc.Height = m_screenHeight;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = SSRConfig::HIZ_MIP_COUNT;
    desc.Format = DXGI_FORMAT_R32_FLOAT;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    
    CD3DX12_HEAP_PROPERTIES heapProps(D3D12_HEAP_TYPE_DEFAULT);
    
    HRESULT hr = m_device->CreateCommittedResource(
        &heapProps,
        D3D12_HEAP_FLAG_NONE,
        &desc,
        D3D12_RESOURCE_STATE_COMMON,
        nullptr,
        IID_PPV_ARGS(&m_hiZBuffer)
    );
    
    if (SUCCEEDED(hr))
        m_hiZBuffer->SetName(L"SSR_HiZBuffer");
    
    // 创建SRV
    D3D12_SHADER_RESOURCE_VIEW_DESC srvDesc = {};
    srvDesc.Format = DXGI_FORMAT_R32_FLOAT;
    srvDesc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    srvDesc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    srvDesc.Texture2D.MipLevels = SSRConfig::HIZ_MIP_COUNT;
    
    m_device->CreateShaderResourceView(m_hiZBuffer, &srvDesc, GetCPUHandle(DESC_HIZ_SRV));
    
    // 为每个Mip创建UAV
    for (uint32_t mip = 0; mip < SSRConfig::HIZ_MIP_COUNT; ++mip)
    {
        D3D12_UNORDERED_ACCESS_VIEW_DESC uavDesc = {};
        uavDesc.Format = DXGI_FORMAT_R32_FLOAT;
        uavDesc.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
        uavDesc.Texture2D.MipSlice = mip;
        
        m_device->CreateUnorderedAccessView(m_hiZBuffer, nullptr, &uavDesc, GetCPUHandle(DESC_HIZ_UAV_BASE + mip));
    }
}

void SimpleSSR::CreateSSRResources()
{
    // SSR追踪结果
    CreateTexture2D(&m_ssrTraceResult, m_screenWidth, m_screenHeight,
        DXGI_FORMAT_R16G16B16A16_FLOAT,
        D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
        D3D12_RESOURCE_STATE_COMMON,
        L"SSR_TraceResult");
    
    // 滤波结果
    CreateTexture2D(&m_ssrFiltered, m_screenWidth, m_screenHeight,
        DXGI_FORMAT_R16G16B16A16_FLOAT,
        D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
        D3D12_RESOURCE_STATE_COMMON,
        L"SSR_Filtered");
    
    // 最终输出
    CreateTexture2D(&m_reflectionOutput, m_screenWidth, m_screenHeight,
        DXGI_FORMAT_R16G16B16A16_FLOAT,
        D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
        D3D12_RESOURCE_STATE_COMMON,
        L"SSR_Output");
    
    // 历史缓冲
    CreateTexture2D(&m_historyA, m_screenWidth, m_screenHeight,
        DXGI_FORMAT_R16G16B16A16_FLOAT,
        D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
        D3D12_RESOURCE_STATE_COMMON,
        L"SSR_HistoryA");
    
    CreateTexture2D(&m_historyB, m_screenWidth, m_screenHeight,
        DXGI_FORMAT_R16G16B16A16_FLOAT,
        D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
        D3D12_RESOURCE_STATE_COMMON,
        L"SSR_HistoryB");
    
    // 创建Views
    D3D12_SHADER_RESOURCE_VIEW_DESC srvDesc = {};
    srvDesc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    srvDesc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    srvDesc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    srvDesc.Texture2D.MipLevels = 1;
    
    D3D12_UNORDERED_ACCESS_VIEW_DESC uavDesc = {};
    uavDesc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    uavDesc.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
    uavDesc.Texture2D.MipSlice = 0;
    
    // Trace Result UAV
    m_device->CreateUnorderedAccessView(m_ssrTraceResult, nullptr, &uavDesc, GetCPUHandle(DESC_SSR_TRACE_UAV));
    
    // Filtered UAV
    m_device->CreateUnorderedAccessView(m_ssrFiltered, nullptr, &uavDesc, GetCPUHandle(DESC_SSR_FILTERED_UAV));
    
    // Output UAV
    m_device->CreateUnorderedAccessView(m_reflectionOutput, nullptr, &uavDesc, GetCPUHandle(DESC_OUTPUT_UAV));
    
    // History A SRV/UAV
    m_device->CreateShaderResourceView(m_historyA, &srvDesc, GetCPUHandle(DESC_HISTORY_A_SRV));
    m_device->CreateUnorderedAccessView(m_historyA, nullptr, &uavDesc, GetCPUHandle(DESC_HISTORY_A_UAV));
    
    // History B SRV/UAV
    m_device->CreateShaderResourceView(m_historyB, &srvDesc, GetCPUHandle(DESC_HISTORY_B_SRV));
    m_device->CreateUnorderedAccessView(m_historyB, nullptr, &uavDesc, GetCPUHandle(DESC_HISTORY_B_UAV));
}

void SimpleSSR::CreateTexture2D(
    ID3D12Resource** outResource,
    uint32_t width,
    uint32_t height,
    DXGI_FORMAT format,
    D3D12_RESOURCE_FLAGS flags,
    D3D12_RESOURCE_STATES initialState,
    const wchar_t* debugName)
{
    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = width;
    desc.Height = height;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.Format = format;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    desc.Flags = flags;
    
    CD3DX12_HEAP_PROPERTIES heapProps(D3D12_HEAP_TYPE_DEFAULT);
    
    HRESULT hr = m_device->CreateCommittedResource(
        &heapProps,
        D3D12_HEAP_FLAG_NONE,
        &desc,
        initialState,
        nullptr,
        IID_PPV_ARGS(outResource)
    );
    
    if (SUCCEEDED(hr) && debugName)
        (*outResource)->SetName(debugName);
}

//-----------------------------------------------------------------------------
// Root Signatures
//-----------------------------------------------------------------------------

void SimpleSSR::CreateRootSignatures()
{
    // Hi-Z Root Signature
    {
        CD3DX12_ROOT_PARAMETER rootParams[3] = {};
        
        // [0] Constants
        rootParams[0].InitAsConstants(sizeof(HiZConstants) / 4, 0);
        
        // [1] Source SRV (上一级Mip或深度)
        CD3DX12_DESCRIPTOR_RANGE srvRange;
        srvRange.Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 0);
        rootParams[1].InitAsDescriptorTable(1, &srvRange);
        
        // [2] Dest UAV
        CD3DX12_DESCRIPTOR_RANGE uavRange;
        uavRange.Init(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 1, 0);
        rootParams[2].InitAsDescriptorTable(1, &uavRange);
        
        // Sampler
        D3D12_STATIC_SAMPLER_DESC sampler = {};
        sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
        sampler.AddressU = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.AddressV = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.ShaderRegister = 0;
        sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        
        CD3DX12_ROOT_SIGNATURE_DESC desc;
        desc.Init(3, rootParams, 1, &sampler, D3D12_ROOT_SIGNATURE_FLAG_NONE);
        
        ID3DBlob* signature = nullptr;
        ID3DBlob* error = nullptr;
        D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &signature, &error);
        if (error) error->Release();
        
        m_device->CreateRootSignature(0, signature->GetBufferPointer(), signature->GetBufferSize(),
            IID_PPV_ARGS(&m_hiZRootSignature));
        signature->Release();
        
        m_hiZRootSignature->SetName(L"SSR_HiZ_RootSignature");
    }
    
    // SSR Root Signature
    {
        CD3DX12_ROOT_PARAMETER rootParams[5] = {};
        
        // [0] Constants CBV
        rootParams[0].InitAsConstantBufferView(0);
        
        // [1] GBuffer SRVs (Depth, Normal, WorldPos, Albedo)
        CD3DX12_DESCRIPTOR_RANGE srvRange1;
        srvRange1.Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 4, 0);
        rootParams[1].InitAsDescriptorTable(1, &srvRange1);
        
        // [2] Hi-Z + PrevFrame SRVs
        CD3DX12_DESCRIPTOR_RANGE srvRange2;
        srvRange2.Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 2, 4);
        rootParams[2].InitAsDescriptorTable(1, &srvRange2);
        
        // [3] History SRV
        CD3DX12_DESCRIPTOR_RANGE srvRange3;
        srvRange3.Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 6);
        rootParams[3].InitAsDescriptorTable(1, &srvRange3);
        
        // [4] Output UAVs
        CD3DX12_DESCRIPTOR_RANGE uavRange;
        uavRange.Init(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 3, 0);
        rootParams[4].InitAsDescriptorTable(1, &uavRange);
        
        // Samplers
        D3D12_STATIC_SAMPLER_DESC samplers[2] = {};
        
        // Point Sampler
        samplers[0].Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
        samplers[0].AddressU = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        samplers[0].AddressV = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        samplers[0].AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        samplers[0].ShaderRegister = 0;
        samplers[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        
        // Linear Sampler
        samplers[1].Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        samplers[1].AddressU = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        samplers[1].AddressV = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        samplers[1].AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        samplers[1].ShaderRegister = 1;
        samplers[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        
        CD3DX12_ROOT_SIGNATURE_DESC desc;
        desc.Init(5, rootParams, 2, samplers, D3D12_ROOT_SIGNATURE_FLAG_NONE);
        
        ID3DBlob* signature = nullptr;
        ID3DBlob* error = nullptr;
        D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &signature, &error);
        if (error) error->Release();
        
        m_device->CreateRootSignature(0, signature->GetBufferPointer(), signature->GetBufferSize(),
            IID_PPV_ARGS(&m_ssrRootSignature));
        signature->Release();
        
        m_ssrRootSignature->SetName(L"SSR_Main_RootSignature");
    }
}

//-----------------------------------------------------------------------------
// Pipeline States
//-----------------------------------------------------------------------------

void SimpleSSR::CreatePipelineStates()
{
    // 加载Shader
    // 注意：你需要根据自己的文件系统调整路径和加载方式
    
    auto CompileShader = [](const char* source, const char* entry, ID3DBlob** blob) -> bool
    {
        ID3DBlob* error = nullptr;
        HRESULT hr = D3DCompile(
            source, strlen(source),
            nullptr, nullptr, nullptr,
            entry, "cs_5_1",
            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0,
            blob, &error
        );
        if (error) error->Release();
        return SUCCEEDED(hr);
    };
    
    // Hi-Z Generate PSO
    {
        std::string source;
        if (FileReadToString(source, "Data/Shaders/SSR/HiZGenerate.hlsl"))
        {
            ID3DBlob* csBlob = nullptr;
            if (CompileShader(source.c_str(), "CSMain", &csBlob))
            {
                D3D12_COMPUTE_PIPELINE_STATE_DESC psoDesc = {};
                psoDesc.pRootSignature = m_hiZRootSignature;
                psoDesc.CS = { csBlob->GetBufferPointer(), csBlob->GetBufferSize() };
                
                m_device->CreateComputePipelineState(&psoDesc, IID_PPV_ARGS(&m_pso_HiZGenerate));
                m_pso_HiZGenerate->SetName(L"SSR_HiZGenerate_PSO");
                
                csBlob->Release();
            }
        }
    }
    
    // SSR Trace PSO
    {
        std::string source;
        if (FileReadToString(source, "Data/Shaders/SSR/SimpleSSR.hlsl"))
        {
            ID3DBlob* csBlob = nullptr;
            if (CompileShader(source.c_str(), "CSTrace", &csBlob))
            {
                D3D12_COMPUTE_PIPELINE_STATE_DESC psoDesc = {};
                psoDesc.pRootSignature = m_ssrRootSignature;
                psoDesc.CS = { csBlob->GetBufferPointer(), csBlob->GetBufferSize() };
                
                m_device->CreateComputePipelineState(&psoDesc, IID_PPV_ARGS(&m_pso_SSRTrace));
                m_pso_SSRTrace->SetName(L"SSR_Trace_PSO");
                
                csBlob->Release();
            }
        }
    }
    
    // Spatial Filter PSO
    {
        std::string source;
        if (FileReadToString(source, "Data/Shaders/SSR/SSRFilter.hlsl"))
        {
            ID3DBlob* csBlob = nullptr;
            if (CompileShader(source.c_str(), "CSSpatialFilter", &csBlob))
            {
                D3D12_COMPUTE_PIPELINE_STATE_DESC psoDesc = {};
                psoDesc.pRootSignature = m_ssrRootSignature;
                psoDesc.CS = { csBlob->GetBufferPointer(), csBlob->GetBufferSize() };
                
                m_device->CreateComputePipelineState(&psoDesc, IID_PPV_ARGS(&m_pso_SpatialFilter));
                m_pso_SpatialFilter->SetName(L"SSR_SpatialFilter_PSO");
                
                csBlob->Release();
            }
        }
    }
    
    // Temporal Accumulation PSO
    {
        std::string source;
        if (FileReadToString(source, "Data/Shaders/SSR/SSRFilter.hlsl"))
        {
            ID3DBlob* csBlob = nullptr;
            if (CompileShader(source.c_str(), "CSTemporalAccum", &csBlob))
            {
                D3D12_COMPUTE_PIPELINE_STATE_DESC psoDesc = {};
                psoDesc.pRootSignature = m_ssrRootSignature;
                psoDesc.CS = { csBlob->GetBufferPointer(), csBlob->GetBufferSize() };
                
                m_device->CreateComputePipelineState(&psoDesc, IID_PPV_ARGS(&m_pso_TemporalAccum));
                m_pso_TemporalAccum->SetName(L"SSR_TemporalAccum_PSO");
                
                csBlob->Release();
            }
        }
    }
}

//-----------------------------------------------------------------------------
// 执行
//-----------------------------------------------------------------------------

void SimpleSSR::Execute(
    ID3D12GraphicsCommandList* cmdList,
    ConstantBuffer* constantBuffer,
    const SSRConstants& constants,
    GBufferData* gBuffer,
    ID3D12Resource* prevFrameColor)
{
    if (!m_initialized)
        return;
    
    m_constantBuffer = constantBuffer;
    m_gBuffer = gBuffer;
    m_prevFrameColor = prevFrameColor;
    
    // Pass 1: 生成Hi-Z
    Pass_GenerateHiZ(cmdList, gBuffer->m_depthTexture);
    
    // Pass 2: SSR追踪
    Pass_SSRTrace(cmdList, constants);
    
    // Pass 3: 空间滤波
    Pass_SpatialFilter(cmdList);
    
    // Pass 4: 时间累积
    Pass_TemporalAccumulation(cmdList, constants);
    
    // 切换历史缓冲
    m_useHistoryB = !m_useHistoryB;
}

//-----------------------------------------------------------------------------
// Pass实现
//-----------------------------------------------------------------------------

void SimpleSSR::Pass_GenerateHiZ(ID3D12GraphicsCommandList* cmdList, ID3D12Resource* depthBuffer)
{
    cmdList->SetComputeRootSignature(m_hiZRootSignature);
    cmdList->SetPipelineState(m_pso_HiZGenerate);
    
    // 转换深度缓冲为SRV
    TransitionResource(cmdList, depthBuffer, D3D12_RESOURCE_STATE_DEPTH_WRITE, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    TransitionResource(cmdList, m_hiZBuffer, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    
    uint32_t srcWidth = m_screenWidth;
    uint32_t srcHeight = m_screenHeight;
    
    for (uint32_t mip = 0; mip < SSRConfig::HIZ_MIP_COUNT; ++mip)
    {
        uint32_t dstWidth = std::max(1u, srcWidth >> 1);
        uint32_t dstHeight = std::max(1u, srcHeight >> 1);
        
        HiZConstants hizConst = {};
        hizConst.SrcWidth = srcWidth;
        hizConst.SrcHeight = srcHeight;
        hizConst.DstWidth = dstWidth;
        hizConst.DstHeight = dstHeight;
        hizConst.MipLevel = mip;
        
        cmdList->SetComputeRoot32BitConstants(0, sizeof(HiZConstants) / 4, &hizConst, 0);
        
        // 第一级从深度缓冲读取，之后从上一级Hi-Z读取
        if (mip == 0)
        {
            // 绑定深度SRV（需要在外部创建）
            // cmdList->SetComputeRootDescriptorTable(1, depthSRV_GPU_Handle);
        }
        else
        {
            // 绑定上一级Hi-Z
            cmdList->SetComputeRootDescriptorTable(1, GetGPUHandle(DESC_HIZ_SRV));
        }
        
        cmdList->SetComputeRootDescriptorTable(2, GetGPUHandle(DESC_HIZ_UAV_BASE + mip));
        
        uint32_t groupsX = (dstWidth + 7) / 8;
        uint32_t groupsY = (dstHeight + 7) / 8;
        cmdList->Dispatch(groupsX, groupsY, 1);
        
        // 插入UAV屏障
        D3D12_RESOURCE_BARRIER barrier = CD3DX12_RESOURCE_BARRIER::UAV(m_hiZBuffer);
        cmdList->ResourceBarrier(1, &barrier);
        
        srcWidth = dstWidth;
        srcHeight = dstHeight;
    }
    
    // 转换回读取状态
    TransitionResource(cmdList, m_hiZBuffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    TransitionResource(cmdList, depthBuffer, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_DEPTH_WRITE);
}

void SimpleSSR::Pass_SSRTrace(ID3D12GraphicsCommandList* cmdList, const SSRConstants& constants)
{
    cmdList->SetComputeRootSignature(m_ssrRootSignature);
    cmdList->SetPipelineState(m_pso_SSRTrace);
    
    // 上传常量
    m_constantBuffer->AppendData(&constants, sizeof(SSRConstants), 0);
    cmdList->SetComputeRootConstantBufferView(0, m_constantBuffer->GetGPUVirtualAddress());
    
    // 绑定GBuffer SRVs（需要根据你的实际布局调整）
    // cmdList->SetComputeRootDescriptorTable(1, gBufferSRV_Table);
    
    // 绑定Hi-Z + PrevFrame
    // cmdList->SetComputeRootDescriptorTable(2, hiZ_prevFrame_Table);
    
    // 绑定输出
    TransitionResource(cmdList, m_ssrTraceResult, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    cmdList->SetComputeRootDescriptorTable(4, GetGPUHandle(DESC_SSR_TRACE_UAV));
    
    uint32_t groupsX = (m_screenWidth + 7) / 8;
    uint32_t groupsY = (m_screenHeight + 7) / 8;
    cmdList->Dispatch(groupsX, groupsY, 1);
}

void SimpleSSR::Pass_SpatialFilter(ID3D12GraphicsCommandList* cmdList)
{
    cmdList->SetPipelineState(m_pso_SpatialFilter);
    
    TransitionResource(cmdList, m_ssrTraceResult, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    TransitionResource(cmdList, m_ssrFiltered, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    
    cmdList->SetComputeRootDescriptorTable(4, GetGPUHandle(DESC_SSR_FILTERED_UAV));
    
    uint32_t groupsX = (m_screenWidth + 7) / 8;
    uint32_t groupsY = (m_screenHeight + 7) / 8;
    cmdList->Dispatch(groupsX, groupsY, 1);
}

void SimpleSSR::Pass_TemporalAccumulation(ID3D12GraphicsCommandList* cmdList, const SSRConstants& constants)
{
    cmdList->SetPipelineState(m_pso_TemporalAccum);
    
    TransitionResource(cmdList, m_ssrFiltered, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    TransitionResource(cmdList, m_reflectionOutput, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    
    // 绑定历史
    ID3D12Resource* historyRead = m_useHistoryB ? m_historyB : m_historyA;
    ID3D12Resource* historyWrite = m_useHistoryB ? m_historyA : m_historyB;
    
    TransitionResource(cmdList, historyRead, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    TransitionResource(cmdList, historyWrite, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    
    uint32_t historySRV = m_useHistoryB ? DESC_HISTORY_B_SRV : DESC_HISTORY_A_SRV;
    cmdList->SetComputeRootDescriptorTable(3, GetGPUHandle(historySRV));
    cmdList->SetComputeRootDescriptorTable(4, GetGPUHandle(DESC_OUTPUT_UAV));
    
    uint32_t groupsX = (m_screenWidth + 7) / 8;
    uint32_t groupsY = (m_screenHeight + 7) / 8;
    cmdList->Dispatch(groupsX, groupsY, 1);
    
    // 转换回常规状态
    TransitionResource(cmdList, m_reflectionOutput, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COMMON);
    TransitionResource(cmdList, historyWrite, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COMMON);
}

//-----------------------------------------------------------------------------
// 辅助函数
//-----------------------------------------------------------------------------

void SimpleSSR::TransitionResource(
    ID3D12GraphicsCommandList* cmdList,
    ID3D12Resource* resource,
    D3D12_RESOURCE_STATES before,
    D3D12_RESOURCE_STATES after)
{
    if (before == after)
        return;
    
    D3D12_RESOURCE_BARRIER barrier = CD3DX12_RESOURCE_BARRIER::Transition(resource, before, after);
    cmdList->ResourceBarrier(1, &barrier);
}

D3D12_CPU_DESCRIPTOR_HANDLE SimpleSSR::GetCPUHandle(uint32_t offset)
{
    CD3DX12_CPU_DESCRIPTOR_HANDLE handle(m_descriptorHeap->GetCPUDescriptorHandleForHeapStart());
    handle.Offset(m_descriptorOffset + offset, m_descriptorSize);
    return handle;
}

D3D12_GPU_DESCRIPTOR_HANDLE SimpleSSR::GetGPUHandle(uint32_t offset)
{
    CD3DX12_GPU_DESCRIPTOR_HANDLE handle(m_descriptorHeap->GetGPUDescriptorHandleForHeapStart());
    handle.Offset(m_descriptorOffset + offset, m_descriptorSize);
    return handle;
}

#endif // ENGINE_DX12_RENDERER
