#pragma once
#include "Game/Gamecommon.hpp"
#include "Game/App.hpp"
#include "Engine/Renderer/Camera.hpp"
#include "Engine/Math/AABB2.hpp"
#include "Engine/Core/Vertex_PCU.hpp"
#include "Engine/Audio/AudioSystem.hpp"

#include <vector>

class Player;
class Clock;
class Entity;
class LightObject;

class Game 
{
public:
	Game();
	~Game();

	void Startup();
	void Update();
	void Render() const;

	void AdjustForPauseAndTimeDistortion();

public:
	bool m_openDevConsole = false;
	bool m_isInAttractMode;
	bool m_mouseFPS = false;
	Clock* m_gameClock;
	//Camera m_gameCamera;
	Camera m_screenCamera;

	Player* m_player;
	
private:
	void AttractModeUpdate();
	void AttractModeRender() const;
	//void UpdateCamera();  //move into m_player
	void PrintGameControlToDevConsole();
	void DrawSquareXYGrid(int unit = 100);
	void DebugRenderSystemInputUpdate();
	void DebugAddWorldAxisText(Mat44 worldMat);

private:
	bool m_isSlowMo;
	bool m_isUsingUserTimeScale;

	float m_userTimeScale;

	bool m_hasPlayedAttractSound = false;
	SoundPlaybackID m_attractSoundID = MISSING_SOUND_ID;


	float m_varyTime = 0.f;

	// Orbiting point light
	LightObject* m_orbitLight = nullptr;
	float m_orbitAngle = 0.f;
	Vec3 m_orbitCenter;
	float m_orbitRadius = 2.5f;

	// Card scan test ('T' to toggle)
	bool m_cardTestActive  = false;
	int  m_cardTestFrame   = 0;
	int  m_cardTestPrevIdx = 0;

	std::vector<Vertex_PCU> m_gridVertexes;
};




