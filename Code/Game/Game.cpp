#include "Game.hpp"

#include "LuminaScene.h"
#include "Engine/Math/RandomNumberGenerator.hpp"
#include "Engine/Math/AABB2.hpp"
#include "Engine/Math/AABB3.hpp"
#include "Engine/Math/Mat44.hpp"
#include "Engine/Math/MathUtils.hpp"
#include "Engine/Core/ErrorWarningAssert.hpp"
#include "Engine/Core/Rgba8.hpp"
#include "Engine/Core/VertexUtils.hpp"
#include "Engine/Core/Clock.hpp"
#include "Engine/Core/DebugRenderSystem.hpp"
#include "Engine/Renderer/BitmapFont.hpp"
#include "Engine/Renderer/Camera.hpp"
#include "Engine/Audio/AudioSystem.hpp"
#include "Engine/Scene/Scene.h"

#ifdef ENGINE_DX12_RENDERER
#include "Engine/Renderer/DX12Renderer.hpp"
#endif

#include "Game/Player.hpp"
#include "Game/Gamecommon.hpp"

//extern AudioSystem* g_theAudio;
extern Clock* s_theSystemClock;
extern GISystem* g_theGISystem;
extern Scene* g_theScene;
RandomNumberGenerator g_RNG;

Game::Game()
{
	m_isInAttractMode = false;
	m_screenCamera.SetOrthographicView(Vec2(0.f, 0.f), Vec2(1600.f, 800.f));
	//m_gameCamera.SetOrthographicView(Vec2(-1.0f, -1.0f), Vec2(1.0f, 1.0f));

	m_player = new Player(this);

	m_player->m_worldCamera.SetCameraMode(Camera::CameraMode::eMode_Perspective);
	m_player->m_worldCamera.SetPerspectiveView(2.f, 60.f, 0.1f, 300.f);
	Mat44 mat;
	mat.SetIJK3D(Vec3(0.f, 0.f,1.f), Vec3(-1.f, 0.f, 0.f), Vec3(0.f, 1.f, 0.f));
	((Player*)m_player)->m_worldCamera.SetCameraToRenderTransform(mat);

	PrintGameControlToDevConsole();
	DrawSquareXYGrid(100);

	DebugAddWorldBasis(mat, -1.f, DebugRenderMode::USE_DEPTH);
	DebugAddWorldAxisText(mat);
}

Game::~Game()
{
	delete m_player;
	m_player = nullptr;

}

void Game::Startup()
{
	SceneConfig sceneConfig;
	sceneConfig.m_renderer = g_theRenderer;
	sceneConfig.m_giSystem = g_theGISystem;
	LuminaScene* scene = new LuminaScene(sceneConfig);

	g_theScene = scene;
	g_theGISystem->SetScene(g_theScene);

	// ===== Chess Scene (commented out) =====
	/*
	g_theScene->CreateLightEntity("SunLight", LIGHT_DIRECTIONAL, Vec3(), Rgba8(180,180,220, 210), Vec3(1.f, -1.f, -1.f));

	g_theScene->CreateLightEntity("PointLight1", LIGHT_POINT, Vec3(7.f, 0.f, 1.2f),
		Rgba8::WHITE, Vec3(), Rgba8(255, 200, 150, 200), 0.f,
		Vec3(), 0.5f, 4.f, 0.f, 0.f);
	g_theScene->CreateLightEntity("PointLight2", LIGHT_POINT, Vec3(4.f, -2.f, 1.2f),
		Rgba8::WHITE, Vec3(), Rgba8(255, 200, 150, 200), 0.f,
		Vec3(), 0.5f, 4.f, 0.f, 0.f);

	DebugAddWorldQuad(Vec3(-10.f, -10.f, 0.f), Vec3(20.f, -10.f, 0.f), Vec3(20.f, 10.f, 0.f), Vec3(-10.f, 10.f, 0.f), -1.f, Rgba8(60, 60, 60));

	g_theScene->CreateMeshEntity("Data/Models/LewisSet/Bishop_black", "BishopBlack", Vec3(10.f, 0.5f, 0.1f), EulerAngles(180.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/LewisSet/King_white", "KingWhite", Vec3(5.f, -0.5f, 0.1f), EulerAngles(180.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/LewisSet/Bishop_black", "BishopBlack", Vec3(4.f, 3.f, 0.1f), EulerAngles(304.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/LewisSet/King_white", "KingWhite", Vec3(8.f, -3.f, 0.1f), EulerAngles(124.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/LewisSet/Bishop_black", "BishopBlack", Vec3(9.f, 2.5f, 0.1f), EulerAngles(220.f, 0.f, 0.f));

	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(10.f, 0.f, 1.8f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(8.f, 0.f, 1.8f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(6.f, 0.f, 1.8f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(10.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(8.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(6.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(4.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(2.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(10.f, -4.f, 1.8f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 8.f, -4.f, 1.8f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 6.f, -4.f, 1.8f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(10.f, 4.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 8.f, 4.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 6.f, 4.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 4.f, 4.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 2.f, 4.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(10.f, -4.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 8.f, -4.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 6.f, -4.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 4.f, -4.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 2.f, -4.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(10.f, -2.f, 1.8f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 8.f, -2.f, 1.8f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 6.f, -2.f, 1.8f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(4.f, -2.f, 1.8f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 2.f, -2.f, 1.8f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(10.f, 2.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 8.f, 2.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 6.f, 2.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 4.f, 2.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 2.f, 2.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(10.f, -2.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 8.f, -2.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 6.f, -2.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 4.f, -2.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3( 2.f, -2.f, 0.f));

	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(5.f, -1.2f, 0.f), EulerAngles(90.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(8.f, -1.2f, 0.f), EulerAngles(90.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(5.f, 1.1f, 0.f), EulerAngles(90.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(9.f, 1.1f, 0.f), EulerAngles(90.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(10.5f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(5.5f, -1.5f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(7.f, -3.5f, 0.f), EulerAngles(90.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(9.f, 3.5f, 0.f), EulerAngles(230.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(6.f, 4.5f, 0.f), EulerAngles(270.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(6.f, -4.5f, 0.f), EulerAngles(90.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(9.f, -3.5f, 0.f), EulerAngles(130.f, 0.f, 0.f));

	g_theScene->CreateMeshEntity("Data/Models/lucy", "lucy", Vec3(6.5f, 0.f, 0.f), EulerAngles(-90.f, 0.f, 0.f));
	*/

	// ===== Indoor Room Scene =====
	// Room area: x=[3,14], y=[-3.5,3.5], floor z=0, ceiling z=1.8
	g_theScene->CreateLightEntity("SunLight", LIGHT_DIRECTIONAL, Vec3(), Rgba8(180,180,220, 210), Vec3(1.f, -1.f, -1.f));
	// Two point lights — one on each side of the protruding partition wall at x~8.5
	g_theScene->CreateLightEntity("RoomLightLeft", LIGHT_POINT, Vec3(11.f, -0.5f, 1.4f),
		Rgba8::WHITE, Vec3(), Rgba8(255, 255, 255, 200), 0.f,
		Vec3(), 0.5f, 4.f, 0.f, 0.f);
	m_orbitLight = g_theScene->CreateLightEntity("RoomLightRight", LIGHT_POINT, Vec3(11.f, 0.f, 1.2f),
		Rgba8::WHITE, Vec3(), Rgba8(255, 200, 150, 200), 0.f,
		Vec3(), 0.5f, 4.f, 0.f, 0.f);
	m_orbitCenter = Vec3(8.5f, 0.f, 1.2f);
	m_orbitRadius = 2.5f;

	DebugAddWorldQuad(Vec3(-10.f, -10.f, 0.f), Vec3(20.f, -10.f, 0.f), Vec3(20.f, 10.f, 0.f), Vec3(-10.f, 10.f, 0.f), -1.f, Rgba8(60, 60, 60));

	// Floor (z=0) — 6x4 grid of 2x2 tiles, x={3,5,7,9,11,13}, y={-3,-1,1,3}
	float floorXs[] = { 3.f, 5.f, 7.f, 9.f, 11.f, 13.f };
	float floorYs[] = { -3.f, -1.f, 1.f, 3.f };
	for (float fx : floorXs)
		for (float fy : floorYs)
			g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(fx, fy, 0.f));

	// Ceiling (z=1.8) — same 6x4 grid
	for (float fx : floorXs)
		for (float fy : floorYs)
			g_theScene->CreateMeshEntity("Data/Models/Building/Stone_floor", "Stone_floor", Vec3(fx, fy, 1.8f));

	// Perimeter walls
	// East wall (x~14, yaw=0): extends along Y by default
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(14.f, -1.75f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(14.f,  1.75f, 0.f));
	// West wall (x~3, yaw=0)
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(3.f, -1.75f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(3.f,  1.75f, 0.f));
	// North wall (y~3.5, yaw=90): 3 pieces spanning x=3..14
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(4.75f,  3.5f, 0.f), EulerAngles(90.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(8.25f,  3.5f, 0.f), EulerAngles(90.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(11.75f, 3.5f, 0.f), EulerAngles(90.f, 0.f, 0.f));
	// South wall (y~-3.5, yaw=90): 3 pieces
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(4.75f,  -3.5f, 0.f), EulerAngles(90.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(8.25f,  -3.5f, 0.f), EulerAngles(90.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(11.75f, -3.5f, 0.f), EulerAngles(90.f, 0.f, 0.f));

	// Bishops — one on each side of the partition wall, near the side walls
	g_theScene->CreateMeshEntity("Data/Models/LewisSet/Bishop_black", "BishopBlack", Vec3(5.5f, 2.5f, 0.1f), EulerAngles(180.f, 0.f, 0.f));
	g_theScene->CreateMeshEntity("Data/Models/LewisSet/Bishop_white", "BishopWhite", Vec3(11.f, -2.5f, 0.1f), EulerAngles(180.f, 0.f, 0.f));
	//g_theScene->CreateMeshEntity("Data/Models/lucy", "lucy", Vec3(12.f, 1.5f, 0.f), EulerAngles(-90.f, 0.f, 0.f));

	// Interior: protruding wall from north wall at x~8.5, extending south (yaw=0)
	// Both faces lit by left light (5.5,0) and right light (11,0)
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(8.5f, 1.75f, 0.f));
	// Perpendicular cap at the south tip (yaw=90, extends along X) — gives the wall thickness
	g_theScene->CreateMeshEntity("Data/Models/Building/Floor02_wall", "Floor02_wall", Vec3(8.5f, 0.f, 0.f), EulerAngles(90.f, 0.f, 0.f));

	g_theScene->InitializeBoundsAndMeshSDF();
	g_theScene->UpdateCardMetadata();
}

void Game::Update()
{
	if (g_theApp->WasKeyJustPressed(KEYCODE_ESC)
		|| g_theInput->GetController(0).WasButtonJustPressed(XboxButtonID::X))
	{
		if (m_isInAttractMode)
		{
			g_theApp->g_isQuitting = true;
		}
		if (!m_isInAttractMode)
		{
			m_isInAttractMode = true;
			m_mouseFPS = false;
		}
	}

	AdjustForPauseAndTimeDistortion();

	if (m_isInAttractMode)
	{
		AttractModeUpdate();

		if (!m_hasPlayedAttractSound)
		{
			//SoundID Attract = g_theAudio->CreateOrGetSound("Data/Audio/Attract.MP3");
			//m_attractSoundID = g_theAudio->StartSound(Attract, false, 1.0f, 0.5f, 1.0f, false);
			m_hasPlayedAttractSound = true;
		}
	}

	if (!m_isInAttractMode)
	{
		m_player->Update((float)s_theSystemClock->GetDeltaSeconds());

		// Orbiting point light — smooth every-frame update
		if (m_orbitLight)
		{
			m_orbitAngle += 0.5f * (float)s_theSystemClock->GetDeltaSeconds();
			if (m_orbitAngle > 2.0f * 3.14159f)
				m_orbitAngle -= 2.0f * 3.14159f;

			Vec3 newPos = Vec3(
				m_orbitCenter.x + m_orbitRadius * cosf(m_orbitAngle),
				m_orbitCenter.y + m_orbitRadius * sinf(m_orbitAngle),
				m_orbitCenter.z
			);
			m_orbitLight->SetPosition(newPos);
		}

		g_theScene->Update((float)s_theSystemClock->GetDeltaSeconds());
		DebugRenderSystemInputUpdate();
	}

	if (g_theDevConsole->GetMode() == OPEN_FULL)
	{
		m_openDevConsole = true;
	}
	if (g_theDevConsole->GetMode() == HIDDEN)
	{
		m_openDevConsole = false;
	}

	// GI Visualization 控制 (V键)
#ifdef ENGINE_DX12_RENDERER
	if (g_theApp->WasKeyJustPressed('V'))
	{
		DX12Renderer* dx12Renderer = g_theRenderer->GetSubRenderer();
		if (dx12Renderer)
		{
			dx12Renderer->ToggleGIVisualization();
			DebuggerPrintf("[GIViz] %s\n", dx12Renderer->IsGIVisualizationEnabled() ? "Enabled" : "Disabled");
		}
		m_mouseFPS = true;
	}
#endif

	if (g_theApp->WasKeyJustPressed('M'))
	{
		m_mouseFPS = !m_mouseFPS;
	}

	m_varyTime += (float)m_gameClock->GetDeltaSeconds();
	if (m_varyTime > 360.f)
	{
		m_varyTime = 0.f;
	}
}

void Game::Render() const
{
	if (m_isInAttractMode)
	{
 		g_theRenderer->SetRenderMode(RenderMode::FORWARD); 
		g_theRenderer->ClearScreen();
		g_theRenderer->SetDepthMode(DepthMode::DISABLED);
		g_theRenderer->BeginCamera(m_screenCamera);
		g_theRenderer->BindShader(nullptr);
		g_theRenderer->SetMaterialConstants(nullptr);
		g_theRenderer->SetBlendMode(BlendMode::ALPHA);
		g_theRenderer->SetRasterizerMode(RasterizerMode::SOLID_CULL_NONE);
		AttractModeRender();
		g_theRenderer->EndCamera(m_screenCamera);
	}

	if (!m_isInAttractMode)// && !IsInSelectInterface)
	{
		g_theRenderer->SetRenderMode(RenderMode::GI);
		g_theRenderer->ClearScreen(Rgba8(0, 0, 0, 0));
		g_theRenderer->BeginCamera(((Player*)m_player)->m_worldCamera);
		g_theRenderer->SetBlendMode(BlendMode::ALPHA);
		g_theRenderer->SetRasterizerMode(RasterizerMode::SOLID_CULL_BACK);
		g_theRenderer->SetDepthMode(DepthMode::READ_WRITE_LESS_EQUAL);
		g_theRenderer->SetSamplerMode(SamplerMode::POINT_CLAMP);
		g_theScene->Render();
		/*g_theRenderer->SetRenderMode(RenderMode::FORWARD);
		g_theRenderer->BindShader(nullptr);
		g_theRenderer->SetMaterialConstants(nullptr);
		g_theRenderer->SetModelConstants();
		g_theRenderer->DrawVertexArray(m_gridVertexes);*/
		g_theRenderer->EndCamera(((Player*)m_player)->m_worldCamera);

		// ImGui panel runs BEFORE DebugRenderWorld so that per-frame debug points
		// (e.g. point light indicators) are added in time to be drawn.
#ifdef ENGINE_DX12_RENDERER
		DX12Renderer* dx12Renderer = g_theRenderer->GetSubRenderer();
		if (dx12Renderer)
		{
			dx12Renderer->RenderGIVisualizationImGuiPanel();
		}
#endif

		DebugRenderWorld(((Player*)m_player)->m_worldCamera);
		DebugRenderScreen(m_screenCamera);
	}

	g_theDevConsole->Render(AABB2(m_screenCamera.GetOrthographicBottomLeft(), m_screenCamera.GetOrthographicTopRight()), g_theRenderer);
}

void Game::AdjustForPauseAndTimeDistortion()
{
	if (g_theApp->WasKeyJustPressed('T'))
	{
		m_isSlowMo = !m_isSlowMo;
		m_isUsingUserTimeScale = false;
	}
	if (m_isUsingUserTimeScale) // 如果用户通过 set_time_scale 设定了时间缩放，保持该值
	{
		m_gameClock->SetTimeScale(m_userTimeScale);
	}
	else
	{
		m_gameClock->SetTimeScale(m_isSlowMo ? 0.1f : 1.0f);
	}

	if (g_theApp->WasKeyJustPressed('P'))
	{
		m_gameClock->TogglePause();
		if (!m_gameClock->IsPaused())
		{
			m_gameClock->Unpause();
			m_gameClock->Reset();
			//SoundID Pause = g_theAudio->CreateOrGetSound("Data/Audio/Pause.mp3");
			//g_theAudio->StartSound(Pause, false, 0.05f, 0.5f, 1.f, false);
		}
		if (m_gameClock->IsPaused())
		{
			m_gameClock->Reset();
			//SoundID Unpause = g_theAudio->CreateOrGetSound("Data/Audio/Unpause.mp3");
			//g_theAudio->StartSound(Unpause, false, 0.05f, 0.5f, 1.f, false);
		}
	}

	if (g_theApp->WasKeyJustPressed('O'))
	{
		m_gameClock->StepSingleFrame();
	}
}

void Game::AttractModeUpdate()
{
	if (g_theApp->IsKeyDown(' ') ||
		g_theApp->IsKeyDown('N') ||
		g_theInput->GetController(0).WasButtonJustPressed(XboxButtonID::START) ||
		g_theInput->GetController(0).WasButtonJustPressed(XboxButtonID::A))
	{
		m_isInAttractMode = false;
		m_mouseFPS = true;
	}
}

void Game::AttractModeRender() const
{
	//DebugDrawRing(Vec2(800.f, 400.f), 100.f, 10.f + sinf(m_varyTime) * 10.f, Rgba8::YELLOW);
}

void Game::PrintGameControlToDevConsole()
{
	g_theDevConsole->AddLine(Rgba8::BLUE, "Type help for a list of commands");
	g_theDevConsole->AddLine(Rgba8::CYAN, "Mouse x-axis Right stick x-axis Yaw");
	g_theDevConsole->AddLine(Rgba8::CYAN, "Mouse y-axis Right stick y-axis Pitch");
	g_theDevConsole->AddLine(Rgba8::CYAN, "Q / E Left trigger / right trigger Roll");
	g_theDevConsole->AddLine(Rgba8::CYAN, "A / D Left stick x-axis Move left or right");
	g_theDevConsole->AddLine(Rgba8::CYAN, "W / S Left stick y-axis Move forward or back");
	g_theDevConsole->AddLine(Rgba8::CYAN, "Z / C Left shoulder / right shoulder Move down or up");
	g_theDevConsole->AddLine(Rgba8::CYAN, "H / Start button Reset position and orientation to zero");
	g_theDevConsole->AddLine(Rgba8::CYAN, "Shift / A button Increase speed by a factor of 10 while held");
	g_theDevConsole->AddLine(Rgba8::CYAN, "P - Pause the game");
	g_theDevConsole->AddLine(Rgba8::CYAN, "O - Single step frame");
	g_theDevConsole->AddLine(Rgba8::CYAN, "T - Slow motion mode");
	g_theDevConsole->AddLine(Rgba8::CYAN, "1 - Spawn line");
	g_theDevConsole->AddLine(Rgba8::CYAN, "2 - Spawn point");
	g_theDevConsole->AddLine(Rgba8::CYAN, "3 - Spawn wireframe sphere");
	g_theDevConsole->AddLine(Rgba8::CYAN, "4 - Spawn basis");
	g_theDevConsole->AddLine(Rgba8::CYAN, "5 - Spawn billboard");
	g_theDevConsole->AddLine(Rgba8::CYAN, "6 - Spawn wireframe cylinder");
	g_theDevConsole->AddLine(Rgba8::CYAN, "7 - Add message");
	g_theDevConsole->AddLine(Rgba8::CYAN, "V - Toggle GI Visualization debug panel");
	g_theDevConsole->AddLine(Rgba8::CYAN, "ESC - Exit game");
}

void Game::DrawSquareXYGrid(int unit /*= 100*/)
{
	m_gridVertexes.clear();

	const int GRID_SIZE = unit * unit;
	const float LINE_THICKNESS = 0.03f;
	const float BOLD_LINE_THICKNESS = 0.05f;
	const float ORIGIN_LINE_THICKNESS = 0.1f;

	for (int x = -GRID_SIZE / 2; x <= GRID_SIZE / 2; ++x)
	{
		float thickness = LINE_THICKNESS;
		Rgba8 color = Rgba8::GREY; 

		if (x % 5 == 0)
		{
			thickness = BOLD_LINE_THICKNESS;
			color = Rgba8::RED; 
		}
		if (x == 0)
		{
			thickness = ORIGIN_LINE_THICKNESS;
			color = Rgba8(255, 50, 50, 255);
		}

		AABB3 bounds(Vec3(-GRID_SIZE / 2.f, (float)x - thickness / 2.f, -thickness / 2.f),
			Vec3(GRID_SIZE / 2.f, (float)x + thickness / 2.f, thickness / 2.f));

		AddVertsForAABB3D(m_gridVertexes, bounds, color, AABB2::ZERO_TO_ONE);
	}

	for (int y = -GRID_SIZE / 2; y <= GRID_SIZE / 2; ++y)
	{
		float thickness = LINE_THICKNESS * 1.1f;
		Rgba8 color = Rgba8::GREY;

		if (y % 5 == 0)
		{
			thickness = BOLD_LINE_THICKNESS * 1.1f;
			color = Rgba8::GREEN; 
		}
		if (y == 0)
		{
			thickness = ORIGIN_LINE_THICKNESS * 1.1f;
			color = Rgba8(50, 255, 50, 255);
		}

		AABB3 bounds(Vec3((float)y - thickness / 2.f, -GRID_SIZE / 2.f , -thickness/2.f),
			Vec3((float)y + thickness / 2.f, GRID_SIZE / 2.f, thickness/2.f));

		AddVertsForAABB3D(m_gridVertexes, bounds, color, AABB2::ZERO_TO_ONE);
	}
}

void Game::DebugRenderSystemInputUpdate()
{
	Vec3 pos = m_player->m_position;
	std::string reportHUD = " Player Position: " +
		RoundToOneDecimalString(pos.x) + ", " + RoundToOneDecimalString(pos.y) + ", " + RoundToOneDecimalString(pos.z);
	DebugAddMessage(reportHUD, 0.f, m_screenCamera);

	if (g_theApp->WasKeyJustPressed('1'))
	{
		Vec3 playerI = m_player->GetModelToWorldTransform().GetIBasis3D();
		Vec3 end = pos + playerI * 20.f;
		DebugAddWorldLine(pos, end, 0.1f, 10.f, Rgba8::YELLOW, Rgba8::YELLOW, DebugRenderMode::X_RAY);
	}
	if (g_theApp->IsKeyDown('2'))
	{
		DebugAddWorldPoint(Vec3(pos.x,pos.y,0.f), 0.2f, 60.f, Rgba8(150, 75, 0), Rgba8(150, 75, 0), DebugRenderMode::USE_DEPTH);
	}
	if (g_theApp->WasKeyJustPressed('3'))
	{
		Vec3 playerI = m_player->GetModelToWorldTransform().GetIBasis3D();
		Vec3 center = pos + playerI * 2.f;
		DebugAddWorldWireSphere(center, 1.f, 5.f, Rgba8::GREEN, Rgba8::RED);//, DebugRenderMode::USE_DEPTH);
	}
	if (g_theApp->WasKeyJustPressed('4'))
	{
		Mat44 playerMat = m_player->GetModelToWorldTransform();
		Vec3 playerI = m_player->GetModelToWorldTransform().GetIBasis3D().GetNormalized();
		Vec3 playerJ = m_player->GetModelToWorldTransform().GetJBasis3D().GetNormalized();
		Vec3 playerK = m_player->GetModelToWorldTransform().GetKBasis3D().GetNormalized();
		playerMat.SetIJK3D(playerI, playerJ, playerK);
		/*Mat44 mat;
		mat.SetIJK3D(Vec3(0.f, -1.f, 0.f), Vec3(0.f, 0.f, 1.f), Vec3(1.f, 0.f, 0.f));
		playerMat.Append(mat);*/
		//DebugAddWorldBasis(playerMat, 20.f);//, DebugRenderMode::USE_DEPTH);
		Vec3 newK = pos + playerK;
		Vec3 newI = pos + playerI;
		Vec3 newJ = pos + playerJ;
		DebugAddWorldArrow(pos, newK, 0.05f, 20.f, Rgba8::AQUA, Rgba8::AQUA);
		DebugAddWorldArrow(pos, newI, 0.05f, 20.f, Rgba8::MAGENTA, Rgba8::MAGENTA);
		DebugAddWorldArrow(pos, newJ, 0.05f, 20.f, Rgba8::MINTGREEN, Rgba8::MINTGREEN);
	}
	if (g_theApp->WasKeyJustPressed('5'))
	{
		EulerAngles ori = m_player->m_orientation;
		Vec3 playerI = m_player->GetModelToWorldTransform().GetIBasis3D().GetNormalized();
		Vec3 pivot = pos + playerI * 2.f;
		/*std::string report = "Position: " +
			std::to_string(RoundToOneDecimal(pos.x)) + ", " + std::to_string(RoundToOneDecimal(pos.y)) + ", " + std::to_string(RoundToOneDecimal(pos.z)) +
			" Orientation: " + std::to_string(RoundToOneDecimal(ori.m_yawDegrees)) + ", " + std::to_string(RoundToOneDecimal(ori.m_pitchDegrees)) + ", "
			+ std::to_string(RoundToOneDecimal(ori.m_rollDegrees));*/
		std::string report = "Position: " +
			RoundToOneDecimalString(pos.x) + ", " + RoundToOneDecimalString(pos.y) + ", " + RoundToOneDecimalString(pos.z) +
			" Orientation: " + RoundToOneDecimalString(ori.m_yawDegrees) + ", " + RoundToOneDecimalString(ori.m_pitchDegrees) + ", "
			+ RoundToOneDecimalString(ori.m_rollDegrees);

		DebugAddWorldBillboardText(report, pivot, 0.2f, Vec2(0.25f, 0.25f), 10.f, Rgba8::WHITE);// , DebugRenderMode::USE_DEPTH);
	}
	if (g_theApp->WasKeyJustPressed('6'))
	{
		DebugAddWorldWireCylinder(pos, pos + Vec3(0.f, 0.f, 2.f), 0.5f, 10.f, Rgba8::WHITE, Rgba8::RED);
	}
	if (g_theApp->WasKeyJustPressed('7'))
	{
		EulerAngles ori = m_player->m_orientation;
		std::string report = " Camera Orientation: " + RoundToOneDecimalString(ori.m_yawDegrees) + ", " + RoundToOneDecimalString(ori.m_pitchDegrees) + ", "
			+ RoundToOneDecimalString(ori.m_rollDegrees);
		DebugAddMessage(report, 5.f, m_screenCamera);
	}

	//Add fps...
	float timeTotal = (float)m_gameClock->GetTotalSeconds();
	float fps = (float)m_gameClock->GetFrameRate();
	float timeScale = m_gameClock->GetTimeScale();
	std::string timeReportHUD = " Time: " + RoundToTwoDecimalsString(timeTotal) 
	+ " FPS: " + RoundToOneDecimalString(fps) + " Scale: " + RoundToTwoDecimalsString(timeScale);
	float textWidth = GetTextWidth(12.f, timeReportHUD, 0.7f);
	DebugAddScreenText(timeReportHUD, m_screenCamera.GetOrthographicTopRight() - Vec2(textWidth + 1.f, 15.f), 12.f, Vec2::ZERO, 0.f);

	// Key hints (top-left)
	float hintSize = 11.f;
	float topY = 780.f;
	DebugAddScreenText("Point Light: Orbiting",
		Vec2(5.f, topY - 14.f), hintSize, Vec2::ZERO, 0.f, Rgba8::YELLOW);
#ifdef ENGINE_DX12_RENDERER
	bool vizOn = g_theRenderer->GetSubRenderer() && g_theRenderer->GetSubRenderer()->IsGIVisualizationEnabled();
#else
	bool vizOn = false;
#endif
	DebugAddScreenText(Stringf("[V] GI Visualization: %s", vizOn ? "ON" : "OFF"),
		Vec2(5.f, topY - 28.f), hintSize, Vec2::ZERO, 0.f, vizOn ? Rgba8::YELLOW : Rgba8(180, 180, 180));
	DebugAddScreenText(Stringf("[M] Mouse FPS: %s", m_mouseFPS ? "ON" : "OFF"),
		Vec2(5.f, topY - 42.f), hintSize, Vec2::ZERO, 0.f, m_mouseFPS ? Rgba8::YELLOW : Rgba8(180, 180, 180));
	DebugAddScreenText(Stringf("Culled: %d/%d", g_theScene->m_lastCulledCount, g_theScene->m_lastTotalCount),
		Vec2(5.f, topY - 56.f), hintSize, Vec2::ZERO, 0.f, Rgba8(180, 220, 180));
}

void Game::DebugAddWorldAxisText(Mat44 worldMat)
{
	Mat44 xMat;
	xMat.SetIJK3D(Vec3(-1.f, 0.f, 0.f), Vec3(0.f, 0.f, 1.f), Vec3(0.f, 1.f, 0.f));
	xMat.Append(worldMat);
	DebugAddWorldText("x-Forward", xMat, 0.2f, Vec2(-0.05f, -0.3f), -1.f, Rgba8::MAGENTA);

	Mat44 yMat;
	yMat.SetIJK3D(Vec3(0.f, 1.f, 0.f), Vec3(0.f, 0.f, 1.f), Vec3(1.f, 0.f, 0.f));
	yMat.Append(worldMat);
	DebugAddWorldText("y-Left", yMat, 0.2f, Vec2( 1.f,-0.3f), -1.f, Rgba8::MINTGREEN);

	Mat44 zMat;
	zMat.SetIJK3D(Vec3(0.f, 0.f, -1.f), Vec3(0.f, 1.f, 0.f), Vec3(1.f, 0.f, 0.f));
	zMat.Append(worldMat);
	DebugAddWorldText("z-Up", zMat, 0.2f, Vec2(-0.3f, 1.5f), -1.f, Rgba8::AQUA);
}
