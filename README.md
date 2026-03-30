# LuminaGI

**Real-Time Global Illumination Inspired by Unreal Engine 5 Lumen**

LuminaGI is a real-time global illumination system built on a custom C++/DirectX 12 engine ([Igloo Engine](https://github.com/CarlottaSeal/Igloo)). It achieves multi-bounce diffuse indirect lighting at interactive frame rates (1920x1080) using software ray tracing -- no hardware ray tracing (DXR) required.

This project is a thesis work at SMU Guildhall.

<!-- If you have screenshots, uncomment and update the path below:
![LuminaGI Demo](docs/screenshots/demo.png)
-->

## Key Features

- **Screen-Space Probe System** -- 11-pass compute pipeline: 240x135 probe grid, 64 importance-sampled rays per probe (~2M rays/frame), with temporal and spatial filtering
- **Surface Cache** -- 4096x4096 texture atlas with 6 layers (albedo, normal, material, direct light, indirect light, combined), tile-based allocation with up to 4096 cards
- **Signed Distance Field Tracing** -- Per-mesh SDF generation (64-128 voxel resolution) with BVH acceleration; global SDF composition for coarse long-range tracing
- **Voxel Irradiance Volume** -- World-space stable 3D irradiance grid, serving as fallback when mesh SDF misses
- **Surface Radiosity** -- Multi-bounce indirect lighting via probe grid ray tracing with spherical harmonics integration
- **Dynamic Point Lights** -- Moving point light support with incremental dirty-card relighting, 128-bit per-card light masks, and distance-priority scheduling
- **Shadow System** -- Directional shadow maps (2048x2048, PCF) + omnidirectional point light cube shadows (1024x1024 x 6 faces, up to 4 lights)
- **Instanced Indexed Drawing** -- Frustum culling, sort-by-material batching, structured buffer instance data

## Architecture

```
LuminaGI
├── Code/Game/
│   ├── App.cpp / Game.cpp        # Application entry, subsystem init
│   ├── LuminaScene.cpp           # Scene setup, light config, rendering
│   └── Player.cpp / Statue.cpp   # Camera control, scene objects
│
└── Run/Data/Shaders/
    ├── ScreenProbe/              # 11-pass screen probe pipeline
    │   ├── ProbePlacement.hlsl
    │   ├── BRDFPDFGeneration.hlsl
    │   ├── LightingPDFGeneration.hlsl
    │   ├── GenerateSampleDirections.hlsl
    │   ├── MeshSDFTrace.hlsl
    │   ├── VoxelSDFTrace.hlsl
    │   ├── RadianceComposite.hlsl
    │   ├── SpatialFilter.hlsl
    │   ├── OctIrradiance.hlsl
    │   ├── FinalGather.hlsl
    │   └── ScreenSpaceTemporalFilter.hlsl
    ├── SurfaceRadiosity/         # Multi-bounce radiosity
    ├── DirectLightUpdate.hlsl    # Per-card point light evaluation
    ├── CardCapture.hlsl          # Surface cache capture
    ├── SDFGeneration.hlsl        # Mesh SDF baking
    ├── BuildGlobalSDF.hlsl       # Global SDF composition
    ├── InjectVoxelLighting.hlsl  # Voxel irradiance injection
    ├── PointLightShadow.hlsl     # Cube shadow map rendering
    └── Shadow.hlsl               # Directional shadow pass
```

The GI system is implemented in the [Igloo Engine](https://github.com/CarlottaSeal/Igloo) under `Engine/Renderer/GI/`, `Engine/Renderer/Cache/`, and `Engine/Scene/SDF/`.

## Rendering Pipeline

| Order | Pass | Type | Frequency |
|-------|------|------|-----------|
| 1 | Directional Shadow Map (2048x2048) | Rasterization | On sun change |
| 2 | Point Light Cube Shadow (1024x1024 x 24) | Rasterization | Every frame |
| 3 | GBuffer | Rasterization | Every frame |
| 4 | Card Capture (dirty cards only) | Rasterization | On geometry change |
| 5 | Direct Light Update | Compute | On light change |
| 6 | Combine Surface Cache | Compute | After update |
| 7-8 | Voxel Visibility + Lighting Injection | Compute | Periodic |
| 9 | Surface Radiosity (Trace + Filter + SH) | Compute | Every frame |
| 10 | Screen Probes (11 passes) | Compute | Every frame |
| 11 | Final Composite | Full-screen PS | Every frame |

## Performance

Measured at 1920x1080 on a desktop NVIDIA GPU:

| Component | GPU Time |
|-----------|----------|
| Screen Probe Pipeline (total) | ~5.3 ms |
| -- Mesh SDF Trace | 2.8 ms |
| -- Final Gather | 0.5 ms |
| -- Radiance Composite | 0.5 ms |
| Point Light Cube Shadows | 1.0-2.0 ms |
| Direct Light Update | 0.2-0.4 ms |

## Build Requirements

- **OS**: Windows 10/11
- **IDE**: Visual Studio 2022
- **Graphics API**: DirectX 12 (Feature Level 12_0)
- **GPU**: Any DX12-capable GPU (no DXR required)
- **Dependencies**: [Igloo Engine](https://github.com/CarlottaSeal/Igloo) (sibling directory expected at `../Engine`)

### Build Steps

1. Clone both repositories as siblings:
   ```
   git clone https://github.com/CarlottaSeal/Igloo.git Engine
   git clone https://github.com/CarlottaSeal/LuminaGI.git LuminaGI
   ```
2. Open `LuminaGI/LuminaGI.sln` in Visual Studio 2022
3. Build in **Release** or **Debug** configuration (x64)
4. Run from the `Run/` directory

## Inspired By

- [Lumen (Unreal Engine 5)](https://advances.realtimerendering.com/s2022/SIGGRAPH2022-Advances-Lumen-Wright%20et%20al.pdf) -- Wright, Narkowicz, Jimenez (SIGGRAPH 2022)
- [GI-1.0](https://gpuopen.com/download/publications/GPUOpen2022_GI1_0.pdf) -- Boisse (AMD GPUOpen, 2022)
- [SimLumen](https://github.com/jiawei-gao/SimLumen) -- Educational Lumen reference implementation

## License

This project is part of a thesis at SMU Guildhall. All rights reserved.
