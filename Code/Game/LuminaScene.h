#pragma once
#include "App.hpp"
#include "Engine/Scene/Scene.h"

class LuminaScene : public Scene
{
public:
    LuminaScene(SceneConfig config);

    virtual void Render() const override;
};
