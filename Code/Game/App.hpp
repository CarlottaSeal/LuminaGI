#pragma once
#include "Engine/Math/Vec2.hpp"
#include "Engine/Renderer/Camera.hpp"
#include "Game/Game.hpp"
#include "Engine/Renderer/Renderer.hpp"
#include "Engine/Input/KeyButtonState.hpp"
#include "Engine/Input/InputSystem.hpp"
#include "Engine/Audio/AudioSystem.hpp"

class Game;

class App
{
public:
	App();
	~App();

	void Startup();
	void Shutdown();
	void RunFrame();

	bool IsQuitting() const { return g_isQuitting; }
	void HandleKeyPressed(unsigned char keyCode);
	void HandleKeyReleased(unsigned char keycode);
	void HandleQuitRequested();

	bool IsKeyDown(unsigned char keyCode) const;         
	bool WasKeyJustPressed(unsigned char keyCode) const; 
	bool IsKeyReleased(unsigned char keyCode) const;

	//void AttractModeUpdate(float deltaSeconds);
	//void AttractModeRender() const;

public:
	bool g_isQuitting = false;

private:
	void BeginFrame();
	void Update();
	void Render() const;
	void EndFrame();

	void UpdateCursor();
	
private:
	bool m_currentKeyStates[256] = { false }; 
	bool m_previousKeyStates[256] = { false };

	KeyButtonState m_keystates[NUM_KEYCODES];
};

bool OnQuitEvent(EventArgs& args);
