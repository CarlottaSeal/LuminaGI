#include "LuminaScene.h"

#include "Engine/Scene/Object/Mesh/MeshObject.h"
#include "Engine/Core/DebugRenderSystem.hpp"
#include "Engine/Renderer/Cache/SurfaceCard.h"

LuminaScene::LuminaScene(SceneConfig config)
    :Scene(config)
{
}

void LuminaScene::Render() const
{
    //Scene::Render();
    SetLightConstants();
    m_config.m_renderer->BindShader(nullptr);
    //m_config.m_renderer->BindTexture(nullptr);
    for (MeshObject* mesh : m_meshObjects)
    {
        m_config.m_renderer->SetMaterialConstants(mesh->GetMesh()->m_diffuseTexture, mesh->GetMesh()->m_normalTexture,
            mesh->GetMesh()->m_specularTexture);

        // for (SurfaceCard card : mesh->m_runtimeCards)
        // {
        //     DebugAddWorldPoint(card.m_worldOrigin, 0.1f, 0.f);
        // }
        m_config.m_renderer->SetModelConstants(mesh->GetWorldMatrix(), Rgba8::WHITE);
        m_config.m_renderer->DrawIndexBuffer(mesh->GetMesh()->m_vertexBuffer, mesh->GetMesh()->m_indexBuffer,
            (int)mesh->GetMesh()->m_indices.size());
    }
}
