#include "LuminaScene.h"
#include <algorithm>

#include "Engine/Scene/Object/Mesh/MeshObject.h"
#include "Engine/Core/DebugRenderSystem.hpp"
#include "Engine/Core/StaticMesh.h"
#include "Engine/Renderer/Cache/SurfaceCard.h"
#include "Engine/Math/Frustum.h"
#include "Engine/Renderer/DX12Renderer.hpp"

LuminaScene::LuminaScene(SceneConfig config)
    :Scene(config)
{
}

void LuminaScene::Render() const
{
    SetLightConstants();
    m_config.m_renderer->BindShader(nullptr);

#ifdef ENGINE_DX12_RENDERER
    Frustum frustum = GetRenderer()->GetCurrentCamera().GetFrustum();
    int culledCount = 0;

    // Phase 1: Frustum cull - collect visible objects
    std::vector<MeshObject*> visibleObjects;
    visibleObjects.reserve(m_meshObjects.size());
    for (MeshObject* mesh : m_meshObjects)
    {
        if (frustum.IsAABBOutside(mesh->GetWorldBounds()))
        {
            ++culledCount;
            continue;
        }
        visibleObjects.push_back(mesh);
    }

    // Phase 2: Sort by (mesh, material) to maximize batch sizes
    std::sort(visibleObjects.begin(), visibleObjects.end(),
        [](const MeshObject* a, const MeshObject* b)
        {
            if (a->GetMesh() != b->GetMesh())
                return a->GetMesh() < b->GetMesh();
            if (a->GetMesh()->m_diffuseTexture != b->GetMesh()->m_diffuseTexture)
                return a->GetMesh()->m_diffuseTexture < b->GetMesh()->m_diffuseTexture;
            return false;
        });

    // Phase 3: Upload all instance data
    m_config.m_renderer->ResetInstanceData();
    for (MeshObject* obj : visibleObjects)
        m_config.m_renderer->AppendInstanceData(obj->GetWorldMatrix(), Rgba8::WHITE);

    // Phase 4: Batched draw by (mesh, material)
    uint32_t i = 0;
    while (i < (uint32_t)visibleObjects.size())
    {
        StaticMesh* batchMesh = visibleObjects[i]->GetMesh();
        const Texture* batchDiff = batchMesh->m_diffuseTexture;
        const Texture* batchNorm = batchMesh->m_normalTexture;
        const Texture* batchSpec = batchMesh->m_specularTexture;

        uint32_t batchEnd = i + 1;
        while (batchEnd < (uint32_t)visibleObjects.size())
        {
            StaticMesh* cur = visibleObjects[batchEnd]->GetMesh();
            if (cur != batchMesh || cur->m_diffuseTexture != batchDiff ||
                cur->m_normalTexture != batchNorm || cur->m_specularTexture != batchSpec)
                break;
            ++batchEnd;
        }

        m_config.m_renderer->SetMaterialConstants(batchDiff, batchNorm, batchSpec);
        m_config.m_renderer->DrawIndexedInstancedBatch(
            batchMesh->m_vertexBuffer, batchMesh->m_indexBuffer,
            (int)batchMesh->m_indices.size(), i, batchEnd - i);

        i = batchEnd;
    }

    m_lastTotalCount = (int)m_meshObjects.size();
    m_lastCulledCount = culledCount;
#endif
}
