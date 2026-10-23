extends Node3D
## ONE MORE DRINK - endless driving game about alcohol impairment (Godot 4.1+)
## Attach this script to a Node3D root, save the scene and press F5.
## Controls: A / Left = change lane left, D / Right = change lane right
##           Enter / Space / R = start / restart
##
## Arcade-style logic: no physics engine, collisions are simple box overlap tests.
##
## FAIRNESS: traffic is generated as "rows". Every row keeps one SAFE LANE free, the safe
## lane can only move by one lane between two rows, and rows are spaced by *time*
## (longer when the alcohol delay is bigger). Moving vehicles are spawned so that they
## reach their row exactly when the player does, so a path through the traffic always exists.

enum State { MENU, PLAYING, GAME_OVER }

# --- Road / player ------------------------------------------------------------
const LANE_WIDTH := 3.5
const ROAD_HALF := 5.25            # road is 10.5 m wide, 3 lanes
const OFFROAD_LIMIT := 5.3         # |x| beyond this = left the road
const PLAYER_HALF := Vector2(0.9, 2.0)   # half width (x), half length (z)
const LATERAL_SPEED := 11.0        # m/s when changing lanes

# --- Speed / progression ------------------------------------------------------
const START_SPEED := 18.0          # m/s
const MAX_SPEED := 60.0
const ACCEL := 0.4                 # m/s gained per second
const SEGMENT_LENGTH := 700.0      # metres per route segment (+50 pts, +1 alcohol level)

# --- Traffic ------------------------------------------------------------------
const SPAWN_AHEAD := 220.0         # hazards appear this far ahead (hidden by fog)
const PLAN_AHEAD := 480.0          # how far ahead rows are planned
const MIN_GAP := 24.0              # minimum metres between two rows
const ROW_TIME := 1.6              # base seconds between two rows
const ROW_TIME_PER_DELAY := 1.2    # extra seconds per second of input delay
const VEHICLE_SPEED_MIN := 6.0
const VEHICLE_SPEED_MAX := 9.0
const PED_SPEED := 2.4

# --- World streaming ----------------------------------------------------------
const CHUNK_LEN := 100.0
const NUM_CHUNKS := 6
const BASE_FOV := 68.0

# --- Alcohol tuning, indexed by level 0..3 (values are interpolated smoothly) ---
const DELAY := [0.0, 0.18, 0.28, 0.55]      # seconds of input delay
const LANE_ERR := [0.0, 0.0, 0.7, 1.0]      # random lane-change error in metres
const SWAY := [0.0, 0.0, 0.0, 0.35]         # slow involuntary drifting in metres
const STATE_NAMES := ["SOBER", "BUZZED", "DRUNK", "WASTED"]
const LEVEL_MSGS := [
	"",
	"Alcohol level 1\nYour reactions are getting slower...",
	"Alcohol level 2\nThe world sways. Lane changes get sloppy...",
	"Alcohol level 3\nBlurred, narrow vision. Delayed reactions.",
]
const LEVEL_COLORS := [Color.WHITE, Color(1, 0.9, 0.3), Color(1, 0.6, 0.2), Color(1, 0.25, 0.2)]

# --- UI palette ---------------------------------------------------------------
const COL_PANEL := Color(0.04, 0.05, 0.09, 0.78)
const COL_BORDER := Color(1, 1, 1, 0.14)
const COL_MUTED := Color(0.66, 0.71, 0.8)
const COL_ACCENT := Color(0.4, 0.8, 1.0)

const FX_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float blur = 0.0;
uniform float split = 0.0;
uniform float vignette = 0.0;
void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 c = textureLod(screen_tex, uv, blur).rgb;
	vec3 a = textureLod(screen_tex, uv + vec2(split, 0.0), blur).rgb;
	vec3 b = textureLod(screen_tex, uv - vec2(split, 0.0), blur).rgb;
	vec3 col = (c + a + b) / 3.0;
	float v = 1.0 - smoothstep(0.3, 0.85, length(uv - vec2(0.5)));
	col *= mix(1.0, v, vignette);
	COLOR = vec4(col, 1.0);
}
"""

static var auto_start := false     # survives scene reload, so restart skips the menu
static var best_score := 0         # survives scene reload


class Hazard:
	var node: Node3D
	var type := 0              # 0 = vehicle, 1 = obstacle, 2 = pedestrian
	var half := Vector2.ONE
	var vel := Vector3.ZERO
	var waiting := false       # pedestrians wait on the curb until triggered
	var side := 1.0
	var trigger := 2.0         # seconds before the player arrives that the pedestrian starts
	var phase := 0.0
	var scored := false
	var threat := false        # was in the player's path -> counts as a risk
	var min_gap := 99.0
	var reason := ""


var state := State.MENU
var player: Node3D
var camera: Camera3D
var ground: MeshInstance3D
var chunks: Array = []
var hazards: Array = []

var speed := START_SPEED
var play_time := 0.0
var score := 0
var score_timer := 0.0
var segments_done := 0
var level := 0
var drunk := 0.0               # smoothed alcohol level (0..3)
var lane := 0
var lane_offset := 0.0
var pending: Array = []        # delayed steering commands
var cam_x := 0.0
var over_time := 0.0           # when the game ended (restart lockout)

# Traffic planning
var rows: Array = []           # planned rows that have not been spawned yet
var plan_z := -150.0           # z of the next row to be planned
var safe_lane := 0             # lane that is guaranteed free in the last planned row

# HUD
var score_label: Label
var segment_label: Label
var route_bar: ProgressBar
var speed_label: Label
var speed_bar: ProgressBar
var speed_fill: StyleBoxFlat
var alc_state_label: Label
var alc_panel_style: StyleBoxFlat
var alc_styles: Array = []
var popup_panel: PanelContainer
var popup_style: StyleBoxFlat
var popup_label: Label
var popup_tween: Tween
var hint_label: Label
var flash: ColorRect
var dim: ColorRect
var title_label: Label
var subtitle_label: Label
var menu_box: VBoxContainer
var over_box: VBoxContainer
var prompt_label: Label
var newbest_label: Label
var stat_score: Label
var stat_best: Label
var stat_dist: Label
var stat_alc: Label
var tint: ColorRect
var fx_rect: ColorRect
var fx_mat: ShaderMaterial
var _hud_level := -1


func _ready() -> void:
	randomize()
	_setup_inputs()
	_build_world()
	player = _make_car_model(Color(0.85, 0.1, 0.1))
	add_child(player)
	camera = Camera3D.new()
	camera.far = 600.0
	add_child(camera)
	camera.current = true
	_build_hud()
	_build_post_fx()
	_update_camera(0.016)
	_update_hud()
	_update_spawns()
	if auto_start:
		_start()
	else:
		_show_menu()


# ------------------------------------------------------------------------------
# Input
# ------------------------------------------------------------------------------
func _setup_inputs() -> void:
	_add_action("steer_left", [KEY_A, KEY_LEFT])
	_add_action("steer_right", [KEY_D, KEY_RIGHT])
	_add_action("start", [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_R])


func _add_action(action: String, keys: Array) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)


func _unhandled_input(event: InputEvent) -> void:
	match state:
		State.MENU:
			if event.is_action_pressed("start"):
				_start()
		State.PLAYING:
			if event.is_action_pressed("steer_left"):
				_queue_steer(-1)
			elif event.is_action_pressed("steer_right"):
				_queue_steer(1)
		State.GAME_OVER:
			# short lockout so mashing A/D at the moment of the crash can't restart
			if event.is_action_pressed("start") and Time.get_ticks_msec() / 1000.0 - over_time > 0.8:
				auto_start = true
				get_tree().reload_current_scene()


# ------------------------------------------------------------------------------
# Game flow
# ------------------------------------------------------------------------------
func _show_menu() -> void:
	dim.visible = true
	menu_box.visible = true
	over_box.visible = false
	title_label.text = "ONE MORE DRINK"
	title_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.35))
	subtitle_label.text = "An endless road. A dangerous choice."
	prompt_label.text = "PRESS  ENTER  TO START"


func _start() -> void:
	state = State.PLAYING
	dim.visible = false
	speed = START_SPEED
	_popup("Go! Stay on the road.", Color.WHITE)
	hint_label.modulate.a = 1.0
	var ht := create_tween()
	ht.tween_interval(5.0)
	ht.tween_property(hint_label, "modulate:a", 0.0, 1.0)


func _game_over(reason: String) -> void:
	state = State.GAME_OVER
	over_time = Time.get_ticks_msec() / 1000.0
	var new_best := score > best_score
	best_score = maxi(best_score, score)

	flash.color.a = 0.55
	create_tween().tween_property(flash, "color:a", 0.0, 0.7)

	dim.visible = true
	menu_box.visible = false
	over_box.visible = true
	title_label.text = "GAME OVER"
	title_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.28))
	subtitle_label.text = reason
	stat_score.text = str(score)
	stat_best.text = str(best_score)
	stat_dist.text = "%d m" % int(-player.position.z)
	stat_alc.text = "%d / 3" % level
	newbest_label.visible = new_best
	prompt_label.text = "PRESS  ENTER  TO TRY AGAIN"


func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	if state == State.PLAYING:
		_update_game(delta)
	_update_camera(delta)


func _update_game(delta: float) -> void:
	play_time += delta
	speed = minf(speed + ACCEL * delta, MAX_SPEED)
	player.position.z -= speed * delta
	drunk = move_toward(drunk, float(level), delta * 0.4)

	_process_steer_queue()
	_update_player_x(delta)

	_update_spawns()
	_update_hazards(delta)
	if state != State.PLAYING:
		return

	if absf(player.position.x) > OFFROAD_LIMIT:
		_game_over("You left the road.")
		return

	_update_progress(delta)
	_update_chunks()
	ground.position.z = player.position.z
	_update_hud()


# ------------------------------------------------------------------------------
# Steering with alcohol effects
# ------------------------------------------------------------------------------
func _by_level(table: Array, v: float) -> float:
	var i := clampi(int(floorf(v)), 0, table.size() - 2)
	return lerpf(table[i], table[i + 1], clampf(v - i, 0.0, 1.0))


func _queue_steer(dir: int) -> void:
	pending.append({"t": play_time + _by_level(DELAY, drunk), "dir": dir})


func _process_steer_queue() -> void:
	while pending.size() > 0 and pending[0]["t"] <= play_time:
		var cmd = pending.pop_front()
		_apply_steer(cmd["dir"])


func _apply_steer(dir: int) -> void:
	var new_lane := clampi(lane + dir, -1, 1)
	if new_lane == lane:
		return                                  # no lane change -> no new error
	lane = new_lane
	# Level 2+: you don't land exactly in the middle of the lane
	var err := _by_level(LANE_ERR, drunk)
	lane_offset = randf_range(-err, err)
	# outer lanes: errors toward the road edge are much smaller (keeps it fair)
	if lane != 0 and signf(lane_offset) == float(lane):
		lane_offset *= 0.4


func _update_player_x(delta: float) -> void:
	var sway := sin(play_time * 0.9) * _by_level(SWAY, drunk)
	var target := lane * LANE_WIDTH + lane_offset + sway
	var before := player.position.x
	player.position.x = move_toward(before, target, LATERAL_SPEED * delta)
	var vx := (player.position.x - before) / maxf(delta, 0.0001)
	player.rotation.y = lerp_angle(player.rotation.y, -vx * 0.03, minf(1.0, delta * 10.0))


# ------------------------------------------------------------------------------
# Player motion prediction (speed only depends on time, so it is fully predictable)
# ------------------------------------------------------------------------------
func _time_to_cover(dist: float) -> float:
	if dist <= 0.0:
		return 0.0
	var t_max := maxf((MAX_SPEED - speed) / ACCEL, 0.0)
	var d_max := speed * t_max + 0.5 * ACCEL * t_max * t_max
	if dist <= d_max:
		return (sqrt(speed * speed + 2.0 * ACCEL * dist) - speed) / ACCEL
	return t_max + (dist - d_max) / MAX_SPEED


func _speed_after(dist: float) -> float:
	return minf(sqrt(speed * speed + 2.0 * ACCEL * maxf(dist, 0.0)), MAX_SPEED)


# ------------------------------------------------------------------------------
# Traffic planning: rows that always leave a reachable safe lane
# ------------------------------------------------------------------------------
func _update_spawns() -> void:
	_plan_rows()
	for i in range(rows.size() - 1, -1, -1):
		if _row_start_dist(rows[i]) <= SPAWN_AHEAD:
			_spawn_row(rows[i])
			rows.remove_at(i)


func _plan_rows() -> void:
	while player.position.z - plan_z < PLAN_AHEAD:
		rows.append(_make_row(plan_z))
		plan_z -= _row_gap(plan_z)


# Distance (in metres) to the next row. It is measured in TIME so the player always has
# enough seconds to change lanes, even with the input delay of a higher alcohol level.
func _row_gap(m: float) -> float:
	var d := player.position.z - m
	var s_arr := _speed_after(d + 60.0)
	var lvl := clampi(int(-(m - 60.0) / SEGMENT_LENGTH), 0, 3)
	var t: float = ROW_TIME + ROW_TIME_PER_DELAY * DELAY[lvl] + randf_range(0.0, 0.8)
	return maxf(MIN_GAP, s_arr * t)


func _make_row(m: float) -> Dictionary:
	var row := {"m": m, "has_vehicle": false, "vehicle_lane": 0, "v": 0.0,
			"obstacles": [], "ped_side": 0.0}
	var r := randf()
	if r < 0.22:
		# Pedestrian crossing from one curb. The lane on the far side of the road
		# always stays free, so that is this row's safe lane.
		var sides: Array = []
		for sd in [-1, 1]:
			if abs(-sd - safe_lane) <= 1:
				sides.append(sd)
		var side := float(sides[randi() % sides.size()])
		row["ped_side"] = side
		safe_lane = int(-side)
		return row

	# Pick the safe lane (max. one lane away from the previous safe lane)
	var opts: Array = []
	for l in range(-1, 2):
		if absi(l - safe_lane) <= 1:
			opts.append(l)
	safe_lane = opts[randi() % opts.size()]
	var others: Array = []
	for l in range(-1, 2):
		if l != safe_lane:
			others.append(l)
	others.shuffle()

	if r < 0.50:                                   # slow vehicle
		row["has_vehicle"] = true
		row["vehicle_lane"] = others[0]
		row["v"] = randf_range(VEHICLE_SPEED_MIN, VEHICLE_SPEED_MAX)
	elif r < 0.78:                                 # obstacle(s)
		row["obstacles"].append([others[0], 0.0])
		if randf() < 0.4:
			row["obstacles"].append([others[1], 0.0])
	else:                                          # vehicle + obstacle
		row["has_vehicle"] = true
		row["vehicle_lane"] = others[0]
		row["v"] = randf_range(VEHICLE_SPEED_MIN, VEHICLE_SPEED_MAX)
		row["obstacles"].append([others[1], randf_range(-3.0, 3.0)])
	return row


# How far from the player the row's first object would appear. Vehicles drive forward,
# so they start closer to the player than the row position.
func _row_start_dist(row: Dictionary) -> float:
	var d: float = player.position.z - float(row["m"])
	var v: float = row["v"]
	return d - v * _time_to_cover(d)


func _spawn_row(row: Dictionary) -> void:
	var m: float = row["m"]
	if row["has_vehicle"]:
		_spawn_vehicle(row["vehicle_lane"], m, row["v"])
	for ob in row["obstacles"]:
		_spawn_obstacle(ob[0], m + ob[1])
	if row["ped_side"] != 0.0:
		_spawn_pedestrian(m, row["ped_side"])


# ------------------------------------------------------------------------------
# Hazards
# ------------------------------------------------------------------------------
func _spawn_vehicle(lane_i: int, m: float, v: float) -> void:
	var h := Hazard.new()
	h.type = 0
	h.half = Vector2(0.9, 2.0)
	h.reason = "You crashed into another vehicle."
	var colors := [Color(0.1, 0.3, 0.8), Color(0.9, 0.9, 0.9), Color(0.1, 0.6, 0.3),
			Color(0.9, 0.7, 0.1), Color(0.3, 0.3, 0.35)]
	h.node = _make_car_model(colors[randi() % colors.size()])
	# start position chosen so the vehicle is exactly at z = m when the player gets there
	var z0 := m + v * _time_to_cover(player.position.z - m)
	h.node.position = Vector3(lane_i * LANE_WIDTH, 0.0, z0)
	h.vel = Vector3(0, 0, -v)
	add_child(h.node)
	hazards.append(h)


func _spawn_obstacle(lane_i: int, z: float) -> void:
	var h := Hazard.new()
	h.type = 1
	h.reason = "You hit an obstacle."
	var n := Node3D.new()
	match randi() % 3:
		0:  # barrel
			_add_cyl(n, 0.45, 1.0, Vector3(0, 0.5, 0), Color(0.9, 0.4, 0.1))
			_add_cyl(n, 0.46, 0.15, Vector3(0, 0.5, 0), Color(0.95, 0.95, 0.95))
			h.half = Vector2(0.45, 0.45)
		1:  # cone
			var cone := _add_cyl(n, 0.35, 0.9, Vector3(0, 0.45, 0), Color(1.0, 0.45, 0.0))
			(cone.mesh as CylinderMesh).top_radius = 0.03
			h.half = Vector2(0.35, 0.35)
		_:  # road barrier (2 m wide)
			_add_box(n, Vector3(2.0, 0.9, 0.4), Vector3(0, 0.75, 0), Color(0.9, 0.9, 0.9))
			_add_box(n, Vector3(2.0, 0.25, 0.41), Vector3(0, 0.9, 0), Color(0.9, 0.1, 0.1))
			_add_box(n, Vector3(0.15, 0.6, 0.15), Vector3(-0.8, 0.3, 0), Color(0.3, 0.3, 0.3))
			_add_box(n, Vector3(0.15, 0.6, 0.15), Vector3(0.8, 0.3, 0), Color(0.3, 0.3, 0.3))
			h.half = Vector2(1.0, 0.3)
	n.position = Vector3(lane_i * LANE_WIDTH, 0.0, z)
	h.node = n
	add_child(n)
	hazards.append(h)


func _spawn_pedestrian(z: float, side: float) -> void:
	var h := Hazard.new()
	h.type = 2
	h.half = Vector2(0.35, 0.35)
	h.reason = "You hit a pedestrian."
	h.waiting = true
	h.side = side
	h.trigger = randf_range(1.2, 2.4)   # keeps the far-side lane clear when the car arrives
	h.phase = randf() * TAU
	var n := Node3D.new()
	var col := Color.from_hsv(randf(), 0.6, 0.9)
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.25
	cap.height = 1.6
	body.mesh = cap
	body.material_override = _mat(col)
	body.position.y = 0.8
	n.add_child(body)
	var head := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.22
	sph.height = 0.44
	head.mesh = sph
	head.material_override = _mat(Color(0.9, 0.75, 0.6))
	head.position.y = 1.8
	n.add_child(head)
	n.position = Vector3(h.side * 6.5, 0.1, z)
	h.node = n
	add_child(n)
	hazards.append(h)


func _update_hazards(delta: float) -> void:
	for i in range(hazards.size() - 1, -1, -1):
		var h: Hazard = hazards[i]
		var n := h.node

		# Pedestrians start crossing when the player is `trigger` seconds away
		if h.type == 2:
			if h.waiting and _time_to_cover(player.position.z - n.position.z) <= h.trigger:
				h.waiting = false
				h.vel = Vector3(-h.side * PED_SPEED, 0, 0)
			if not h.waiting:
				n.position.y = 0.1 + absf(sin(play_time * 9.0 + h.phase)) * 0.08
				if (h.side > 0.0 and n.position.x < -7.2) or (h.side < 0.0 and n.position.x > 7.2):
					h.vel = Vector3.ZERO

		n.position += h.vel * delta

		var dx := n.position.x - player.position.x
		var dz := n.position.z - player.position.z
		var reach_x := h.half.x + PLAYER_HALF.x
		var reach_z := h.half.y + PLAYER_HALF.y

		# Collision = Game Over
		if absf(dx) < reach_x and absf(dz) < reach_z:
			_game_over(h.reason)
			return

		# Was this hazard a real risk for the player?
		if dz < 0.0 and dz > -60.0 and absf(dx) < reach_x + 0.5:
			h.threat = true
		if absf(dz) < 7.0:
			h.min_gap = minf(h.min_gap, absf(dx) - reach_x)

		# Hazard passed (it is now behind the player) -> close call bonus
		if not h.scored and dz > reach_z + 1.0:
			h.scored = true
			if h.threat or h.min_gap < 1.0:
				score += 10
				_popup("Close call!  +10", Color(0.4, 1.0, 0.5))

		if dz > 40.0:
			n.queue_free()
			hazards.remove_at(i)


# ------------------------------------------------------------------------------
# Score and route progress
# ------------------------------------------------------------------------------
func _update_progress(delta: float) -> void:
	score_timer += delta
	while score_timer >= 1.0:
		score_timer -= 1.0
		score += 1

	var seg_now := int(-player.position.z / SEGMENT_LENGTH)
	if seg_now > segments_done:
		segments_done = seg_now
		score += 50
		var text := "Segment %d complete!  +50" % segments_done
		var color := Color(0.4, 0.8, 1.0)
		var new_level := mini(segments_done, 3)
		if new_level != level:
			level = new_level
			text += "\n" + LEVEL_MSGS[level]
			color = LEVEL_COLORS[level]
		_popup(text, color)


# ------------------------------------------------------------------------------
# Camera + post effects (wobble, FOV, blur, tint)
# ------------------------------------------------------------------------------
func _update_camera(delta: float) -> void:
	var k2 := clampf(drunk - 1.0, 0.0, 2.0)    # wobble: small at lvl 2, bigger at lvl 3
	var k3 := clampf(drunk - 2.0, 0.0, 1.0)    # blur / FOV only at lvl 3
	var t := Time.get_ticks_msec() / 1000.0

	cam_x = lerpf(cam_x, player.position.x * 0.6, minf(1.0, delta * 6.0))
	var wobble := Vector3(sin(t * 0.9) * 0.3, sin(t * 1.3) * 0.12, 0.0) * k2
	camera.position = Vector3(cam_x + wobble.x, 3.4 + wobble.y, player.position.z + 7.5)
	camera.look_at(Vector3(cam_x, 1.2, player.position.z - 14.0), Vector3.UP)
	camera.rotate_object_local(Vector3.BACK, (sin(t * 1.1) * 0.03 + sin(t * 0.37) * 0.015) * k2)

	var target_fov := BASE_FOV + clampf((speed - START_SPEED) * 0.2, 0.0, 8.0) - 22.0 * k3
	camera.fov = lerpf(camera.fov, target_fov, minf(1.0, delta * 3.0))

	# warm screen tint that grows with every drink (visible cue from level 1 on)
	var kd := clampf(drunk / 3.0, 0.0, 1.0)
	tint.color = Color(1.0, lerpf(0.75, 0.3, kd), 0.25, kd * 0.12)

	fx_rect.visible = k3 > 0.01
	fx_mat.set_shader_parameter("blur", k3 * 2.4)
	fx_mat.set_shader_parameter("split", k3 * 0.007)
	fx_mat.set_shader_parameter("vignette", k3 * 0.75)


# ------------------------------------------------------------------------------
# UI helpers
# ------------------------------------------------------------------------------
func _style(bg: Color, border: Color, radius := 12, border_w := 1, margin := 12) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	if border_w > 0:
		sb.shadow_color = Color(0, 0, 0, 0.35)
		sb.shadow_size = 6
	return sb


func _label(text: String, font_size: int, color := Color.WHITE,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("outline_size", 4)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _make_bar(fill: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.show_percentage = false
	b.min_value = 0.0
	b.max_value = 100.0
	b.custom_minimum_size = Vector2(0, 8)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(1, 1, 1, 0.12)
	bg.set_corner_radius_all(4)
	var fg := StyleBoxFlat.new()
	fg.bg_color = fill
	fg.set_corner_radius_all(4)
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fg)
	return b


func _cell(c: Control, h_align: int) -> void:
	c.size_flags_horizontal = (Control.SIZE_EXPAND | h_align) as Control.SizeFlags
	c.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _keycap(text: String, width := 46.0) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style(Color(1, 1, 1, 0.10), Color(1, 1, 1, 0.38), 9, 2, 6))
	p.custom_minimum_size = Vector2(width, 46)
	p.add_child(_label(text, 20, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER))
	return p


func _stat_tile(parent: Control, caption: String) -> Label:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.10), 12, 1, 14))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	p.add_child(v)
	v.add_child(_label(caption, 14, COL_MUTED))
	var val := _label("0", 34, Color.WHITE)
	v.add_child(val)
	return val


# ------------------------------------------------------------------------------
# HUD
# ------------------------------------------------------------------------------
func _build_hud() -> void:
	var hud := CanvasLayer.new()
	hud.layer = 3
	add_child(hud)
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# ---- top bar: score | alcohol | speed --------------------------------------
	var top := MarginContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for m in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		top.add_theme_constant_override(m, 20)
	root.add_child(top)
	top.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bar := HBoxContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_constant_override("separation", 12)
	top.add_child(bar)

	# score + route progress
	var left := PanelContainer.new()
	left.add_theme_stylebox_override("panel", _style(COL_PANEL, COL_BORDER, 14, 1, 14))
	left.custom_minimum_size = Vector2(250, 0)
	_cell(left, Control.SIZE_SHRINK_BEGIN)
	bar.add_child(left)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 4)
	left.add_child(lv)
	lv.add_child(_label("SCORE", 14, COL_MUTED))
	score_label = _label("0", 44, Color.WHITE)
	lv.add_child(score_label)
	route_bar = _make_bar(COL_ACCENT)
	lv.add_child(route_bar)
	segment_label = _label("", 14, COL_MUTED)
	lv.add_child(segment_label)

	# alcohol meter
	var mid := PanelContainer.new()
	alc_panel_style = _style(COL_PANEL, COL_BORDER, 14, 2, 14)
	mid.add_theme_stylebox_override("panel", alc_panel_style)
	_cell(mid, Control.SIZE_SHRINK_CENTER)
	bar.add_child(mid)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 6)
	mid.add_child(mv)
	mv.add_child(_label("BLOOD ALCOHOL", 14, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	var cells := HBoxContainer.new()
	cells.add_theme_constant_override("separation", 6)
	cells.alignment = BoxContainer.ALIGNMENT_CENTER
	mv.add_child(cells)
	for i in range(3):
		var cell := PanelContainer.new()
		cell.custom_minimum_size = Vector2(64, 14)
		var st := _style(Color(1, 1, 1, 0.12), Color(0, 0, 0, 0), 5, 0, 0)
		cell.add_theme_stylebox_override("panel", st)
		cells.add_child(cell)
		alc_styles.append(st)
	alc_state_label = _label("SOBER", 20, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	mv.add_child(alc_state_label)

	# speedometer
	var right := PanelContainer.new()
	right.add_theme_stylebox_override("panel", _style(COL_PANEL, COL_BORDER, 14, 1, 14))
	right.custom_minimum_size = Vector2(250, 0)
	_cell(right, Control.SIZE_SHRINK_END)
	bar.add_child(right)
	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 4)
	right.add_child(rv)
	var sline := HBoxContainer.new()
	sline.alignment = BoxContainer.ALIGNMENT_END
	sline.add_theme_constant_override("separation", 8)
	rv.add_child(sline)
	speed_label = _label("0", 44, Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT)
	sline.add_child(speed_label)
	var unit := _label("KM/H", 16, COL_MUTED)
	unit.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	sline.add_child(unit)
	speed_bar = _make_bar(COL_ACCENT)
	rv.add_child(speed_bar)
	speed_fill = speed_bar.get_theme_stylebox("fill") as StyleBoxFlat
	var rcap := _label("SPEED", 14, COL_MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	rv.add_child(rcap)

	# ---- popup banner ----------------------------------------------------------
	var pop_margin := MarginContainer.new()
	pop_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pop_margin.add_theme_constant_override("margin_top", 140)
	root.add_child(pop_margin)
	pop_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var pop_box := VBoxContainer.new()
	pop_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pop_margin.add_child(pop_box)
	popup_panel = PanelContainer.new()
	popup_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	popup_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	popup_style = _style(Color(0.04, 0.05, 0.09, 0.88), COL_ACCENT, 14, 2, 16)
	popup_panel.add_theme_stylebox_override("panel", popup_style)
	popup_panel.modulate.a = 0.0
	pop_box.add_child(popup_panel)
	popup_label = _label("", 30, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	popup_panel.add_child(popup_label)

	# ---- control hint (fades out a few seconds after the start) -----------------
	hint_label = _label("A / D  or  LEFT / RIGHT  -  change lane", 22, Color(1, 1, 1, 0.9), HORIZONTAL_ALIGNMENT_CENTER)
	hint_label.modulate.a = 0.0
	root.add_child(hint_label)
	hint_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE, Control.PRESET_MODE_MINSIZE, 36)

	_build_overlay(root)


func _build_overlay(root: Control) -> void:
	flash = ColorRect.new()
	flash.color = Color(0.9, 0.05, 0.05, 0.0)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(flash)
	flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	dim = ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.06, 0.68)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _style(Color(0.06, 0.07, 0.11, 0.95), Color(1, 1, 1, 0.14), 22, 2, 34))
	card.custom_minimum_size = Vector2(700, 0)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	card.add_child(box)

	title_label = _label("", 56, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	title_label.add_theme_constant_override("outline_size", 8)
	box.add_child(title_label)
	subtitle_label = _label("", 22, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(subtitle_label)
	box.add_child(HSeparator.new())

	# ---- menu content ----------------------------------------------------------
	menu_box = VBoxContainer.new()
	menu_box.add_theme_constant_override("separation", 14)
	box.add_child(menu_box)

	var keys := HBoxContainer.new()
	keys.alignment = BoxContainer.ALIGNMENT_CENTER
	keys.add_theme_constant_override("separation", 8)
	menu_box.add_child(keys)
	keys.add_child(_keycap("A"))
	keys.add_child(_keycap("D"))
	keys.add_child(_label("  or  ", 18, COL_MUTED))
	keys.add_child(_keycap("LEFT", 84.0))
	keys.add_child(_keycap("RIGHT", 96.0))
	keys.add_child(_label("   change lane", 20, Color.WHITE))

	for r in [["+1", "every second survived", Color(0.8, 0.85, 1.0)],
			["+10", "close call with a hazard", Color(0.4, 1.0, 0.5)],
			["+50", "route segment completed", Color(0.4, 0.8, 1.0)]]:
		var line := HBoxContainer.new()
		line.alignment = BoxContainer.ALIGNMENT_CENTER
		line.add_theme_constant_override("separation", 14)
		var chip := _label(r[0], 26, r[2], HORIZONTAL_ALIGNMENT_RIGHT)
		chip.custom_minimum_size = Vector2(70, 0)
		line.add_child(chip)
		var desc := _label(r[1], 20, Color.WHITE)
		desc.custom_minimum_size = Vector2(300, 0)
		line.add_child(desc)
		menu_box.add_child(line)

	menu_box.add_child(_label(
		"Crashing, hitting a pedestrian or leaving the road ends the run.\nThe farther you drive, the more you drink.",
		18, Color(1, 0.7, 0.35), HORIZONTAL_ALIGNMENT_CENTER))

	# ---- game over content -----------------------------------------------------
	over_box = VBoxContainer.new()
	over_box.add_theme_constant_override("separation", 14)
	box.add_child(over_box)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	over_box.add_child(grid)
	stat_score = _stat_tile(grid, "SCORE")
	stat_best = _stat_tile(grid, "BEST")
	stat_dist = _stat_tile(grid, "DISTANCE")
	stat_alc = _stat_tile(grid, "ALCOHOL LEVEL")
	newbest_label = _label("NEW BEST SCORE!", 24, Color(1, 0.85, 0.3), HORIZONTAL_ALIGNMENT_CENTER)
	over_box.add_child(newbest_label)
	var msg := _label("Alcohol slows your reactions, narrows your vision and ruins your judgement.\nIt is never worth the risk. Don't drink and drive.",
			18, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	over_box.add_child(msg)
	over_box.visible = false

	# ---- prompt (pulsing) ------------------------------------------------------
	box.add_child(HSeparator.new())
	prompt_label = _label("", 24, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(prompt_label)
	var pulse := create_tween().set_loops()
	pulse.tween_property(prompt_label, "modulate:a", 0.35, 0.8)
	pulse.tween_property(prompt_label, "modulate:a", 1.0, 0.8)


func _update_hud() -> void:
	var seg_pos := fposmod(-player.position.z, SEGMENT_LENGTH)
	score_label.text = str(score)
	segment_label.text = "SEGMENT %d  -  %d / %d m" % [segments_done + 1, int(seg_pos), int(SEGMENT_LENGTH)]
	route_bar.value = seg_pos / SEGMENT_LENGTH * 100.0

	speed_label.text = str(int(speed * 3.6))
	var sr := clampf((speed - START_SPEED) / (MAX_SPEED - START_SPEED), 0.0, 1.0)
	speed_bar.value = sr * 100.0
	speed_fill.bg_color = COL_ACCENT.lerp(Color(1, 0.3, 0.25), sr)

	# alcohol cells fill up smoothly while the level rises
	for i in range(3):
		var st: StyleBoxFlat = alc_styles[i]
		st.bg_color = Color(1, 1, 1, 0.12).lerp(LEVEL_COLORS[i + 1], clampf(drunk - i, 0.0, 1.0))
	if level != _hud_level:
		_hud_level = level
		alc_state_label.text = STATE_NAMES[level]
		alc_state_label.add_theme_color_override("font_color", LEVEL_COLORS[level])
		alc_panel_style.border_color = LEVEL_COLORS[level] if level > 0 else COL_BORDER


func _popup(text: String, color: Color) -> void:
	popup_label.text = text
	popup_label.add_theme_color_override("font_color", color)
	popup_style.border_color = color
	popup_panel.reset_size()
	if popup_tween:
		popup_tween.kill()
	popup_panel.modulate.a = 0.0
	popup_tween = create_tween()
	popup_tween.tween_property(popup_panel, "modulate:a", 1.0, 0.12)
	popup_tween.tween_interval(1.7)
	popup_tween.tween_property(popup_panel, "modulate:a", 0.0, 0.5)


func _build_post_fx() -> void:
	# warm tint layer (below the blur so the blur affects it too)
	var tint_layer := CanvasLayer.new()
	tint_layer.layer = 1
	add_child(tint_layer)
	tint = ColorRect.new()
	tint.color = Color(1.0, 0.75, 0.25, 0.0)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tint_layer.add_child(tint)
	tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var layer := CanvasLayer.new()
	layer.layer = 2                       # below the HUD so text stays sharp
	add_child(layer)
	fx_rect = ColorRect.new()
	fx_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = FX_SHADER
	fx_mat = ShaderMaterial.new()
	fx_mat.shader = shader
	fx_rect.material = fx_mat
	layer.add_child(fx_rect)
	fx_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fx_rect.visible = false


# ------------------------------------------------------------------------------
# World building (endless road = chunks recycled in front of the player)
# ------------------------------------------------------------------------------
func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.8, 0.9)
	env.fog_density = 0.006
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	add_child(sun)

	ground = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1200, 1200)
	ground.mesh = plane
	ground.material_override = _mat(Color(0.25, 0.5, 0.2))
	ground.position.y = -0.15
	add_child(ground)

	for i in range(NUM_CHUNKS):
		var c := _make_chunk(i)
		add_child(c)
		chunks.append(c)


func _make_chunk(i: int) -> Node3D:
	var c := Node3D.new()
	c.position.z = 100.0 - i * CHUNK_LEN
	_add_box(c, Vector3(ROAD_HALF * 2.0, 0.2, CHUNK_LEN), Vector3(0, -0.1, 0), Color(0.16, 0.16, 0.18))
	for s in [-1, 1]:
		_add_box(c, Vector3(0.15, 0.02, CHUNK_LEN), Vector3(s * (ROAD_HALF - 0.25), 0.011, 0), Color(0.9, 0.9, 0.9))
		_add_box(c, Vector3(2.5, 0.25, CHUNK_LEN), Vector3(s * 6.5, 0.0, 0), Color(0.55, 0.55, 0.55))
		for k in range(4):
			var pz := -37.5 + k * 25.0
			_add_cyl(c, 0.1, 6.0, Vector3(s * 8.2, 3.0, pz), Color(0.3, 0.3, 0.3))
			_add_box(c, Vector3(1.8, 0.15, 0.4), Vector3(s * 7.4, 6.0, pz), Color(1.0, 0.95, 0.7), true)
		for k in range(3):
			var tx: float = s * randf_range(10.0, 17.0)
			var tz := randf_range(-50.0, 50.0)
			_add_cyl(c, 0.3, 2.0, Vector3(tx, 1.0, tz), Color(0.4, 0.25, 0.1))
			var crown := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 1.6
			sm.height = 3.2
			crown.mesh = sm
			crown.material_override = _mat(Color(0.12, 0.4, 0.15))
			crown.position = Vector3(tx, 3.2, tz)
			c.add_child(crown)
	for lx in [-1.75, 1.75]:
		for k in range(10):
			_add_box(c, Vector3(0.15, 0.02, 3.0), Vector3(lx, 0.011, -45.0 + k * 10.0), Color(0.9, 0.9, 0.9))
	return c


func _update_chunks() -> void:
	for c in chunks:
		if c.position.z - player.position.z > CHUNK_LEN * 1.5:
			c.position.z -= CHUNK_LEN * NUM_CHUNKS


# ------------------------------------------------------------------------------
# Model helpers
# ------------------------------------------------------------------------------
func _make_car_model(color: Color) -> Node3D:
	var car := Node3D.new()
	_add_box(car, Vector3(1.8, 0.6, 4.0), Vector3(0, 0.6, 0), color)
	_add_box(car, Vector3(1.6, 0.5, 1.9), Vector3(0, 1.15, 0.3), Color(0.15, 0.2, 0.25))
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var w := _add_cyl(car, 0.4, 0.3, Vector3(sx * 0.95, 0.4, sz * 1.3), Color(0.05, 0.05, 0.05))
			w.rotation_degrees.z = 90.0
		_add_box(car, Vector3(0.4, 0.18, 0.06), Vector3(sx * 0.6, 0.7, 2.02), Color(1.0, 0.1, 0.1), true)
	return car


func _mat(color: Color, emissive := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if emissive:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 1.5
	return m


func _add_box(parent: Node, size: Vector3, pos: Vector3, color: Color, emissive := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(color, emissive)
	mi.position = pos
	parent.add_child(mi)
	return mi


func _add_cyl(parent: Node, radius: float, height: float, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	mi.mesh = cm
	mi.material_override = _mat(color)
	mi.position = pos
	parent.add_child(mi)
	return mi
