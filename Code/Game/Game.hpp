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

	std::vector<Vertex_PCU> m_gridVertexes;
};




