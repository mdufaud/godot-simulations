class_name SimQualityProfile
extends RefCounted
## Common quality-tier foundation for the demo simulations. A tier bundles the
## whole performance configuration of a demo behind one name, so the menu
## exposes a single reproducible choice instead of a dozen loose toggles. The
## four tiers share one philosophy across the project:
##
## - ULTRA: no restrictions, everything the simulation can do.
## - HIGH: nearly everything on, minus the few most expensive multipliers.
## - MEDIUM: comfortable on integrated GPUs, the first-launch default.
## - LOW: smooth on the same integrated GPUs.
##
## Demos subclass this and override [method values] with their per-tier knob
## dictionaries; override [method tier_supported] when a tier needs hardware
## the machine lacks. Statics resolve on the class they are called through, so
## SimQualityState carries the subclass reference itself instead of relying on
## virtual lookup from inside this base class.

enum Tier { LOW, MEDIUM, HIGH, ULTRA }

const TIER_NAMES := ["Low", "Medium", "High", "Ultra"]


## Tier a fresh launch starts from. Overridable per demo (a static function,
## because GDScript forbids shadowing a parent-class constant); subclasses
## wanting the project-wide Medium default simply inherit this.
static func default_tier() -> int:
	return Tier.MEDIUM


static func tier_count() -> int:
	return TIER_NAMES.size()


static func tier_name(tier: int) -> String:
	return TIER_NAMES[clampi(tier, 0, TIER_NAMES.size() - 1)]


## Performance knobs for one tier. Keys are demo-specific; SimQualityState
## pushes each entry to the widget bound under the same key, and hands the
## unbound remainder to the demo's apply callable.
static func values(tier: int) -> Dictionary:
	return {}


## False when [param tier] needs hardware the machine lacks. SimQualityState
## walks down from the requested tier to the highest supported one. Statics
## resolve lexically in GDScript, so the walk lives on the state, which calls
## [method tier_supported] through the concrete subclass reference; a subclass
## overriding this hook is seen by the state but not by base-class helpers.
static func tier_supported(tier: int) -> bool:
	return true


## True when the menu must show the "requested / active" degraded label.
static func is_degraded(requested: int, effective: int) -> bool:
	return requested != effective


## Label for menus, profiler overlays and capture metadata; a degraded pick
## reads e.g. "Ultra requested / High active".
static func label(requested: int, effective: int) -> String:
	if requested == effective:
		return tier_name(effective)
	return "%s requested / %s active" % [tier_name(requested), tier_name(effective)]
