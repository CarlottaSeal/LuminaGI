#pragma once
#include "Engine/Core/Rgba8.hpp"
#include "Engine/Math/Vec3.hpp"
#include "Engine/Renderer/Camera.hpp"

class Game;
class Camera;

class Player
{
public:
	Player(Game* owner);
	~Player();

	void Update(float deltaSeconds);
	void Render() const;

	Vec3 GetForwardVectorDueToOrientation() const;
	Vec3 GetLeftVectorDueToOrientation() const;
	Mat44 GetModelToWorldTransform() const;

public:
	Game* m_game = nullptr;
	Vec3 m_position;
	Vec3 m_velocity;
	EulerAngles m_orientation;
	EulerAngles m_angularVelocity;
	Rgba8 m_color = Rgba8::GREY;
	
	Vec3 m_originV;
	float m_originYaw;
	float m_originPitch;
	float m_originRoll;

	Camera m_worldCamera;
};