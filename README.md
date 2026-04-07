# LuminaGI

**Real-Time Global Illumination Inspired by Unreal Engine 5 Lumen**

LuminaGI is a real-time global illumination system built on a custom C++/DirectX 12 engine ([Igloo Engine](https://github.com/CarlottaSeal/Igloo)). It achieves multi-bounce diffuse indirect lighting at interactive frame rates (1920x1080) using software ray tracing, no hardware ray tracing (DXR) required.

This project is my thesis work at SMU Guildhall.

<!-- Screenshots coming soon -->

## Key Features

- **Screen-Space Probe System**: 11-pass compute pipeline: 240x135 probe grid, 64 rays per probe (~2M rays/frame) sampled via joint BRDF + lighting PDF; temporal blend (α=0.05) + bilateral spatial filter weighted by depth and normal; SH2 (4 coefficients/channel) storage per probe
- **Surface Cache**: 4096x4096 texture atlas with 6 layers (albedo, normal, material, direct light, indirect light, combined), tile-based allocation with up to 4096 cards
- **Signed Distance Field Tracing**: Per-mesh SDF generation (64×64×64 cubic volume) with BVH acceleration; global SDF composition for coarse long-range tracing
- **Voxel Irradiance Volume**: World-space stable 3D irradiance grid, serving as fallback when mesh SDF misses
- **Surface Radiosity**: Multi-bounce indirect lighting via 1024x1024 probe grid on the surface cache atlas; L0-L2 SH (9 coefficients/channel) for higher-fidelity directional representation than screen probes; frame-persistent history for temporal coherence
- **Dynamic Point Lights**: Moving point light support with incremental dirty-card relighting, 128-bit per-card light masks, and distance-priority scheduling
- **Shadow System**: Directional shadow maps (2048x2048, PCF) + omnidirectional point light cube shadows (512x512 x 6 faces, up to 4 lights)
- **Instanced Indexed Drawing**: Frustum culling, sort-by-material batching, structured buffer instance data

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

## Screen Probe Pipeline

| Pass | Shader | Operation |
|------|--------|-----------|
| 1 | ProbePlacement | Reconstruct world position per 8×8 pixel cell |
| 2 | BRDFPDFGeneration | Cosine-weighted Lambertian distribution |
| 3 | LightingPDFGeneration | History reprojection from previous frame |
| 4 | GenerateSampleDirections | 64 rays/probe via joint BRDF + lighting PDF |
| 5 | MeshSDFTrace | Sphere trace per-mesh SDFs (0–100 units) |
| 6 | VoxelSDFTrace | Sphere trace global SDF (100–500 units) |
| 7 | RadianceComposite | Blend voxel + surface cache radiance at hit points |
| 8 | SpatialFilter | Bilateral filter weighted by depth and normal |
| 9 | OctIrradiance | Project per-probe radiance to SH2 (octahedral map) |
| 10 | FinalGather | 4-probe blend → per-pixel irradiance |
| 11 | ScreenSpaceTemporalFilter | Temporal blend (α=0.05) for stability |

## Surface Cache Layers

4096×4096 atlas, 6 layers per texel:

| Layer | Contents | Format |
|-------|----------|--------|
| 0 | Albedo | RGBA8 |
| 1 | World-Space Normal | RGBA16F |
| 2 | Material (roughness / metallic / AO) | RGBA8 |
| 3 | Direct Light | RGBA16F |
| 4 | Indirect Light (from radiosity) | RGBA16F |
| 5 | Combined Light | RGBA16F |

## Debug Visualization

19 real-time visualization modes toggled at runtime:

| Category | Modes |
|----------|-------|
| Geometry | GBuffer Albedo, Normal, Material, WorldPos, Depth |
| Surface Cache | Albedo, Normal, Direct Light, Indirect Light, Combined |
| GI Results | Probe Radiance, Probe AO, Radiosity Trace, Voxel Lighting |
| Shadows | Directional Shadow Map, Point Light Shadow |
| Diagnostics | SDF Normal, Direct-only, Indirect-only, Final Composite |

These modes were essential for validating each subsystem independently during development — e.g., isolating whether a lighting artifact originated in the surface cache, the probe pipeline, or the final gather.

## Rendering Pipeline

| Order | Pass | Type | Frequency |
|-------|------|------|-----------|
| 1 | Directional Shadow Map (2048x2048) | Rasterization | On sun change |
| 2 | Point Light Cube Shadow (512x512 x 24) | Rasterization | Every frame |
| 3 | GBuffer | Rasterization | Every frame |
| 4 | Card Capture (dirty cards only) | Rasterization | On geometry change |
| 5 | Direct Light Update | Compute | On light change |
| 6 | Combine Surface Cache | Compute | After update |
| 7-8 | Voxel Visibility + Lighting Injection | Compute | Periodic |
| 9 | Surface Radiosity (Trace + Filter + SH) | Compute | Every frame |
| 10 | Screen Probes (11 passes) | Compute | Every frame |
| 11 | Final Composite | Full-screen PS | Every frame |

## Scene Complexity

The test scene consists of a 6×4 grid of floor and ceiling tiles (38 instances of a 12,324-triangle stone tile mesh), 23 perimeter and interior wall segments (43,320 triangles each), and one 49,950-triangle character model: totaling approximately **1.5 million triangles** across **62 mesh instances**.

## Performance

Measured in windowed mode (~1728×864, 2:1 aspect at 90% of a 1080p desktop) on a desktop NVIDIA GPU:

| Component | GPU Time |
|-----------|----------|
| Screen Probe Pipeline (total) | ~5.3 ms |
| &nbsp;&nbsp;Mesh SDF Trace | 2.8 ms |
| &nbsp;&nbsp;Final Gather | 0.5 ms |
| &nbsp;&nbsp;Radiance Composite | 0.5 ms |
| Point Light Cube Shadows | 1.0-2.0 ms |
| Direct Light Update | 0.2-0.4 ms |

## Implementation Notes

**Importance Sampling**
Each screen probe samples 64 ray directions via a joint PDF combining a BRDF term (cosine-weighted Lambertian) and a lighting PDF derived from the SH-projected light distribution of the probe's surroundings. The two terms are weighted equally (0.5/0.5). This reduces variance compared to uniform hemisphere sampling without requiring hardware ray tracing.

**Bilateral Filtering**
The final gather cross-blends radiance from neighboring probes using a bilateral weight:
```
depth_weight  = exp(-plane_distance × 10.0)
normal_weight = pow(saturate(dot(n1, n2)), 4.0)
```
This preserves edges at depth discontinuities and surface orientation boundaries, preventing light bleeding between geometrically distinct surfaces.

**SH Resolution Trade-off**
Screen probes store SH2 (4 coefficients/channel, 3 channels = 12 floats/probe). Surface radiosity uses L0-L2 SH (9 coefficients/channel) on the surface cache atlas for higher directional fidelity on static geometry. The asymmetry is intentional: screen probes are recomputed every frame and prioritize bandwidth; surface radiosity accumulates over multiple frames and can afford the larger footprint.

**Dirty Card States**
Two dirty flags per card: geometry-dirty (object moved → full re-render of albedo/normal/material/direct light layers via rasterization) and lighting-dirty (light moved → compute-only direct light update, skipping rasterization entirely). Moving a point light suppresses full card recapture and routes through the compute path only.

**Firefly Clamping**
All pipeline stages clamp output luminance to 1/π (≈ 0.318), the physical maximum of the Lambertian BRDF. This prevents any stage from producing radiance above the diffuse surface limit, eliminating firefly artifacts without an arbitrary threshold.

**Codebase Scale**
- LuminaGI shaders: 33 HLSL files, ~7,000 lines
- Engine GI/Cache/SDF subsystems: ~6,000 lines C++
- Total engine: ~180,000 lines C++

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

## Known Limitations

- SDF representation cannot accurately capture thin geometry or highly concave surfaces
- Fixed probe density (one per 8×8 pixels) may undersample high-frequency lighting variation in small or detailed scenes
- Point light shadow maps are hard-limited to 4 simultaneous shadow-casting lights

## Inspired By

- [Lumen (Unreal Engine 5)](https://advances.realtimerendering.com/s2022/SIGGRAPH2022-Advances-Lumen-Wright%20et%20al.pdf): Wright, Narkowicz, Jimenez (SIGGRAPH 2022)
- [GI-1.0](https://gpuopen.com/download/publications/GPUOpen2022_GI1_0.pdf): Boisse (AMD GPUOpen, 2022)

## License

This project is part of a thesis at SMU Guildhall. All rights reserved.
