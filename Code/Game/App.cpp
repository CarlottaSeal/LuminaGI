#include "Engine/Window/Window.hpp"
#include "Engine/Renderer/Renderer.hpp"
#include "Engine/Renderer/Camera.hpp"
#include "Engine/Renderer/SimpleTriangleFont.hpp"
#include "Engine/Input/InputSystem.hpp"
#include "Engine/Core/Time.hpp"
#include "Engine/Core/EngineCommon.hpp"
#include "Engine/Core/VertexUtils.hpp"
#include "Engine/Core/Clock.hpp"
#include "Engine/Core/DebugRenderSystem.hpp"
#include "Engine/Input/KeyButtonState.hpp"
#include "Engine/Input/InputSystem.hpp"
#include "Engine/Audio/AudioSystem.hpp"

#include "Game/App.hpp"
#include "Game/Game.hpp"
#include "Game/Gamecommon.hpp"

#include "Engine/Renderer/GI/GISystem.h"
#include "Engine/Scene/Scene.h"

App* g_theApp = nullptr;
Renderer* g_theRenderer = nullptr;
InputSystem* g_theInput = nullptr;
//AudioSystem* g_theAudio = nullptr;
Window* g_theWindow = nullptr;
GISystem* g_theGISystem = nullptr;
SaveSystem* g_theSaveSystem = nullptr;
Game* g_theGame = nullptr;
Scene* g_theScene = nullptr;

App::App()
{
	//Parse GameConfig
	XmlDocument gameConfigDoc;
	gameConfigDoc.LoadFile("Data/GameConfig.xml");
	/*if (loadResult != XmlResult::XML_SUCCESS)
	{
		return; 
	}*/
	//if load fails, sth will be wrong
	XmlElement* rootElement = gameConfigDoc.RootElement();
	if (rootElement)
	{
		g_gameConfigBlackboard.PopulateFromXmlElementAttributes(*rootElement);
	}
	
	//Create all engine subsystems
	InputSystemConfig inputConfig;
	g_theInput = new InputSystem(inputConfig);

	WindowConfig windowConfig;
	windowConfig.m_aspectRatio = 2.f;
	windowConfig.m_inputSystem = g_theInput;
	windowConfig.m_windowTitle = g_gameConfigBlackboard.GetValue("windowTitle", "Protogame3D");
	windowConfig.m_isFullscreen = g_gameConfigBlackboard.GetValue("windowFullscreen", false);
	g_theWindow = new Window(windowConfig);

	RendererConfig rendererConfig;
	rendererConfig.m_window = g_theWindow;
	rendererConfig.m_enableGI = true;
	g_theRenderer = new Renderer(rendererConfig);
	
	EventSystemConfig eventSystemConfig;
	g_theEventSystem = new EventSystem(eventSystemConfig);

	unsigned int numCores = std::thread::hardware_concurrency();
	JobSystemConfig jobSystemConfig;
	numCores = GetClampedInt((int)numCores, 0, 32);
	jobSystemConfig.m_numWorkerThreads = (int)numCores - 2;
	jobSystemConfig.m_numIOThreads = 1;
	g_theJobSystem = new JobSystem(jobSystemConfig);

	SaveConfig saveConfig;
	g_theSaveSystem = new SaveSystem(saveConfig);

	DevConsoleConfig devConsoleConfig;
	devConsoleConfig.m_defaultRenderer = g_theRenderer;
	devConsoleConfig.m_defaultFontName = "SquirrelFixedFont";
	Camera* devCamera = new Camera();
	devCamera->SetOrthographicView(Vec2(0.f, 0.f), Vec2(1600.f, 800.f));
	//devConsoleConfig.m_camera = &g_theGame->m_screenCamera;
	devConsoleConfig.m_camera = devCamera;
	g_theDevConsole = new DevConsole(devConsoleConfig);

	/*AudioSystemConfig audioSystemConfig;
	g_theAudio = new AudioSystem(audioSystemConfig);*/
}

App::~App()
{
}

void App::Startup()
{
	GIConfig giConfig;
	giConfig.m_window = g_theWindow;
	giConfig.m_renderer = g_theRenderer;
	g_theGISystem = new GISystem(giConfig);
	g_theRenderer->GetSubRenderer()->SetGISystem(g_theGISystem);
	
	g_theWindow->Startup();
	g_theRenderer->Startup();
	//g_theAudio->Startup();
	g_theEventSystem->StartUp(); 
	g_theDevConsole->Startup();
	g_theInput->Startup();
	g_theJobSystem->Startup();

	g_theGISystem->Startup();
	
	DebugRenderConfig debugRenderConfig;
	debugRenderConfig.m_renderer = g_theRenderer;
	DebugRenderSystemStartup(debugRenderConfig);

	g_theGame = new Game();
	g_theGame->m_gameClock = new Clock(Clock::GetSystemClock());
	g_theGame->Startup();

	g_theEventSystem->SubscribeEventCallBackFunction("quit", OnQuitEvent);

	g_theDevConsole->AddLine(Rgba8::BLUE, "Type help for a list of commands");
}

void App::Shutdown()
{
	delete g_theScene;
	g_theScene = nullptr;

	delete g_theGame;
	g_theGame = nullptr;

	g_theJobSystem->Shutdown();
	//g_theGISystem->Shutdown();
	g_theEventSystem->Shutdown();
	//g_theAudio->Shutdown();
	g_theRenderer->ShutDown();
	g_theWindow->Shutdown();
	g_theInput->Shutdown();
	g_theJobSystem->Shutdown();
	g_theDevConsole->Shutdown();

	DebugRenderSystemShutdown();

	delete g_theDevConsole;
	g_theDevConsole = nullptr;

	delete g_theEventSystem;
	g_theEventSystem = nullptr;

	/*delete g_theAudio;
	g_theAudio = nullptr;*/

	delete g_theRenderer;
	g_theRenderer = nullptr;

	delete g_theWindow;
	g_theWindow = nullptr;

	delete g_theInput;
	g_theInput = nullptr;

	delete g_theJobSystem;
	g_theJobSystem = nullptr;

	delete g_theGISystem;
	g_theGISystem = nullptr;
}

void App::BeginFrame()
{
	Clock::TickSystemClock();
	g_theWindow->BeginFrame();
	g_theInput->BeginFrame();
	g_theRenderer->BeginFrame();
	//g_theGISystem->BeginFrame(g_theRenderer->m_frameIndex);
	//g_theAudio->BeginFrame();
	g_theEventSystem->BeginFrame();
	g_theDevConsole->BeginFrame();

	DebugRenderBeginFrame();
}

bool App::IsKeyDown(unsigned char keyCode) const
{
	return g_theInput->IsKeyDown(keyCode);
	//return m_keystates[keyCode].IsPressed();
	//return m_currentKeyStates[keyCode]; // 当前帧按键状态
}

bool App::WasKeyJustPressed(unsigned char keyCode) const
{
	return g_theInput->WasKeyJustPressed(keyCode);
	//return m_keystates[keyCode].WasJustPressed();
	//return m_currentKeyStates[keyCode] && !m_previousKeyStates[keyCode]; // 当前帧按下，上一帧未按下
}

void App::HandleKeyPressed(unsigned char keyCode)
{
	g_theInput->HandleKeyPressed(keyCode);
	//m_keystates[keyCode].UpdateStatus(true);
	//m_currentKeyStates[keyCode] = true;
}

void App::HandleKeyReleased(unsigned char keyCode)
{
	g_theInput->HandleKeyReleased(keyCode);
	//m_keystates[keyCode].UpdateStatus(false);
	m_currentKeyStates[keyCode] = false;
}

bool App::IsKeyReleased(unsigned char keyCode) const
{
	return 	m_currentKeyStates[keyCode];
}

void App::HandleQuitRequested()
{
	g_isQuitting = true;
}

//-----------------------------------------------------------------------------------------------
// One "frame" of the game.  Generally: Input, Update, Render.  We call this 60+ times per second.
// #SD1ToDo: Move this function to Game/App.cpp and rename it to  TheApp::RunFrame()

void App::RunFrame()
{
	//float timeNow = static_cast<float>(GetCurrentTimeSeconds());
	//float deltaSeconds = timeNow - m_timeLastFrameStart;
	////DebuggerPrintf("TimeNow = %.06f\n, TimeNow");
	//m_timeLastFrameStart = timeNow;

	BeginFrame();
	Update();
	Render();
	EndFrame();
}

void App::Update()
{
	if (WasKeyJustPressed(KEYCODE_F8))
	{
		delete g_theGame;
		g_theGame = new Game();
	}

	g_theGame->Update();

	UpdateCursor();
}

void App::Render() const
{
	g_theGame->Render();
}

void App::EndFrame()
{
	// let renderer deal with buffers
	g_theWindow->EndFrame();
	g_theGISystem->EndFrame();
	g_theRenderer->EndFrame();
	g_theInput->EndFrame();
	//g_theAudio->EndFrame();
	g_theEventSystem->EndFrame();
	g_theDevConsole->EndFrame();

	for (int i = 0; i < 256; ++i)
	{
		m_keystates[i].EndFrame();
	}

	DebugRenderEndFrame();
}

void App::UpdateCursor()
{
	if (g_theGame->m_isInAttractMode || g_theGame->m_openDevConsole || !g_theWindow->WindowHasFocus())
	{
		g_theInput->SetCursorMode(CursorMode::POINTER);
	}
	else
	{
		g_theInput->SetCursorMode(CursorMode::FPS);
	}
}

bool OnQuitEvent(EventArgs& args)
{
	UNUSED(args);
	g_theApp->HandleQuitRequested();
	return true;
}