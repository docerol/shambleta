# P3 — escalabilidade: ZonePolicy agrupa idle policies por zona (O(1) por frame físico para farm zones).
class_name ZonePolicy
extends IdlePolicy

var policies : Array[IdlePolicy] = []

func Tick(delta : float) -> void:
	# Comportamento base: o próprio agente farma normalmente (brain IdlePolicy).
	super.Tick(delta)
	# P3 — batching: além disso itera policies agrupadas, se houver.
	for policy in policies:
		if policy and is_instance_valid(policy.agent) and policy.agent:
			policy.Tick(delta)

func AttachPolicy(policy : IdlePolicy) -> void:
	if policy and not policies.has(policy):
		policies.append(policy)

func DetachPolicy(policy : IdlePolicy) -> void:
	policies.erase(policy)
